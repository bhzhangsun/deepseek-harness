#!/bin/sh
# Exercise `dsh-cli user` against stubs: no root, no real accounts, no real ACLs.
#
# The stubs stand in for the privileged tools (adduser, setfacl, chown, usermod,
# setpriv) and for the machine facts the wrapper reads (systemctl, getent, id).
# Every path the wrapper touches lives under a scratch root, so the run is
# repeatable and leaves nothing behind on the host.
set -u
here=$(cd "$(dirname "$0")" && pwd)
script=$here/dsh-cli

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT INT TERM
bin=$root/bin
log=$root/log
mkdir -p "$bin"
: > "$log"

state=$root/state
dshhome=$root/dshhome
mkdir -p "$state" "$dshhome"
chmod 0700 "$state" # private state root: the wrapper must walk it with an ACL
passwd=$root/passwd
groups_file=$root/groups
: > "$groups_file"
cat > "$passwd" <<EOF
root:x:0:0:root:/root:/bin/sh
dsh:x:108:112::$dshhome:/usr/sbin/nologin
EOF

# --- stubs ------------------------------------------------------------------
cat > "$bin/systemctl" <<EOF
#!/bin/sh
case "\$*" in
  *"-p User"*) echo dsh ;;
  *"-p Environment"*) echo "DSH_HOME=$state" ;;
  *"-p ProtectHome"*)
    echo 'ProtectHome=read-only'
    echo "ReadWritePaths=$state" ;;
esac
EOF

cat > "$bin/getent" <<EOF
#!/bin/sh
if [ -n "\${2-}" ]; then
  grep "^\$2:" $passwd
else
  cat $passwd
fi
EOF

cat > "$bin/id" <<EOF
#!/bin/sh
case "\${1-}" in
  -u) echo "\${STUB_UID:-0}" ;;
  -gn) echo dsh ;;
  -nG)
    printf 'dsh'
    while read -r g; do printf ' %s' "\$g"; done < $groups_file
    printf '\n' ;;
esac
EOF

cat > "$bin/stat" <<EOF
#!/bin/sh
# stat -c %a <path> decides which ancestors need a traverse ACL: report the
# private state root as 0700 and every other directory as world-traversable.
# stat -c %U <path> names the owner, which the grant needs for the entry that keeps
# the owner able to write the service account's files: a home created here belongs
# to the account it is named after.
for last in "\$@"; do :; done
case "\$*" in
  *"%a"*) if [ "\$last" = "$state" ]; then echo 700; else echo 755; fi ;;
  *"%U"*) echo "\${last##*/}" ;;
esac
EOF

cat > "$bin/adduser" <<EOF
#!/bin/sh
echo "adduser \$*" >> $log
home=
name=
while [ \$# -gt 0 ]; do
  case "\$1" in
    --home) home=\$2; shift 2 ;;
    --shell|--gecos) shift 2 ;;
    --quiet|--disabled-password) shift ;;
    *) name=\$1; shift ;;
  esac
done
[ -n "\$home" ] && mkdir -p "\$home"
echo "\$name:x:1001:1001::\$home:/usr/sbin/nologin" >> $passwd
EOF

cat > "$bin/useradd" <<EOF
#!/bin/sh
echo "useradd \$*" >> $log
home=
name=
while [ \$# -gt 0 ]; do
  case "\$1" in
    --home-dir) home=\$2; shift 2 ;;
    --shell) shift 2 ;;
    --create-home|--user-group) shift ;;
    *) name=\$1; shift ;;
  esac
done
[ -n "\$home" ] && mkdir -p "\$home"
echo "\$name:x:1001:1001::\$home:/usr/sbin/nologin" >> $passwd
EOF

cat > "$bin/usermod" <<EOF
#!/bin/sh
echo "usermod \$*" >> $log
echo "\$2" >> $groups_file
EOF

cat > "$bin/gpasswd" <<EOF
#!/bin/sh
echo "gpasswd \$*" >> $log
grep -vx "\$3" $groups_file > $root/groups.new 2>/dev/null || true
mv $root/groups.new $groups_file
EOF

cat > "$bin/deluser" <<EOF
#!/bin/sh
echo "deluser \$*" >> $log
grep -v "^\$1:" $passwd > $root/passwd.new || true
mv $root/passwd.new $passwd
EOF

cat > "$bin/userdel" <<EOF
#!/bin/sh
echo "userdel \$*" >> $log
grep -v "^\$1:" $passwd > $root/passwd.new || true
mv $root/passwd.new $passwd
EOF

# Records the granted entry, so getfacl can report what is really there: a
# group-only grant must not read back as a named-account ACL.
cat > "$bin/setfacl" <<EOF
#!/bin/sh
echo "setfacl \$*" >> $log
spec=
verb=
prev=
for a in "\$@"; do
  case "\$prev" in
    -m) spec=\$a ;;
    -x) spec=\$a; verb=remove ;;
  esac
  prev=\$a
done
for last in "\$@"; do :; done
# A file another account owns is what makes the real setfacl stop part way through a
# tree, so a marker makes the stub refuse exactly the way the tool does. The wrapper
# has to keep going and report it.
if [ -f "$root/foreign" ]; then
  case "\$last" in
    */users/*) echo "setfacl: \$last/foreign.txt: Operation not permitted" >&2; exit 1 ;;
  esac
fi
marker="$root/acl.\$(printf '%s' "\$last" | tr / _)"
if [ "\$verb" = remove ]; then
  if [ -f "\$marker" ]; then
    cp "\$marker" "\$marker.new"
    for entry in \$(printf '%s' "\$spec" | tr ',' ' '); do
      grep -v -F "\$entry" "\$marker.new" > "\$marker.tmp" 2>/dev/null || :
      mv "\$marker.tmp" "\$marker.new"
    done
    mv "\$marker.new" "\$marker"
  fi
elif [ -n "\$spec" ]; then
  # One entry per line, the way setfacl writes them, so a removal can drop one.
  printf '%s\n' "\$spec" | tr ',' '\n' >> "\$marker"
fi
exit 0
EOF

cat > "$bin/getfacl" <<EOF
#!/bin/sh
for last in "\$@"; do :; done
marker="$root/acl.\$(printf '%s' "\$last" | tr / _)"
[ -f "\$marker" ] || exit 0
if grep -q '^u:dsh:' "\$marker"; then echo 'user:dsh:rwx'; fi
sed -n 's/^g:\\([^:]*\\):.*/group:\\1:rwx/p' "\$marker" | sort -u
EOF

cat > "$bin/chown" <<EOF
#!/bin/sh
echo "chown \$*" >> $log
EOF

# macOS refuses the setgid bit on a scratch directory, so the mode change is
# logged rather than applied; Linux is where this script actually runs. A 2770
# home is recorded separately, because that bit is what makes a group grant work.
cat > "$bin/chmod" <<EOF
#!/bin/sh
echo "chmod \$*" >> $log
case "\${1-}" in
  2770)
    for last in "\$@"; do :; done
    : > "$root/setgid.\$(printf '%s' "\$last" | tr / _)" ;;
esac
EOF

# A faithful enough access check: a named ACL grants, and so does membership in a
# group that owns the directory. Otherwise the account is refused.
cat > "$bin/setpriv" <<EOF
#!/bin/sh
echo "setpriv \$*" >> $log
# Only the access check (setpriv ... test -r|-w <path>) is emulated; every other
# invocation, such as handing the CLI to the service account, just succeeds.
case "\$*" in
  *" test "*) ;;
  *) exit 0 ;;
esac
mode=
path=
for a in "\$@"; do
  case "\$a" in
    -r|-w) mode=\$a ;;
    /*) path=\$a ;;
  esac
done
[ -n "\$path" ] || exit 0
marker="$root/acl.\$(printf '%s' "\$path" | tr / _)"
[ -f "\$marker" ] && exit 0
# A group grant only reaches the account if that home carries the setgid bit and the
# account is in the group, which is the condition the real check encodes.
if [ "\$mode" = -w ] && [ -f "$root/setgid.\$(printf '%s' "\$path" | tr / _)" ] && [ -s $groups_file ]; then
  exit 0
fi
exit 1
EOF

chmod +x "$bin"/*

# --- helpers ----------------------------------------------------------------
pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

# run <label> <expected status> [VAR=value] -- args...
run() {
  label=$1
  want=$2
  shift 2
  env_prefix=
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    env_prefix="$env_prefix $1"
    shift
  done
  [ $# -gt 0 ] && shift
  out=$root/out
  env PATH="$bin:$PATH" $env_prefix sh "$script" user "$@" > "$out" 2>&1
  got=$?
  if [ "$got" = "$want" ]; then
    ok "$label (exit $got)"
  else
    no "$label" "exit $got, wanted $want:
$(cat "$out")"
  fi
  cat "$out"
}

has() { if grep -qF -- "$2" "$root/out"; then ok "$1"; else no "$1" "missing: $2"; fi; }
hasnt() { if grep -qF -- "$2" "$root/out"; then no "$1" "unexpected: $2"; else ok "$1"; fi; }
match() { if grep -qE -- "$2" "$root/out"; then ok "$1"; else no "$1" "no match: $2"; fi; }
logged() { if grep -qF -- "$2" "$log"; then ok "$1"; else no "$1" "not logged: $2"; fi; }
notLogged() { if grep -qF -- "$2" "$log"; then no "$1" "unexpectedly logged: $2"; else ok "$1"; fi; }

printf '== usage ==\n'
run 'bare user prints usage' 2 -- ; has 'mentions the missing subcommand' 'user needs a subcommand'
run 'user help prints usage' 0 -- help ; has 'documents add' 'dsh-cli user add <name>'
run 'user help documents group share' 0 -- help ; has 'explains the restart' 'systemctl restart dsh'
run 'unknown verb' 2 -- frobnicate ; has 'names the bad verb' 'unknown user subcommand: frobnicate'

printf '== name and option validation ==\n'
for bad in '../evil' 'Alice' '9bad' 'a.b' 'a/b'; do
  run "rejects name $bad" 2 -- add "$bad"
done
run 'rejects a relative base' 2 -- add dave --base users ; has 'explains --base' '--base needs an absolute path'
run 'rejects an unknown share mode' 2 -- add dave --share world
run 'rejects an unknown option' 2 -- add --frobnicate

printf '== add --dry-run changes nothing ==\n'
run 'dry-run add alice' 0 -- add alice --dry-run
has 'plans adduser with the home inside the state' "adduser --quiet --disabled-password --gecos  --home $state/users/alice --shell /usr/sbin/nologin alice"
has 'plans the root-owned base' "install -d -m 0755 $state/users"
has 'plans the base owner' "chown root:root $state/users"
has 'plans the home mode' "chmod 0750 $state/users/alice"
has 'plans the link under the service home' "ln -sfn $state/users/alice $dshhome/alice"
has 'plans traverse for the new account' "setfacl -m u:alice:x $state"
has 'plans the named grant' "setfacl -R -m u:dsh:rwX,u:alice:rwX $state/users/alice"
has 'plans the inherited default' "setfacl -R -d -m u:dsh:rwX,u:alice:rwX $state/users/alice"
has 'plans no restart for acl' 'no restart needed'
hasnt 'plans no group change' 'usermod'
if [ -e "$state/users" ]; then no 'dry-run left no base' "$state/users exists"; else ok 'dry-run left no base'; fi
if [ -f "$log" ]; then :; fi

printf '== add ==\n'
: > "$log"
run 'add alice' 0 -- add alice
logged 'ran adduser' "adduser --quiet --disabled-password --gecos  --home $state/users/alice"
logged 'set the base owner' "chown root:root $state/users"
logged 'granted the named ACL' "setfacl -R -m u:dsh:rwX,u:alice:rwX $state/users/alice"
logged 'granted the inherited ACL' "setfacl -R -d -m u:dsh:rwX,u:alice:rwX $state/users/alice"
has 'says the owner keeps write access too' 'alice keeps write access to the files dsh creates here'
has 'reports the resolved home' "home  $state/users/alice"
has 'reports the link' "link  $dshhome/alice -> $state/users/alice"
if [ -d "$state/users/alice" ]; then ok 'created the home'; else no 'created the home' "$state/users/alice missing"; fi
if [ -L "$dshhome/alice" ]; then ok 'created the link'; else no 'created the link' "$dshhome/alice is not a symlink"; fi
if [ "$(readlink "$dshhome/alice")" = "$state/users/alice" ]; then ok 'link points at the home'; else no 'link points at the home' "$(readlink "$dshhome/alice")"; fi
if grep -q '^alice:' "$passwd"; then ok 'registered the account'; else no 'registered the account' 'no alice entry'; fi

printf '== add is idempotent, and refuses a foreign account ==\n'
: > "$log"
run 're-add alice' 0 -- add alice
has 'says it is re-applying' 'exists; re-applying its grant'
notLogged 'did not create alice twice' 'adduser'
has 'leaves the existing mode alone' 'kept the existing home mode'
notLogged 'changed no mode on the existing home' 'chmod'
echo 'carol:x:1002:1002::/home/carol:/bin/sh' >> "$passwd"
run 'refuses a foreign home' 1 -- add carol
has 'explains the refusal' 'already exists with home /home/carol'

printf '== share modes ==\n'
run 'group share dry-run' 0 -- add bob --share group --dry-run
has 'sets the setgid mode' "chmod 2770 $state/users/bob"
has 'joins the private group' "usermod -aG bob dsh"
has 'carries the group write bit' "setfacl -R -d -m g:bob:rwX $state/users/bob"
has 'demands the restart' 'sudo systemctl restart dsh'
hasnt 'makes no named grant for group only' 'setfacl -R -m u:dsh:'
: > "$log"
run 'group share' 0 -- add bob --share group
logged 'joined the group' "usermod -aG bob dsh"
logged 'set the setgid mode' "chmod 2770 $state/users/bob"
logged 'carried the group write bit' "setfacl -R -d -m g:bob:rwX $state/users/bob"
if grep -qx bob "$groups_file"; then ok 'recorded the membership'; else no 'recorded the membership' 'bob not in groups'; fi

run 'read-only dry-run' 0 -- add dave --read-only --dry-run
has 'grants read and traverse only' "setfacl -R -m u:dsh:rX,u:dave:rwX $state/users/dave"
hasnt 'grants no write' "setfacl -R -m u:dsh:rwX"
has 'says writes stay denied' 'writes stay denied'

run 'share none dry-run' 0 -- add erin --share none --dry-run
has 'makes no grant' '--share none: no grant was made'
hasnt 'joins no group' 'usermod'

printf '== list ==\n'
run 'list' 0 -- list
has 'shows the header' 'GRANT'
match 'shows alice with an acl' '^alice[[:space:]].*[[:space:]]acl[[:space:]]'
match 'shows bob with a group' '^bob[[:space:]].*[[:space:]]group[[:space:]]'
hasnt 'does not invent an acl for bob' 'acl+group'

printf '== adopting an account and a home that already exist ==\n'
mkdir -p "$root/other/erin"
printf 'erin:x:1003:1003::%s/other/erin:/bin/sh\n' "$root" >> "$passwd"
: > "$log"
run 'adopt erin' 0 -- add erin --base "$root/other"
has 're-applies instead of creating' 'exists; re-applying its grant'
has 'reports the mode it found' 'kept the existing home mode'
notLogged 'created no account' 'adduser'
notLogged 'changed no mode' 'chmod'
logged 'granted the named ACL' "setfacl -R -m u:dsh:rwX,u:erin:rwX $root/other/erin"
has 'links the existing home' "link  $dshhome/erin -> $root/other/erin"
run 'adopt erin with group share' 0 -- add erin --base "$root/other" --share group
has 'warns that the group bits are needed' 'needs the group bits on that home'
run 'adopt erin read-only' 0 -- add erin --base "$root/other" --read-only
logged 'regranted read and traverse only' "setfacl -R -m u:dsh:rX,u:erin:rwX $root/other/erin"
run 'adopt erin with no grant' 0 -- add erin --base "$root/other" --share none
has 'says out loud that it granted nothing' 'no grant was made'
mkdir -p "$root/other2/dora"
printf 'dora:x:1004:1004::%s/other2/dora:/bin/sh\n' "$root" >> "$passwd"
run 'adopt a home that has no grant at all' 0 -- add dora --base "$root/other2" --share none
has 'says the account cannot write yet' 'CANNOT write'
has 'names the unit as the cause' 'the unit protects that path'
has 'names the drop-in route' 'systemctl edit dsh'

run 'list picks up the adopted account' 0 -- list
match 'lists erin from its link' '^erin[[:space:]]'

printf '== a file another account owns does not abandon the grant ==\n'
: > "$root/foreign"
run 'add uma while one entry refuses' 0 -- add uma
has 'reports what it left alone' 'entries were left alone, another account owns them'
has 'names the path it could not change' 'foreign.txt'
has 'finishes the grant anyway' 'uma keeps write access to the files dsh creates here'
rm -f "$root/foreign"

printf '== revoke keeps the account and the files ==\n'
: > "$log"
run 'revoke erin' 0 -- revoke erin
has 'says the home stays' '(left in place)'
has 'says the account stays' 'keeps the account and every file'
notLogged 'deleted no account' 'deluser'
logged 'dropped the named ACL' "setfacl -R -x u:dsh,u:erin $root/other/erin"
logged 'dropped the inherited ACL' "setfacl -R -d -x u:dsh,u:erin $root/other/erin"
logged 'dropped the group membership' "gpasswd -d dsh erin"
if [ -d "$root/other/erin" ]; then ok 'left the files alone'; else no 'left the files alone' 'home gone'; fi

printf '== remove refuses an account it did not create ==\n'
run 'refuse to delete an adopted account' 1 -- remove erin --base "$root/other"
has 'explains the refusal' 'only deletes the accounts it created'
has 'points at revoke' 'user revoke erin'
has 'points at --force' 'remove erin --force'
if grep -q '^erin:' "$passwd"; then ok 'kept the account'; else no 'kept the account' 'erin is gone'; fi
: > "$log"
run 'delete it with --force' 0 -- remove erin --base "$root/other" --force
logged 'deleted the account' 'deluser erin'
if grep -q '^erin:' "$passwd"; then no 'deleted the account for real' 'erin still present'; else ok 'deleted the account for real'; fi

printf '== remove ==\n'
run 'remove dry-run' 0 -- remove alice --dry-run
has 'plans deluser' 'deluser alice'
has 'plans dropping the link' "rm -f $dshhome/alice"
has 'plans revoking traverse' "setfacl -x u:alice $state"
has 'plans dropping the group membership' "gpasswd -d dsh alice"
if grep -q '^alice:' "$passwd"; then ok 'dry-run kept the account'; else no 'dry-run kept the account' 'alice is gone'; fi

: > "$log"
run 'remove alice' 0 -- remove alice
has 'keeps the home by default' "home kept at $state/users/alice"
if [ -d "$state/users/alice" ]; then ok 'home survives a plain remove'; else no 'home survives a plain remove' 'home deleted'; fi
if grep -q '^alice:' "$passwd"; then no 'removed the account' 'alice still present'; else ok 'removed the account'; fi
logged 'revoked the traverse ACL' "setfacl -x u:alice"

run 'remove unknown name' 1 -- remove zoe
has 'names the missing account' 'no account named zoe'

run 'remove --purge bob' 0 -- remove bob --purge
if [ -d "$state/users/bob" ]; then no 'purge deleted the home' 'bob still present'; else ok 'purge deleted the home'; fi
run 'remove bob again' 1 -- remove bob

printf '== the unprivileged caller still gets refused ==\n'
mkdir -p "$root/bin-nonroot"
cat > "$root/bin-nonroot/id" <<'EOF'
#!/bin/sh
case "${1-}" in
  -u) echo 1000 ;;
  -gn|-nG) echo dsh ;;
esac
EOF
chmod +x "$root/bin-nonroot/id"
out=$root/out
env PATH="$root/bin-nonroot:$bin:$PATH" sh "$script" user add frank > "$out" 2>&1
got=$?
if [ "$got" = 1 ]; then ok "refuses a non-root caller (exit $got)"; else no 'refuses a non-root caller' "exit $got: $(cat "$out")"; fi
cat "$out"
has 'points at sudo' 'run this through sudo, as in: sudo dsh-cli user add frank'
env PATH="$root/bin-nonroot:$bin:$PATH" sh "$script" user revoke frank > "$root/out" 2>&1
got=$?
if [ "$got" = 1 ]; then ok "revoke refuses a non-root caller (exit $got)"; else no 'revoke refuses a non-root caller' "exit $got"; fi
has 'revoke points at sudo' 'run this through sudo, as in: sudo dsh-cli user revoke frank'

printf '== the existing pass-through is untouched ==\n'
: > "$log"
env PATH="$bin:$PATH" sh "$script" plugin --profile web list > "$root/out" 2>&1
got=$?
if [ "$got" = 0 ]; then ok "other verbs still reach the CLI (exit $got)"; else no 'other verbs still reach the CLI' "exit $got: $(cat "$root/out")"; fi
cat "$root/out"
logged 'switched to the service account' '--reuid=dsh'
logged 'ran the CLI entry' '/usr/bin/dsh plugin --profile web list'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
