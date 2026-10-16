# rende-deploy

[English](README.md) | [简体中文](README.zh-CN.md)

rende.fun 各站点共用的 GitHub Actions 部署工作流，以及 ECS 上的接收脚本。

调用方仓库只留一个薄包装：先在 GitHub 上跑测试，再通过 SSH 发送唯一一条命令：

```text
deploy <project> <40位十六进制 sha>
```

其余都在 ECS 上完成。全机只有一个非 root 部署用户 `rende-deploy`，它只接受这条命令。服务器自己从 GitHub 拉取该提交，确认它在 `main` 上，再构建、原子切换 `current` 符号链接、做健康检查，失败则回滚。

本仓库不会部署自己，也不会登录现网。把接收器装到 ECS 上是之后由 root 执行的步骤，材料在 `server/`。

## 结构

```text
调用方仓库（推到 main）
  GitHub 托管 runner 上的 test
  ssh rende-deploy@ECS  deploy <project> $GITHUB_SHA
        |
        v
/usr/local/libexec/rende-deploy/receive-deploy.sh
  读取 /etc/rende-deploy/projects/<project>.conf
  flock + 限流
  git fetch github.com（重试，lowSpeedLimit）
  要求 sha 在 origin/main 上
  解包到 /opt/<目录>/releases/<sha>-<utc>
  按 root 拥有的配置构建
  切换 current 符号链接
  重启该项目自己的 systemd 单元或 PM2 进程
  健康检查，失败则把 current 指回去
  删掉过旧的 release
```

隔离单位是目录、进程单元和配置文件，不是 Linux 账号。一把部署公钥装在 `rende-deploy` 上，四个 secret 以相同的值写进每个调用方仓库。以后若要改成一项目一账号，不需要这套协议先支持。

| 项目 id | 应用 | 目录 | 运行方式 | 接收器使用的健康检查 |
| --- | --- | --- | --- | --- |
| `site` | rende-site | `/opt/site` | 静态文件，无进程 | 存在 `dist/index.html` |
| `recipes` | enamel-recipes | `/opt/caiben` | systemd `caiben` | `http://127.0.0.1:3030/recipes/api/health` 正文 `{"ok":true}` |
| `shutter` | shutter-count | `/opt/shutter-count` | PM2 `shutter-count` | `http://127.0.0.1:3020/shutter` 返回 200 |
| `easypic` | easy-ncp-pic | `/opt/easypic` | PM2 `easypic-api` | `http://127.0.0.1:3010/api/health` 返回 200 |

SSH 命令里的 `<project>` 是上表的 id。目录名保持现网已经在用的名字。

## SSH 会话能做什么

sshd 的 `ForceCommand` 就是接收器。该账号的登录 shell 也是同一个脚本。`SSH_ORIGINAL_COMMAND` 必须匹配：

```text
deploy <project> <40位十六进制 sha>
```

`<project>` 匹配 `[a-z][a-z0-9-]{0,31}`。sha 是 40 位小写十六进制。多出来的参数、短 sha、分支名、其他程序，都会在读取配置之前被拒绝。脚本不会 `eval` 这条命令。

接收器拒绝以 root 运行。配置文件必须属主为 root，且不能被组或其他用户写入。`build` 来自这份配置，是接收器唯一会执行的 shell。字符集拦住 `$()`、反引号、`;` 和重定向。这不是沙箱：`main` 分支和 `/etc/rende-deploy/projects` 的改动都要审。

从这台 ECS 拉取 GitHub 不稳定，因此 fetch 与现网 caiben 接收器使用同一组参数：最多 5 次，`timeout 300`，`http.lowSpeedLimit=1000`，`http.lowSpeedTime=60`，退避 10/20/30/40 秒。用户和系统的 git 配置被忽略，`~/.gitconfig` 不能改写 URL。`~/.npmrc` 也不会被读取。

每个项目有自己的 `flock`（`<root>/.deploy.lock`，最多等 10 分钟）和自己的限流（`min_interval`，默认 30 秒，在一次部署开始时盖章）。GitHub Actions 的并发是 `cancel-in-progress: false`：新的 push 会等，不会取消已经在服务器上跑的那次。调用方工作流不能使用并发组 `rende-deploy-<project>`。这个名字属于可复用工作流，再用一次会把部署死锁住。

成功时打印 `Deployed <project> <sha>`。`current` 指向这次的 release 目录。`previous` 指向切换前的那一次。构建失败不会移动 `current`。健康检查或进程重启失败时，把 `current` 指回 `previous`，并删除失败的 release。第一次部署没有可恢复的版本，失败时会去掉 `current`。除 `current` 和 `previous` 之外，只保留最新的 `keep` 份（默认 5）。每个 release 里有 `REVISION`。配置了 `publish_subdir` 时，同一 sha 也会写到 `<publish_subdir>/REVISION`。

持久数据放在 `releases/` 外面。接收器不复制 `.env`、sqlite 或 nginx 配置。若应用从工作目录读 dotenv，可以用 `env_file` 把项目根目录或 `/etc` 下已有的文件符号链接为 `<release>/.env`。

## 调用方工作流

在调用方里按分支引用可复用工作流：

```yaml
uses: rendeyuwei/rende-deploy/.github/workflows/deploy-project.yml@main
```

可直接复制的包装在 [`docs/caller-workflow.yml`](docs/caller-workflow.yml)。只在 `main` 的 `push` 和 `workflow_dispatch` 上触发，不要挂 `pull_request`。调用方自己的 concurrency 保持 `cancel-in-progress: false`，并且组名不能是 `rende-deploy-<project>`。`deploy-project.yml` 已经使用 `rende-deploy-<project>`。调用方再用同一个组时，调用方等被调用的工作流，被调用的工作流等调用方，部署不会开始。

| 输入 | 默认 | 作用 |
| --- | --- | --- |
| `project` | 必填 | 服务器上的配置 id |
| `node_version` | `22` | runner 上的 Node。只能是数字，例如 `22` 或 `22.12.0` |
| `health_url` | 空 | SSH 成功后从 runner 发的公网 `https://` 检查。空则跳过 |
| `health_body` | 空 | 该检查的精确正文 |
| `cache` | `npm` | `npm`、`yarn` 或 `pnpm` |
| `setup_command` | 空 | 例如 `corepack enable` |
| `install_command` | `npm ci --no-audit --no-fund` | 空则跳过 |
| `test_command` | `npm test` | 空则跳过 |
| `build_command` | `npm run build` | runner 上的构建。服务器构建以配置文件为准 |

服务器不会跟着这些输入改构建命令。改 runner 上的命令不会改变 ECS 编译什么。

Secret 写在每个调用方仓库里（个人账号不能共享 secret）。各仓库填同一组值：

| Secret | 内容 |
| --- | --- |
| `ECS_HOST` | ECS 主机名或 IP，与控制台核对过 |
| `ECS_USER` | `rende-deploy` |
| `ECS_SSH_KEY` | 该用户的私钥 |
| `ECS_KNOWN_HOSTS` | 与控制台比对过的主机公钥行，不要直接信任一次盲目的 `ssh-keyscan` |

没有 `DEPLOY_ENABLED` 这类开关。`main` 上测试通过就会部署。不在 `main` 上调用时，部署作业失败，而不是静默跳过。

本仓库里的第三方 action 钉死到完整 commit SHA（`actions/checkout` v7.0.1，`actions/setup-node` v7.1.0）。SSH 步骤是系统自带的 `ssh`，不用 marketplace action。

## 在 ECS 上安装

用你读过的那个提交，在 ECS 上以 root 运行。它会创建用户，把接收器复制到 `/usr/local/libexec/rende-deploy/receive-deploy.sh`，并且只在目标不存在时安装示例配置。它不会 reload ssh，不会重启 caiben、shutter 或 easypic，也不会 `chown` 已经存在的 `/opt/*` 目录。

```bash
sudo bash server/install.sh
```

`sudo bash server/install.sh --sshd` 会额外把 `server/examples/sshd/rende-deploy.conf` 复制到 `/etc/ssh/sshd_config.d/rende-deploy.conf` 并执行 `sshd -t`。测试失败时 drop-in 会被删掉。无论成功与否都不会 reload ssh。看过 diff 之后再：

```bash
sudo sshd -t && sudo systemctl reload ssh
```

然后仍然以 root：

1. 审阅 `/etc/rende-deploy/projects/*.conf`。示例对上表四个应用。某个应用第一次部署前先改它的 build 行。装上文件本身不会触发部署。
2. 在你自己的机器上生成专用密钥：`ssh-keygen -t ed25519 -f rende-deploy -C rende-deploy`。
3. 在 `/etc/ssh/authorized_keys/rende-deploy`（属主 root，模式 `0644`；sshd 以目标用户身份读取该文件，root 所有的 `0600` 会导致登录 Permission denied）放一行，前缀见 `server/examples/authorized_keys.example`：

   ```text
   restrict,command="/usr/local/libexec/rende-deploy/receive-deploy.sh" ssh-ed25519 AAAA... rende-deploy
   ```

4. 把私钥存进每个调用方的 `ECS_SSH_KEY`。用户名是 `rende-deploy`。主机和主机公钥用 ECS 控制台上核对过的值。
5. 确认应用单元执行的是 `current` 符号链接。`server/install.sh` 不安装 unit 文件。`server/examples/systemd/caiben.service` 只是对照：enamel-recipes 仓库里的单元仍然是 `WorkingDirectory=/opt/caiben`，`ExecStart` 也没有 `current`。替换前先 `systemctl cat caiben`。除非同时搬走 `/opt/caiben/.env` 和 sqlite 目录，否则保持 `User=caiben`。
6. `/etc/sudoers.d/rende-deploy` 只允许 `/usr/bin/systemctl restart -- caiben`。接收器会带上 `--`，没有 `--` 的那一行对不上。要增加单元，用 `visudo` 改这个文件。`install.sh` 不会改写已经存在的 sudoers 文件。PM2 应用由 `rende-deploy` 自己重启，不需要 sudo。PM2 应用的开机单元见 `server/examples/systemd/pm2-<project>.service`：`User=rende-deploy`，`PM2_HOME=/opt/<project>/.pm2`。`install.sh` 不安装 unit 文件。
7. 在信任这把密钥之前先拒绝一条坏命令：

   ```bash
   sudo -u rende-deploy /usr/local/libexec/rende-deploy/receive-deploy.sh 'echo hello'
   ```

   应看到 `expected: deploy <project> <40-hex-sha>`。

部署用户的 `PATH` 上需要已有 Node 22，或者把 `path_extra` 指到一个存在的目录。shutter 示例指向 `/opt/node-v22.23.2-linux-x64/bin`。enamel-recipes 的 `better-sqlite3` 仍然需要 `python3`、`make` 和 `g++`。若该 Node 旁边有 `node.h`，接收器会设置 `npm_config_nodedir`，避免从 nodejs.org 下载头文件。

被拒绝和失败的部署会追加到 `<root>/log/failures.log`。SSH 客户端也能看到错误文本。

## 逐个项目切换

接收器装好之后，一次只切一个应用。在该应用的进程管理确实跟着 `current` 走之前，不要把调用方指到 `deploy-project.yml`。

**site。** `service=none`。构建是 `npm ci --no-audit --no-fund && npm run build`。`rende.fun` 的 apex `location /` 现在仍是 `root /var/www/html`。第一次部署产生 `/opt/site/current/dist` 之后，只改这一个 location，见 `server/examples/nginx/site-root.conf`，不要去掉 easypic、shutter、recipes 的 include。然后再在项目配置和调用方里写上 `health_url=https://rende.fun/`。在此之前不要写：旧站点根目录的 200 不能证明这次 release 已经在对外服务，404 则会把 release 回滚掉。

**recipes。** 构建是 `npm ci` 和 `npm run build`。重启命令是 `sudo -n /usr/bin/systemctl restart -- caiben`。健康检查是本机 URL，正文必须是 `{"ok":true}`。`EnvironmentFile=/opt/caiben/.env` 和绝对路径的 `DATA_DIR` 留在 `releases/` 外面。运行用户可以继续是 `caiben`；release 对其他用户可读，就足够执行 `tsx`。只有通过 `rende-deploy` 的一次部署通过了这个健康检查，才能停用原来的 `caiben-deploy` SSH 账号。

**shutter。** PM2 应用名是 `shutter-count`。示例 `server/examples/pm2/shutter-count.config.cjs` 的 `cwd` 是 `/opt/shutter-count/current`，`script` 是 `bin/start.mjs`，`interpreter` 是 `/opt/node-v22.23.2-linux-x64/bin/node`。文件名必须是 `*.config.cjs` 或 `ecosystem*`。其他 `.cjs` 会被 PM2 当成脚本执行，应用不会启动。环境变量占位符与应用默认值一致：`MAX_UPLOAD_MB=50`、`TRUST_PROXY=127.0.0.1,::1`、`SHUTTER_APP_DIR=/opt/shutter-count/current`。仓库里的 `npm start` 是 `node dist/src/main.js`。以 `pm2 show shutter-count` 实际在跑的路径为准，然后用 `rende-deploy`、`PM2_HOME=/opt/shutter-count/.pm2` 对该 ecosystem 执行 `pm2 startOrRestart`。本机健康检查是 `http://127.0.0.1:3020/shutter/api/health`。`GET /shutter` 返回 308，curl 会把这个状态当成成功。开机单元 `server/examples/systemd/pm2-<project>.service`（或 `pm2-shutter-count.service`）以 `rende-deploy` 运行 PM2，`PM2_HOME=/opt/shutter-count/.pm2`。它不会自动安装。现网 shutter 接收器还会核对 GitHub Actions 的 run id；这套共享接收器不核对。

**easypic。** 现网进程是 root 的 PM2 应用 `easypic-api`，监听 `127.0.0.1:3010`。nginx 从 `/var/www/easypic` 提供 HTML，不是从 release 目录。这个接收器从 `/opt/easypic/current` 重启 PM2，不会 rsync 到 `/var/www`。在 nginx 改为指向 release（或你愿意让这个用户执行的复制步骤）之前，静态文件不会更新。`/etc/easypic/easypic.env` 现在是 root 的 `0600`；`deploy/start-api.sh` 会 source 它，所以新的 PM2 守护进程启动前，`rende-deploy` 必须能读这个文件。在这次切换完成前，保留 root 的 PM2 进程。

## 接入一个新项目

1. 选一个项目 id（`[a-z][a-z0-9-]{0,31}`）和一个真实目录 `/opt/<name>`，属主为 `rende-deploy`（或至少它可写）。不要复用其他应用的目录。
2. 添加 `/etc/rende-deploy/projects/<id>.conf`。必填：`root`、`repo_url`、`service`、`build`，以及 `health_url` 或 `health_file` 至少一个。`repo_url` 形如 `https://github.com/<owner>/<repo>.git`。分支永远是 `main`。
3. `service` 取 `none`、`systemd` 或 `pm2`。
   - `systemd` 需要 `unit`，且该单元名必须写在 `/etc/sudoers.d/rende-deploy` 里。
   - `pm2` 需要 `pm2_app`，以及位于 `root` 之内的 `pm2_home`。可选的 `pm2_ecosystem` 必须在 `/etc/rende-deploy/pm2/` 或 `root` 里面，文件已经存在，并且名字是 `*.config.cjs` 或 `ecosystem*`。把 `server/examples/systemd/pm2-<project>.service` 复制成开机单元，以 `rende-deploy` 运行，`PM2_HOME=/opt/<project>/.pm2`。
4. 在应用仓库放一个包装工作流。四个 `ECS_*` secret 照旧复用。
5. 部署一次，确认输出 `Deployed <id> <sha>` 和健康检查。`readlink -f /opt/<name>/current` 应是新 release，`previous` 仍能启动。

其他配置键：`publish_subdir`、`health_body`、`health_attempts`（默认 30）、`health_timeout`（默认 3 秒）、`keep`、`min_interval`、`env_file`、`path_extra`。不认识的键会被拒绝。

## 开发本仓库

```bash
bash server/tests/receive-deploy.test.sh
shellcheck server/receive-deploy.sh server/install.sh server/tests/receive-deploy.test.sh
```

测试覆盖命令解析、配置拒绝、静态部署、构建失败、健康文件缺失、带精确正文的 HTTP 健康检查、拒绝 HTTP 3xx、回滚、已不在 `main` 上的 sha、限流、`flock`、清理旧 release、fetch 重试，以及有毒的 `~/.gitconfig`。测试不会 SSH 到任何机器。设置了 `SSH_CONNECTION` 时，测试模式会被拒绝。

测试模式下会跳过 GitHub fetch 的退避，让重试立刻发生。生产环境在两次 fetch 之间等待 `attempt * 10` 秒。
