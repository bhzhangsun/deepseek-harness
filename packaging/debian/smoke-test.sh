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

status=$(curl -s -o /dev/null -w '%{http_code}' "$url")
[ "$status" = 303 ] || fail "the token exchange returned $status, expected 303"

cookie=$(curl -s -D - -o /dev/null "$url" | sed -n 's/^[Ss]et-[Cc]ookie: \([^;]*\).*/\1/p' | tail -1)
[ -n "$cookie" ] || fail 'the token exchange set no cookie'
status=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $cookie" "${url%%/?*}/")
[ "$status" = 200 ] || fail "the authenticated page returned $status, expected 200"

port=$(printf '%s' "$url" | sed -n 's|http://127\.0\.0\.1:\([0-9]*\)/.*|\1|p')
status=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H "Host: localhost:${port}" -H 'content-type: application/json' \
  --data '{"type":"client-request","rpcId":"smoke","method":"settings/describe","payload":{"args":{}}}' \
  "http://127.0.0.1:${port}/api/settings/describe")
[ "$status" = 401 ] || fail "an unauthenticated request returned $status, expected 401"

printf 'smoke-test: purging the package\n'
apt-get purge -y dsh
[ ! -e /lib/systemd/system/dsh.service ] || fail 'the unit file survives a purge'
[ ! -e /var/lib/dsh ] || fail '/var/lib/dsh survives a purge'

printf 'smoke-test: passed\n'
