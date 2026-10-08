# packaging/ — Debian system service package

This directory builds a Debian package that installs DeepSeek Harness as a systemd service. It is fork-local packaging, not part of the upstream tree: upstream currently does not accept external pull requests ([CONTRIBUTING.md](../CONTRIBUTING.md)), so the package is published from a fork or from a separate repository rather than merged here.

## What the package installs

| Path | Contents |
|---|---|
| `/opt/dsh/node` | The Node.js runtime pinned by [`scripts/primary-runtime/lock.json`](../scripts/primary-runtime/lock.json) |
| `/opt/dsh/app` | `@deepseek-ai/dsh@<version>` and its dependency closure, installed from the npm registry |
| `/usr/bin/dsh` | Launcher that runs the bundled runtime against the installed entry point |
| `/usr/bin/dsh-cli` | Runs that launcher, under `sudo`, as the service account and against the service state, for plugin and profile commands; its `user` subcommand creates a per-account home the service account can reach |
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

### A directory another account owns

The service account opens a directory as its own uid, so a directory owned by someone else needs a grant on it. `dsh-cli user` supplies the three parts of one: the directory, an entry point under the service account's home, and the ACL.

```sh
sudo dsh-cli user add alice                     # create the account and its home
sudo dsh-cli user add bhzhangsun --base /home   # adopt a login account that exists
sudo dsh-cli user list
sudo dsh-cli user revoke bhzhangsun             # drop the grant, keep the account
sudo dsh-cli user remove alice --purge          # delete an account it created
```

The default home is `<DSH_HOME>/users/<name>`, mode `0750` and owned by that account, linked at `<DSH_HOME>/<name>` as the path the agent reads as `~/<name>`. Pointing `--base` at an existing home's parent adopts that home instead: the account and the directory stay as they are, with neither owner nor mode changed, and only the grant is applied.

| `--share` | Grant | Takes effect |
|---|---|---|
| `acl` (default) | `u:dsh:rwX` as a named ACL on the home, plus the same as a default ACL so files the account creates later stay reachable | at the next open: no restart |
| `group` | the service account joins `<name>`'s private group, the home gains the setgid bit, and a default group ACL carries the write bit to new files | after `sudo systemctl restart dsh`: a running unit keeps the supplementary groups it started with |

The base directory is root-owned, so the service account may write inside each home but cannot remove or replace one. `add` then reports what that account can actually do, opening the home as the service account's own uid, so a grant that quietly failed does not read back as success. `--read-only` grants `rX` instead of `rwX`, and `--dry-run` prints the exact command sequence without running it.

Two things stay outside this command. The unit mounts `/home` read-only (`ProtectHome=read-only`, see below), so a home there needs one unit exception before writes work; the check above is what reports it, and `add` names the exception. And the agent's own sandbox reaches only the directories registered as workspaces, so add that home as a workspace in the Web UI too. `revoke` drops the link, the ACL entries and the group membership while keeping the account and every file; `remove` deletes an account only when its home is inside the default base, and otherwise names `revoke` and `--force` instead of deleting a login account.

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

The package carries the pinned Node runtime and the published application closure. `dsh plugin` forwards its arguments to `pnpm`, which it resolves through `PATH` and which the package does not carry, so install pnpm once with the bundled npm before managing plugins. Name the install directory: npm's global prefix is not necessarily the runtime's own directory, and the shim below is the one inside the runtime's `bin`. That shim carries an `env node` shebang while the service account's `PATH` has no node, so put the bundled runtime in front of the call:

```sh
sudo /opt/dsh/node/bin/npm install -g --prefix /opt/dsh/node pnpm@11.7.0   # the version package.json pins
sudo tee /usr/local/bin/pnpm >/dev/null <<'EOF'
#!/bin/sh
exec env PATH="/opt/dsh/node/bin:$PATH" /opt/dsh/node/bin/pnpm "$@"
EOF
sudo chmod 0755 /usr/local/bin/pnpm
```

Then install the plugin through `dsh-cli`, which reads the account and state directory off the unit and runs the CLI there. It switches accounts, so it needs root: run it under `sudo`, and it refuses any other unprivileged caller rather than writing a state tree the service never reads.

```sh
sudo dsh-cli plugin --profile web add @xgone/dsh-remote
sudo systemctl restart dsh
```

`/usr/bin/dsh` run from your own shell would use `$HOME/.dsh` instead, and installing as root leaves `$DSH_HOME/auth/store.json` owned by root, so the service account cannot create the first account. A plugin change takes effect on the next restart; the running service does not have to be stopped first.

A plugin command that reports `EACCES` never reached pnpm: it resolved an executable the service account cannot reach, either one under a home directory the account cannot traverse (Ubuntu creates `0750` homes, so another user's home is closed to it) or a shim whose `env node` shebang finds no node on that account's `PATH`. Installing pnpm into the runtime as above avoids both, and `dsh-cli` drops `XDG_CONFIG_HOME` with its siblings so pnpm's configuration, cache, and state stay under the account's own home rather than the caller's.

`sudo` asks for your own password, once per terminal within its timestamp window. An unattended install needs one rule, naming this command and nothing else:

```sh
printf '%s ALL=(ALL) NOPASSWD: /usr/bin/dsh-cli\n' "$USER" | sudo tee /etc/sudoers.d/dsh-cli
sudo chmod 0440 /etc/sudoers.d/dsh-cli
sudo visudo -c

sudo -K                                    # drop the cached timestamp
sudo -n dsh-cli plugin --profile web list  # proves the exemption covers the arguments an install passes
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
- `dsh-cli user` creates real accounts outside the package's own footprint, so `apt-get purge` leaves them and their homes behind; remove them with `dsh-cli user remove --purge` first if the host must not keep them.
