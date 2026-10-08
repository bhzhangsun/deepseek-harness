#!/usr/bin/env bash
# Build the Debian package that installs DeepSeek Harness as a systemd service.
#
# The payload carries the Node.js runtime pinned by
# scripts/primary-runtime/lock.json plus the published @deepseek-ai/dsh
# application tree, so the package depends on no distribution Node.js. Build on
# the target architecture: read the resulting Architecture field rather than
# assuming it, and build arm64 on an arm64 host so npm resolves that
# architecture's optional native packages.
#
# Usage: packaging/debian/build-deb.sh [--arch amd64|arm64] [--version <version>]
#                                    [--maintainer "<name> <email>"] [--out <dir>]
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
lock_file="$repo_root/scripts/primary-runtime/lock.json"

arch=
version=
out=dist-deb
maintainer='bhzhangsun <54729991+bhzhangsun@users.noreply.github.com>'

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) arch=$2; shift 2 ;;
    --version) version=$2; shift 2 ;;
    --maintainer) maintainer=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'build-deb: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# Read one dotted key from a JSON file. The build host owns no Node.js by
# assumption, so python3 is the first choice.
json_value() {
  local file=$1 path=$2
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$path" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2].split('.'):
    value = value[key]
print(value)
PY
  elif command -v node >/dev/null 2>&1; then
    node -e 'const fs = require("node:fs"); let value = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); for (const key of process.argv[2].split(".")) value = value[key]; console.log(value)' "$file" "$path"
  else
    printf 'build-deb: python3 or node is required to read %s\n' "$file" >&2
    return 1
  fi
}

for tool in curl tar dpkg-deb sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'build-deb: %s is required\n' "$tool" >&2; exit 1; }
done

if [ -z "$arch" ]; then
  arch=$(dpkg --print-architecture)
fi
case "$arch" in
  amd64) lock_target=linux-x64 ;;
  arm64) lock_target=linux-arm64 ;;
  *) printf 'build-deb: unsupported architecture %s (expected amd64 or arm64)\n' "$arch" >&2; exit 2 ;;
esac

if [ -z "$version" ]; then
  version=$(json_value "$repo_root/apps/cli/package.json" version)
fi

# Debian upstream versions cannot contain a hyphen, which separates the
# upstream version from the Debian revision. A pre-release suffix sorts before
# its release through `~`, so 0.2.1-alpha.1 becomes 0.2.1~alpha.1.
deb_version=$(printf '%s' "$version" | sed -e 's/-/~/1' -e 's/[^A-Za-z0-9.+~]/./g')

node_version=$(json_value "$lock_file" nodeVersion)
node_archive=$(json_value "$lock_file" "targets.$lock_target.nodeArchive")
node_sha256=$(json_value "$lock_file" "targets.$lock_target.nodeSha256")

work=$(mktemp -d)
staging=$(mktemp -d)
trap 'rm -rf "$work" "$staging"' EXIT

printf 'build-deb: packaging @deepseek-ai/dsh@%s (%s) with Node.js %s\n' "$version" "$arch" "$node_version"

# 1. The pinned Node.js runtime.
node_filename="node-v${node_version}-${node_archive}"
curl -fsSL --retry 3 --retry-delay 2 -o "$work/$node_filename" \
  "https://nodejs.org/dist/v${node_version}/${node_filename}"
printf '%s  %s\n' "$node_sha256" "$work/$node_filename" | sha256sum -c -
mkdir -p "$staging/opt/dsh/node"
tar -xzf "$work/$node_filename" --strip-components=1 -C "$staging/opt/dsh/node"

# 2. The published application closure. The bundled npm resolves the
# architecture's optional native packages, and an unpublished version fails
# here rather than producing a package that cannot start.
mkdir -p "$staging/opt/dsh/app"
PATH="$staging/opt/dsh/node/bin:$PATH" npm install \
  --prefix "$staging/opt/dsh/app" \
  --cache "$work/npm-cache" \
  --omit=dev --no-audit --no-fund --no-package-lock --loglevel=error \
  "@deepseek-ai/dsh@${version}"

entry="$staging/opt/dsh/app/node_modules/@deepseek-ai/dsh/lib/bin.js"
if [ ! -e "$entry" ]; then
  printf 'build-deb: the installed tree has no %s\n' "$entry" >&2
  exit 1
fi

# 3. Package files.
install -d "$staging/DEBIAN" "$staging/usr/bin" "$staging/lib/systemd/system" \
  "$staging/etc/default" "$staging/usr/share/doc/dsh"
install -m 0755 "$script_dir/dsh.launcher" "$staging/usr/bin/dsh"
install -m 0755 "$script_dir/dsh-cli" "$staging/usr/bin/dsh-cli"
install -m 0644 "$script_dir/dsh.service" "$staging/lib/systemd/system/dsh.service"
install -m 0644 "$script_dir/dsh.default" "$staging/etc/default/dsh"
install -m 0644 "$repo_root/LICENSE" "$staging/usr/share/doc/dsh/copyright"
install -m 0755 "$script_dir/postinst" "$staging/DEBIAN/postinst"
install -m 0755 "$script_dir/prerm" "$staging/DEBIAN/prerm"
install -m 0755 "$script_dir/postrm" "$staging/DEBIAN/postrm"
printf '/etc/default/dsh\n' > "$staging/DEBIAN/conffiles"

installed_size=$(du -sk --exclude=DEBIAN "$staging" | cut -f1)

{
  printf 'dsh (%s) unstable; urgency=medium\n\n' "$deb_version"
  printf '  * Package the %s release of @deepseek-ai/dsh with Node.js %s.\n\n' "$version" "$node_version"
  printf -- ' -- %s  %s\n' "$maintainer" "$(date -R)"
} | gzip -9n > "$staging/usr/share/doc/dsh/changelog.Debian.gz"

cat > "$staging/DEBIAN/control" <<EOF
Package: dsh
Version: $deb_version
Architecture: $arch
Maintainer: $maintainer
Installed-Size: $installed_size
Depends: libc6 (>= 2.28), libstdc++6 (>= 6), libgcc-s1, ca-certificates
Recommends: bubblewrap, git, ripgrep
Section: utils
Priority: optional
Homepage: https://github.com/deepseek-ai/deepseek-harness
Description: DeepSeek Harness agent harness, served as a systemd service
 DeepSeek Harness (dsh) is an open-source agent harness built on an
 everything-is-a-plugin architecture.
 .
 This package installs a pinned Node.js runtime and the published
 @deepseek-ai/dsh application beneath /opt/dsh, and runs the Web UI as the
 dsh.service systemd unit. The unit binds 127.0.0.1 only and requires the
 token URL the service prints to its journal for the first browser login.
 The dsh-cli command runs the CLI, through sudo, as that unit's account and
 against its state directory, which is what plugin and profile commands change.
EOF

( cd "$staging" && find . -type f ! -path './DEBIAN/*' -print0 \
  | sort -z | xargs -0 md5sum | sed 's|\./||' ) > "$staging/DEBIAN/md5sums"

# 4. Assemble.
mkdir -p "$out"
package="$out/dsh_${deb_version}_${arch}.deb"
dpkg-deb --build --root-owner-group -Zxz "$staging" "$package" >/dev/null

printf 'build-deb: wrote %s (%s)\n' "$package" "$(du -h "$package" | cut -f1)"
