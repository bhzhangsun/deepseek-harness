# packaging/ — Debian system service package

This directory builds a Debian package that installs DeepSeek Harness as a systemd service. It is fork-local packaging, not part of the upstream tree: upstream currently does not accept external pull requests ([CONTRIBUTING.md](../CONTRIBUTING.md)), so the package is published from a fork or from a separate repository rather than merged here.

## What the package installs

| Path | Contents |
|---|---|
| `/opt/dsh/node` | The Node.js runtime pinned by [`scripts/primary-runtime/lock.json`](../scripts/primary-runtime/lock.json) |
| `/opt/dsh/app` | `@deepseek-ai/dsh@<version>` and its dependency closure, installed from the npm registry |
| `/usr/bin/dsh` | Launcher that runs the bundled runtime against the installed entry point |
| `/lib/systemd/system/dsh.service` | The service unit |
| `/etc/default/dsh` | Configuration file the unit reads (a `conffile`, so an upgrade keeps your edits) |
| `/var/lib/dsh` | State: sessions, settings, and the browser credential file, owned by the `dsh` service account |

The package depends on no distribution Node.js, where no supported release exists: `engines` requires Node `^22.19.0 || >=24.0.0`, while current Debian and Ubuntu stable releases ship Node 18 or 20.

## Build

Run on the architecture you are packaging. npm resolves that architecture's optional native packages, so an amd64 host cannot produce a correct arm64 payload without emulation.

```sh
packaging/debian/build-deb.sh --arch "$(dpkg --print-architecture)" --out dist-deb
```

`--version` defaults to the version in [`apps/cli/package.json`](../apps/cli/package.json) and must name a version already published to npm. `--maintainer` sets the `Maintainer` field. The build requires `python3` or `node`, `curl`, `tar`, `dpkg-deb`, and `sha256sum`; it verifies the Node.js archive against the hash in the lock file before unpacking it.

## Continuous integration

[`.github/workflows/deb.yml`](../.github/workflows/deb.yml) builds amd64 on `ubuntu-24.04` and arm64 on `ubuntu-24.04-arm`, uploads both packages as artifacts, then installs the amd64 package on a systemd host and runs the smoke test. It triggers on a manual dispatch, on a non-master branch push that touches this directory, and on a `dsh-deb-v*` tag. Note that GitHub only offers manual dispatch for a workflow that exists on the default branch, so the first build happens on push.

## Verify by hand

On any systemd host, as root:

```sh
packaging/debian/smoke-test.sh dist-deb/dsh_0.2.1~alpha.1_amd64.deb
```

The script installs the package, waits for `dsh.service`, extracts the launch URL from the journal, and checks the four responses the service is expected to give: `303` for the token exchange, a `Set-Cookie` on that exchange, `200` for the authenticated page, and `401` for an unauthenticated request. It then sets `DSH_WEB_ARGS` to a stand-in public URL, restarts the service, and repeats the exchange under that advertised authority, which must answer `200` while an untrusted authority answers `403`. Finally it purges the package and checks that the unit file and `/var/lib/dsh` are gone. The script deletes `/var/lib/dsh`, so run it on a throwaway host.

## Operate

```sh
systemctl status dsh                                  # is the service running
journalctl -u dsh | grep -o 'http://127\.0\.0\.1:[0-9]*/?token=[^ ]*' | tail -1
```

Open that URL once to exchange the token for the browser cookie; the credential persists in `/var/lib/dsh/.credentials.yaml` (mode `0600`), so later restarts do not need a new token.

## Reach the Web UI from another device

The unit binds `127.0.0.1`, and `dsh web --host 0.0.0.0` is refused:

```
error: --host 0.0.0.0 is intentionally not supported yet for safety: it would expose remote code execution to the network; use 127.0.0.1 instead
```

The Web UI runs commands and serves no TLS, authentication, or origin policy of its own, so an external leg belongs to a tunnel or reverse proxy. The one that exposes nothing needs no configuration:

```sh
ssh -L 3080:127.0.0.1:3080 you@host
```

Then open `http://127.0.0.1:3080/?token=<the token from the remote journal>`.

A tunnel or proxy that does publish the UI must forward to the loopback port and preserve the browser-facing `Host`. `DSH_WEB_ARGS` in `/etc/default/dsh` carries the two options such a deployment needs:

```sh
DSH_WEB_ARGS=--public-url=https://nas.example.ts.net/ --trusted-host=nas.example.ts.net
```

`--public-url` supplies the printed launch URL and `DSH_WEB_URL`; it grants no trust. `--trusted-host` is what the request fence accepts, and a browser reaching the deployment under any other authority gets `403` on every API call however correct the tunnel or proxy is. A port-less entry matches any port, which suits a tunnel that binds a different one each time. The launch token and the signed session cookie still authenticate the request. systemd splits `DSH_WEB_ARGS` at whitespace, so pass one `--flag=value` per word.

A private HTTPS endpoint (Tailscale Serve) or a public one (a `cloudflared` tunnel) provides that external leg without proxy configuration of your own. Terminate TLS there: an `http://` root sends the launch token and the session cookie unencrypted, and the printed URL carries a process credential, so share it only with intended users.

### A login gate instead of a shared token

A tunnel or proxy authenticates nobody: the launch token is a process credential, and anyone who reads it can run commands. The third-party [`@xgone/dsh-remote`](https://github.com/xgone/dsh-remote) plugin (MIT) puts a login gate with TOTP in front of every path, and rewrites an authenticated request's `Host` to the loopback authority so the request fence admits its `/api` and WebSocket calls. That removes the need for `--trusted-host` and for proxy configuration of your own; a tunnel to the loopback port is still required, because the service binds `127.0.0.1`.

```sh
sudo -u dsh env HOME=/var/lib/dsh DSH_HOME=/var/lib/dsh \
  /usr/bin/dsh plugin --profile web add @xgone/dsh-remote
sudo systemctl restart dsh
```

The first administrator can be created only from loopback: reach the port over `ssh -L` and create the account in the browser, or set `bootstrap` in `/var/lib/dsh/profiles/web/cordis.patch.yml` for a host without a browser, then remove the plaintext password after the first login. Set `session.secure: true` once the tunnel serves HTTPS. The plugin is third-party and tracks DSH releases, so check its changelog before upgrading the package.

The unit sets `DSH_HOME=/var/lib/dsh` and `HOME=/var/lib/dsh`, denies new privileges, gives the service a private `/tmp`, and mounts the system read-only. `ProtectHome=read-only` blocks `/home`, so a harness that must edit files there needs that directive relaxed. Relocating `DSH_HOME` in `/etc/default/dsh` also requires adding the new path to `ReadWritePaths`.

Set the model provider key in `/etc/default/dsh` (`DEEPSEEK_API_KEY=...`, then `chmod 600 /etc/default/dsh`), or store it through the Web UI, which keeps it in the credentials file under `DSH_HOME` instead. Commands the agent runs are confined by the process sandbox, which on Linux needs `bubblewrap` or a Landlock-enforcing kernel; without either, confined commands fail closed. The package recommends `bubblewrap`.

## Remove

```sh
apt-get remove dsh      # stops and disables the service, keeps /var/lib/dsh
apt-get purge dsh       # also deletes /var/lib/dsh, including sessions and credentials
deluser dsh             # the service account survives a purge
```

## Limitations

- The artifact is unsigned and no APT repository is published; install it with an explicit path.
- The Node.js version follows `scripts/primary-runtime/lock.json`, so raising it is a change to that file rather than to this packaging.
- The payload is the published npm release. A version that is not on the registry fails the build instead of producing a package that cannot start.
- The unit runs the Web UI only. Headless and SDK profiles are reachable through `/usr/bin/dsh` with the same runtime.
