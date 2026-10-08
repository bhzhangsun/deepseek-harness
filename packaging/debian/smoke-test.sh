#!/usr/bin/env bash
# Install a built package on a systemd host and verify the service serves the
# Web UI.
#
# Run as root. The script is destructive by design: it installs the package,
# starts the unit, then purges the package, which deletes /var/lib/dsh.
#
# Usage: packaging/debian/smoke-test.sh <path to .deb>
set -euo pipefail

package=${1:?usage: smoke-test.sh <path to .deb>}
[ -f "$package" ] || { printf 'smoke-test: no such file: %s\n' "$package" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { printf 'smoke-test: run as root\n' >&2; exit 2; }
[ -d /run/systemd/system ] || { printf 'smoke-test: systemd is not running\n' >&2; exit 2; }

# apt-get reads an argument without a leading slash as a package name and
# reports "Unable to locate package", so resolve the path before installing.
case "$package" in
  /*) ;;
  *) package=$(cd "$(dirname "$package")" && pwd)/$(basename "$package") ;;
esac

fail() { printf 'smoke-test: %s\n' "$1" >&2; exit 1; }

# curl reports a malformed URL as exit 3 and a refused connection as 7; name the
# exit instead of letting set -e end the script without a message.
http_code() {
  code=$(curl -sS -o /dev/null -w '%{http_code}' "$@") \
    || fail "curl exited $? for: $*"
  printf '%s' "$code"
}

printf 'smoke-test: installing %s\n' "$package"
apt-get install -y "$package"

# The unit is Type=simple, so it reports active as soon as the process starts,
# while the Web UI needs longer to print the one-time token URL the browser
# exchanges for its cookie. Wait for that URL: it is the readiness signal and
# the only address the loopback Host check accepts.
printf 'smoke-test: waiting for the launch URL\n'
url=
for _ in $(seq 1 90); do
  if ! systemctl is-active --quiet dsh; then
    systemctl status dsh --no-pager --lines=40 || true
    fail 'dsh.service is not active'
  fi
  url=$(journalctl -u dsh --no-pager 2>/dev/null \
    | grep -oE 'http://127\.0\.0\.1:[0-9]+/\?token=[A-Za-z0-9_-]+' | tail -1 || true)
  if [ -n "$url" ]; then
    break
  fi
  sleep 1
done
[ -n "$url" ] || fail "the service printed no launch URL:
$(journalctl -u dsh --no-pager --lines=40 || true)"
printf 'smoke-test: launch URL %s\n' "$url"

# `?` is a pattern wildcard inside ${...}, so strip the query with an escaped
# one; a bare /?* removes from the first slash and leaves "http:".
base=${url%%\?*}

status=$(http_code "$url")
[ "$status" = 303 ] || fail "the token exchange returned $status, expected 303"

cookie=$(curl -sS -D - -o /dev/null "$url" | sed -n 's/^[Ss]et-[Cc]ookie: \([^;]*\).*/\1/p' | tail -1)
[ -n "$cookie" ] || fail 'the token exchange set no cookie'
status=$(http_code -H "Cookie: $cookie" "$base")
[ "$status" = 200 ] || fail "the authenticated page returned $status, expected 200"

port=$(printf '%s' "$url" | sed -n 's|http://127\.0\.0\.1:\([0-9]*\)/.*|\1|p')
status=$(http_code -X POST \
  -H "Host: localhost:${port}" -H 'content-type: application/json' \
  --data '{"type":"client-request","rpcId":"smoke","method":"settings/describe","payload":{"args":{}}}' \
  "http://127.0.0.1:${port}/api/settings/describe")
[ "$status" = 401 ] || fail "an unauthenticated request returned $status, expected 401"

# The external-access recipe: a tunnel or reverse proxy owns the external leg,
# and the operator advertises the browser-visible authority with --public-url
# and admits it with --trusted-host. systemd splits DSH_WEB_ARGS at whitespace,
# so this also proves the unit passes both options through to the process.
printf 'smoke-test: checking the tunnel and reverse proxy recipe\n'
advertised="dsh-smoke.invalid:${port}"
printf 'DSH_WEB_ARGS=--public-url=http://%s/ --trusted-host=%s\n' \
  "$advertised" "$advertised" >> /etc/default/dsh
systemctl restart dsh

public_url=
for _ in $(seq 1 90); do
  if ! systemctl is-active --quiet dsh; then
    systemctl status dsh --no-pager --lines=40 || true
    fail 'dsh.service is not active with DSH_WEB_ARGS set'
  fi
  public_url=$(journalctl -u dsh --no-pager 2>/dev/null \
    | grep -oE "http://${advertised}/\?token=[A-Za-z0-9_-]+" | tail -1 || true)
  if [ -n "$public_url" ]; then
    break
  fi
  sleep 1
done
[ -n "$public_url" ] || fail "the service advertises no ${advertised} URL, so DSH_WEB_ARGS did not reach dsh web:
$(journalctl -u dsh --no-pager --lines=40 || true)"

# A proxy reaches the loopback port and preserves the browser-facing Host, so
# connect to 127.0.0.1 while naming the advertised authority in Host; that
# header is what the fence compares.
token=${public_url#*token=}
loopback="http://127.0.0.1:${port}/?token=${token}"
status=$(http_code -H "Host: $advertised" "$loopback")
[ "$status" = 303 ] || fail "the token exchange at ${advertised} returned $status, expected 303"
cookie=$(curl -sS -D - -o /dev/null -H "Host: $advertised" "$loopback" \
  | sed -n 's/^[Ss]et-[Cc]ookie: \([^;]*\).*/\1/p' | tail -1)
[ -n "$cookie" ] || fail "the token exchange set no cookie for ${advertised}"
status=$(http_code -H "Cookie: $cookie" -H "Host: $advertised" "http://127.0.0.1:${port}/")
[ "$status" = 200 ] || fail "the authenticated page at ${advertised} returned $status, expected 200"

# The fence admits loopback and every --trusted-host authority; an authority
# that is neither is refused even with a valid cookie.
status=$(http_code -X POST -H "Cookie: $cookie" -H 'Host: untrusted.invalid' \
  -H 'content-type: application/json' \
  --data '{"type":"client-request","rpcId":"smoke","method":"settings/describe","payload":{"args":{}}}' \
  "http://127.0.0.1:${port}/api/settings/describe")
[ "$status" = 403 ] || fail "an untrusted authority returned $status, expected 403"

printf 'smoke-test: purging the package\n'
apt-get purge -y dsh
[ ! -e /lib/systemd/system/dsh.service ] || fail 'the unit file survives a purge'
[ ! -e /var/lib/dsh ] || fail '/var/lib/dsh survives a purge'

printf 'smoke-test: passed\n'
