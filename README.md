# rende-deploy

[English](README.md) | [简体中文](README.zh-CN.md)

Shared reusable GitHub Actions deploy workflow and server receiver for rende.fun sites.

Caller repositories keep a thin wrapper. The wrapper runs tests, then opens SSH and sends one command:

```text
deploy <project> <40-hex-sha>
```

The ECS does the rest. One shared non-root user, `rende-deploy`, accepts that command and nothing else. The server fetches the commit from GitHub, requires it on `main`, builds it, flips a `current` symlink, health-checks, and rolls back on failure.

This repository does not deploy itself. It also does not log into the live server. Installing the receiver is a root step on the ECS, done later, from the files in `server/`.

## Architecture

```text
caller repo (push to main)
  test job on GitHub-hosted runner
  ssh rende-deploy@ECS  deploy <project> $GITHUB_SHA
        |
        v
/usr/local/libexec/rende-deploy/receive-deploy.sh
  read /etc/rende-deploy/projects/<project>.conf
  flock + rate limit
  git fetch github.com  (retries, lowSpeedLimit)
  require sha is on origin/main
  archive into /opt/<tree>/releases/<sha>-<utc>
  build from the root-owned config
  mv the current symlink
  restart that project's systemd unit or PM2 app
  health check, or switch current back
  prune old releases
```

Isolation is per directory, per unit, and per config file. It is not per Linux account. One deploy key is installed for `rende-deploy` and copied into each caller as the same four secrets. A later split into one account per project is possible; nothing here requires it.

| Project id | App | Tree | How it runs | Health the receiver uses |
| --- | --- | --- | --- | --- |
| `site` | rende-site | `/opt/site` | static files, no process | `dist/index.html` exists |
| `recipes` | enamel-recipes | `/opt/caiben` | systemd `caiben` | `http://127.0.0.1:3030/recipes/api/health` body `{"ok":true}` |
| `shutter` | shutter-count | `/opt/shutter-count` | PM2 `shutter-count` | `http://127.0.0.1:3020/shutter` returns 200 |
| `easypic` | easy-ncp-pic | `/opt/easypic` | PM2 `easypic-api` | `http://127.0.0.1:3010/api/health` returns 200 |

Those ids are the SSH command's `<project>`. The directory name stays whatever production already uses.

## What the SSH session can do

sshd `ForceCommand` is the receiver. The account's shell is the same script. `SSH_ORIGINAL_COMMAND` must match:

```text
deploy <project> <40-hex-sha>
```

`<project>` is `[a-z][a-z0-9-]{0,31}`. The sha is 40 lowercase hex digits. Extra arguments, a short sha, a branch name, and any other program are rejected before a config file is read. The script does not `eval` the command.

The receiver will not run as root. Config files must be owned by root and not group/world writable. `build` is taken from that config and is the only shell the receiver runs. The charset blocks `$()`, backticks, `;`, and redirects. It is not a sandbox: review changes to `main` and to `/etc/rende-deploy/projects`.

GitHub fetch uses the same knobs as the current caiben receiver, because fetch from this ECS is flaky: up to 5 attempts, `timeout 300`, `http.lowSpeedLimit=1000`, `http.lowSpeedTime=60`, and a 10/20/30/40 second backoff. User and system git config are ignored so `~/.gitconfig` cannot rewrite the URL. `~/.npmrc` is not read.

Each project has its own `flock` (`<root>/.deploy.lock`, wait up to 10 minutes) and its own rate limit (`min_interval`, default 30 seconds, stamped when a deploy starts). GitHub Actions concurrency uses `cancel-in-progress: false`, so a newer push waits. It does not abort the one already on the server.

On success the script prints `Deployed <project> <sha>`. `current` points at the release directory. `previous` points at the release that was current before. A failed build never moves `current`. A failed health check or process restart points `current` back at `previous` and deletes the failed release. The first deploy has nothing to restore, so a failed health check removes `current`. Releases except `current` and `previous` are pruned to `keep` (default 5). Each release contains `REVISION`. If `publish_subdir` is set, the same sha is also written to `<publish_subdir>/REVISION`.

Persistent data stays outside `releases/`. The receiver does not copy `.env`, sqlite files, or nginx config. `env_file` may symlink an existing file under the project root or `/etc` to `<release>/.env` when an app reads dotenv from its cwd.

## Caller workflow

Pin the reusable workflow by branch in the caller, the same way the other rende.fun repos call shared code:

```yaml
uses: rendeyuwei/rende-deploy/.github/workflows/deploy-project.yml@main
```

The copy-paste wrapper is [`docs/caller-workflow.yml`](docs/caller-workflow.yml). Trigger it on `push` to `main` and `workflow_dispatch` only. Do not run it on `pull_request`. Set the caller's concurrency group to `cancel-in-progress: false`.

Inputs:

| Input | Default | Role |
| --- | --- | --- |
| `project` | required | Server config id |
| `node_version` | `22` | Runner Node. Numeric, such as `22` or `22.12.0` |
| `health_url` | empty | Public `https://` check after SSH. Empty skips it |
| `health_body` | empty | Exact body for that check |
| `cache` | `npm` | `npm`, `yarn`, or `pnpm` |
| `setup_command` | empty | For example `corepack enable` |
| `install_command` | `npm ci --no-audit --no-fund` | Empty skips |
| `test_command` | `npm test` | Empty skips |
| `build_command` | `npm run build` | Runner build. The server build is the config file |

The server build does not follow these inputs. Changing the runner command does not change what the ECS compiles.

Secrets, set on each caller repository (a personal account cannot share them). Use the same values everywhere:

| Secret | Value |
| --- | --- |
| `ECS_HOST` | ECS host or IP, checked against the console |
| `ECS_USER` | `rende-deploy` |
| `ECS_SSH_KEY` | Private key for that user |
| `ECS_KNOWN_HOSTS` | Host key line you compared with the console, not a blind `ssh-keyscan` |

There is no `DEPLOY_ENABLED` variable. A successful test on `main` deploys. A caller invoked off `main` fails the deploy job instead of quietly skipping it.

Third-party actions in this repo are pinned to full commit SHAs (`actions/checkout` v7.0.1, `actions/setup-node` v7.1.0). The SSH step is plain `ssh`, not a marketplace action.

## Install on the ECS

Run this as root, from a checkout of the commit you have read. It creates the user, copies the receiver to `/usr/local/libexec/rende-deploy/receive-deploy.sh`, and installs example configs only when the destination is missing. It does not reload ssh, does not restart caiben, shutter, or easypic, and does not `chown` an existing `/opt/*` tree.

```bash
sudo bash server/install.sh
```

`sudo bash server/install.sh --sshd` also copies `server/examples/sshd/rende-deploy.conf` to `/etc/ssh/sshd_config.d/rende-deploy.conf` and runs `sshd -t`. If the test fails, the drop-in is removed. Either way, ssh is not reloaded. Reload only after you have read the diff:

```bash
sudo sshd -t && sudo systemctl reload ssh
```

Then, still as root:

1. Review `/etc/rende-deploy/projects/*.conf`. The examples match the four apps above. Edit a build line before the first deploy of that app. Installing the file does not deploy anything.
2. Create a dedicated key on your own machine: `ssh-keygen -t ed25519 -f rende-deploy -C rende-deploy`.
3. Put one line in `/etc/ssh/authorized_keys/rende-deploy` (mode `0600`, root-owned), using the prefix in `server/examples/authorized_keys.example`:

   ```text
   restrict,command="/usr/local/libexec/rende-deploy/receive-deploy.sh" ssh-ed25519 AAAA... rende-deploy
   ```

4. Store the private key as `ECS_SSH_KEY` in each caller. Store the user `rende-deploy`, the host, and the host key you verified from the ECS console.
5. Confirm the app unit executes the `current` symlink. `server/install.sh` does not install unit files. `server/examples/systemd/caiben.service` is a reference: the unit in the enamel-recipes repo still has `WorkingDirectory=/opt/caiben` and an `ExecStart` that does not mention `current`. Compare with `systemctl cat caiben` before replacing anything. Leave `User=caiben` unless you also move `/opt/caiben/.env` and the sqlite directory.
6. `/etc/sudoers.d/rende-deploy` allows only `systemctl restart caiben`. Add a unit only by editing that file with `visudo`. PM2 apps are restarted as `rende-deploy` and do not need sudo.
7. Reject a bad command before you trust the key:

   ```bash
   sudo -u rende-deploy /usr/local/libexec/rende-deploy/receive-deploy.sh 'echo hello'
   ```

   Expect `expected: deploy <project> <40-hex-sha>`.

Node 22 must already be on `PATH` for the deploy user, or set `path_extra` to a directory that exists. The shutter example points at `/opt/node-v22.23.2-linux-x64/bin`. `python3`, `make`, and `g++` stay required for `better-sqlite3` in enamel-recipes. When `node.h` is installed next to that Node, the receiver sets `npm_config_nodedir` so native modules do not download headers from nodejs.org.

Logs of rejected and failed deploys append to `<root>/log/failures.log`. The SSH client also sees the error text.

## Per-project cutover

Do these one app at a time, after the receiver is installed. Do not point a caller at `deploy-project.yml` until that app's process manager follows `current`.

**site.** `service=none`. The build is `npm ci --no-audit --no-fund && npm run build`. nginx's apex `location /` for `rende.fun` still uses `root /var/www/html`. After the first deploy has created `/opt/site/current/dist`, change that one location as in `server/examples/nginx/site-root.conf`, without dropping the easypic, shutter, or recipes includes. Then set `health_url=https://rende.fun/` in the project config and in the caller. Leave it unset until then: a public 200 from the old document root would not prove this release is the one being served, and a 404 would roll the release back.

**recipes.** Build is `npm ci` and `npm run build`. Restart is `sudo -n systemctl restart caiben`. Health is the loopback URL and the exact body `{"ok":true}`. Keep `EnvironmentFile=/opt/caiben/.env` and an absolute `DATA_DIR` outside `releases/`. The runtime user can stay `caiben`; world-readable release files are enough for it to execute `tsx`. The existing `caiben-deploy` SSH account can be retired only after a deploy through `rende-deploy` has passed this health check.

**shutter.** PM2 app name is `shutter-count`. The example ecosystem `server/examples/pm2/shutter-count.cjs` uses `cwd` `/opt/shutter-count/current` and `script` `bin/start.mjs`. The repo's `npm start` is `node dist/src/main.js`. Use the path `pm2 show shutter-count` actually runs, then `pm2 startOrRestart` that ecosystem as `rende-deploy` with `PM2_HOME=/opt/shutter-count/.pm2`. The boot unit `server/examples/systemd/pm2-shutter-count.service` is optional and is not installed automatically. The live shutter receiver also checks the GitHub Actions run id; this shared receiver does not. Cut over only when the loopback check on port 3020 is enough.

**easypic.** The live process is root's PM2 app `easypic-api` on `127.0.0.1:3010`. nginx serves HTML from `/var/www/easypic`, not from the release tree. This receiver restarts PM2 from `/opt/easypic/current` and does not rsync into `/var/www`. Static files stay stale until the nginx locations point at the release (or you add a copy step you are willing to let this user run). `/etc/easypic/easypic.env` is mode `0600` root; `deploy/start-api.sh` sources it, so `rende-deploy` must be able to read it before the new PM2 daemon will start. Leave the root PM2 process in place until that cutover.

## Onboard another project

1. Pick a project id (`[a-z][a-z0-9-]{0,31}`) and a real directory `/opt/<name>` owned by `rende-deploy` (or writable by it). Do not reuse another app's directory.
2. Add `/etc/rende-deploy/projects/<id>.conf`. Required keys: `root`, `repo_url`, `service`, `build`, and at least one of `health_url` or `health_file`. `repo_url` is `https://github.com/<owner>/<repo>.git`. The branch is always `main`.
3. `service` is `none`, `systemd`, or `pm2`.
   - `systemd` needs `unit`. The unit name must be listed in `/etc/sudoers.d/rende-deploy`.
   - `pm2` needs `pm2_app` and `pm2_home` inside `root`. Optional `pm2_ecosystem` must live under `/etc/rende-deploy/pm2/` or inside `root`, and must already exist.
4. Put a wrapper workflow in the app repo. Reuse the four `ECS_*` secrets.
5. Deploy once and read `Deployed <id> <sha>` plus the health check. Confirm `readlink -f /opt/<name>/current` is the new release and that `previous` still starts.

Config keys: `publish_subdir`, `health_body`, `health_attempts` (default 30), `health_timeout` (default 3 seconds), `keep`, `min_interval`, `env_file`, `path_extra`. Unknown keys are rejected.

## Develop this repo

```bash
bash server/tests/receive-deploy.test.sh
shellcheck server/receive-deploy.sh server/install.sh server/tests/receive-deploy.test.sh
```

The tests cover command parsing, config rejection, a static deploy, build failure, health-file failure, HTTP health with an exact body, rollback, a sha that is no longer on `main`, the rate limit, `flock`, pruning, fetch retries, and a poisoned `~/.gitconfig`. They do not SSH anywhere. Test mode is refused when `SSH_CONNECTION` is set.

GitHub fetch backoff is skipped in test mode so retries stay instant. Production waits `attempt * 10` seconds between fetches.
