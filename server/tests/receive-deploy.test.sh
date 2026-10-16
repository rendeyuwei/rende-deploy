#!/usr/bin/env bash
# Behavioral tests for the shared receiver. Uses a local file:// git remote.
# Production SSH sessions cannot enable this mode: SSH_CONNECTION strips it.
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "$0")/../.." && pwd)
receiver=${root_dir}/server/receive-deploy.sh
install=${root_dir}/server/install.sh
chmod 755 "${receiver}" "${install}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_fail() {
  local name=$1
  local pattern=$2
  shift 2
  local out code
  set +e
  out=$("$@" 2>&1)
  code=$?
  set -e
  [[ ${code} -ne 0 ]] || fail "${name}: expected failure, got: ${out}"
  [[ ${out} == *"${pattern}"* ]] || fail "${name}: output missing '${pattern}': ${out}"
  printf 'ok %s\n' "${name}"
}

expect_ok() {
  local name=$1
  local pattern=$2
  shift 2
  local out
  out=$("$@" 2>&1)
  [[ ${out} == *"${pattern}"* ]] || fail "${name}: output missing '${pattern}': ${out}"
  printf 'ok %s\n' "${name}"
}

tmp=$(mktemp -d)
server_pid=""
lock_pid=""
cleanup() {
  if [[ -n ${server_pid} ]]; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
  if [[ -n ${lock_pid} ]]; then
    kill "${lock_pid}" 2>/dev/null || true
    wait "${lock_pid}" 2>/dev/null || true
  fi
  rm -rf -- "${tmp}"
}
trap cleanup EXIT

git init -q -b main "${tmp}/repo"
git -C "${tmp}/repo" config user.email test@example.com
git -C "${tmp}/repo" config user.name test
printf 'v1\n' > "${tmp}/repo/README.md"
git -C "${tmp}/repo" add README.md
git -C "${tmp}/repo" commit -q -m init
sha=$(git -C "${tmp}/repo" rev-parse HEAD)

commit_file() {
  local msg=$1
  printf '%s\n' "${msg}" >> "${tmp}/repo/README.md"
  git -C "${tmp}/repo" add README.md
  git -C "${tmp}/repo" commit -q -m "${msg}"
  git -C "${tmp}/repo" rev-parse HEAD
}

repo_url="file://${tmp}/repo"

write_conf() {
  local file=$1
  shift
  mkdir -p -- "$(dirname -- "${file}")"
  printf '%s\n' "$@" > "${file}"
  chmod 644 "${file}"
}

static_conf() {
  local file=$1
  local project_root=$2
  shift 2
  local build='mkdir -p dist && touch dist/index.html'
  local keep=5
  local min_interval=0
  local health_file='dist/index.html'
  local health_url=''
  local health_body=''
  local arg key value
  for arg in "$@"; do
    key=${arg%%=*}
    value=${arg#*=}
    case ${key} in
      build) build=${value} ;;
      keep) keep=${value} ;;
      min_interval) min_interval=${value} ;;
      health_file) health_file=${value} ;;
      health_url) health_url=${value} ;;
      health_body) health_body=${value} ;;
      *) fail "bad override ${arg}" ;;
    esac
  done
  local -a lines=(
    "root=${project_root}"
    "repo_url=${repo_url}"
    "service=none"
    "build=${build}"
    "publish_subdir=dist"
    "keep=${keep}"
    "min_interval=${min_interval}"
    "health_attempts=2"
    "health_timeout=1"
  )
  if [[ -n ${health_file} ]]; then
    lines+=("health_file=${health_file}")
  fi
  if [[ -n ${health_url} ]]; then
    lines+=("health_url=${health_url}")
  fi
  if [[ -n ${health_body} ]]; then
    lines+=("health_body=${health_body}")
  fi
  write_conf "${file}" "${lines[@]}"
}

deploy_test() {
  local cfg=$1
  local id=$2
  local commit=$3
  env -u SSH_CONNECTION -u SSH_ORIGINAL_COMMAND \
    RENDE_DEPLOY_TEST=1 \
    RENDE_DEPLOY_CONFIG_DIR="${cfg}" \
    "${receiver}" deploy "${id}" "${commit}"
}

bash -n "${receiver}"
bash -n "${install}"
printf 'ok syntax\n'

expect_fail 'install requires root' 'run server/install.sh as root' "${install}"
expect_fail 'reject empty command' 'expected: deploy <project> <40-hex-sha>' "${receiver}"
expect_fail 'reject short sha' 'expected: deploy <project> <40-hex-sha>' \
  env SSH_ORIGINAL_COMMAND='deploy site abc' "${receiver}"
expect_fail 'reject extra argument' 'expected: deploy <project> <40-hex-sha>' \
  env SSH_ORIGINAL_COMMAND="deploy site ${sha} extra" "${receiver}"
expect_fail 'reject shell suffix' 'expected: deploy <project> <40-hex-sha>' \
  env SSH_ORIGINAL_COMMAND="deploy site ${sha}; touch ${tmp}/pwned" "${receiver}"
[[ ! -e ${tmp}/pwned ]] || fail 'shell suffix was executed'
printf 'ok shell suffix not executed\n'

cfg=${tmp}/cfg-bad
proj=${tmp}/opt-bad
mkdir -p "${proj}"
write_conf "${cfg}/site.conf" \
  "root=${proj}" \
  "repo_url=${repo_url}" \
  "service=none" \
  "build=npm ci; rm -rf /" \
  "health_file=dist/index.html"
expect_fail 'reject build metacharacters' 'invalid build command' \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha}"

write_conf "${cfg}/site.conf" \
  "root=${proj}" \
  "repo_url=http://github.com/rendeyuwei/rende-site.git" \
  "service=none" \
  "build=true" \
  "health_file=dist/index.html"
expect_fail 'reject non-https repo' 'invalid repo_url' \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha}"

write_conf "${cfg}/site.conf" \
  "root=${proj}" \
  "repo_url=${repo_url}" \
  "service=systemd" \
  "build=true" \
  "health_url=http://127.0.0.1/health"
expect_fail 'systemd requires unit' 'config missing unit' \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha}"

write_conf "${cfg}/site.conf" \
  "root=${proj}" \
  "repo_url=${repo_url}" \
  "service=none" \
  "build=true" \
  "health_file=dist/index.html" \
  "nope=1"
expect_fail 'unknown config key' 'unknown config key: nope' \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha}"

write_conf "${cfg}/site.conf" \
  "root=${proj}" \
  "root=${proj}" \
  "repo_url=${repo_url}" \
  "service=none" \
  "build=true" \
  "health_file=dist/index.html"
expect_fail 'duplicate config key' 'duplicate config key: root' \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha}"

rm -f "${cfg}/site.conf"
write_conf "${cfg}/real.conf" "root=${proj}"
ln -s real.conf "${cfg}/site.conf"
expect_fail 'reject symlink config' 'unknown project' \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha}"

rm -f "${cfg}/site.conf"
write_conf "${cfg}/site.conf" \
  "root=${proj}" \
  "repo_url=${repo_url}" \
  "service=none" \
  "build=true" \
  "health_file=dist/index.html"
chmod 666 "${cfg}/site.conf"
expect_fail 'reject world-writable config' 'config is group or world writable' \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha}"

cfg=${tmp}/cfg-prod
proj=${tmp}/opt-prod
mkdir -p "${proj}"
static_conf "${cfg}/site.conf" "${proj}"
expect_fail 'test config ignored without test mode' 'unknown project' \
  env RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha}"
[[ ! -L ${proj}/current ]] || fail 'production mode used the test config'
expect_fail 'ssh connection disables test mode' 'unknown project' \
  env SSH_CONNECTION='10.0.0.1 1 10.0.0.2 2' RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" \
  "${receiver}" deploy site "${sha}"

cfg=${tmp}/cfg-ok
proj=${tmp}/opt-ok
mkdir -p "${proj}"
static_conf "${cfg}/site.conf" "${proj}"

poison_home=${tmp}/poison-home
mkdir -p "${poison_home}"
cat > "${poison_home}/.gitconfig" <<EOF
[url "file:///no/such/rende-deploy-repo/"]
    insteadOf = file:///
EOF
expect_ok 'deploy ignores user gitconfig' "Deployed site ${sha}" \
  env HOME="${poison_home}" RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" \
  "${receiver}" deploy site "${sha}"
[[ -f ${proj}/current/dist/index.html ]] || fail 'index was not published'
[[ $(<"${proj}/current/REVISION") == "${sha}" ]] || fail 'REVISION mismatch'
[[ $(<"${proj}/current/dist/REVISION") == "${sha}" ]] || fail 'publish REVISION mismatch'
target=$(readlink -f "${proj}/current")
[[ ${target} == "${proj}/releases/${sha}-"* ]] || fail "current not in releases: ${target}"

static_conf "${cfg}/site.conf" "${proj}" "build=false"
expect_fail 'build failure leaves current' 'build failed' \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha}"
[[ $(readlink -f "${proj}/current") == "${target}" ]] || fail 'current moved after build failure'
half_built=$(find "${proj}/releases" -mindepth 1 -maxdepth 1 -type d ! -path "${target}" | wc -l)
[[ ${half_built} -eq 0 ]] || fail "half-built release was kept (${half_built})"

cfg_half=${tmp}/cfg-half
proj_half=${tmp}/opt-half
mkdir -p "${proj_half}"
static_conf "${cfg_half}/site.conf" "${proj_half}" "build=mkdir -p node_modules && false"
expect_fail 'failed first build removes half-built release' 'build failed' \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg_half}" "${receiver}" deploy site "${sha}"
half_count=$(find "${proj_half}/releases" -mindepth 1 -maxdepth 1 -type d | wc -l)
[[ ${half_count} -eq 0 ]] || fail "half-built release was kept (${half_count})"
[[ ! -e ${proj_half}/current ]] || fail 'failed first build created current'

static_conf "${cfg}/site.conf" "${proj}" "build=mkdir -p dist"
expect_fail 'missing health file leaves current' 'health file missing: dist/index.html' \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha}"
[[ $(readlink -f "${proj}/current") == "${target}" ]] || fail 'current moved when health file was missing'

python3 - <<PY &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{"ok":true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        return
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
open("${tmp}/port", "w").write(str(server.server_address[1]))
server.serve_forever()
PY
server_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -s ${tmp}/port ]] && break
  sleep 0.1
done
port=$(<"${tmp}/port")
[[ -n ${port} ]] || fail 'health server did not start'

sha_b=$(commit_file 'v2')
static_conf "${cfg}/site.conf" "${proj}" \
  "health_url=http://127.0.0.1:${port}/health" \
  "health_body={\"ok\":true}"
expect_ok 'http health exact body' "Deployed site ${sha_b}" \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha_b}"
good=$(readlink -f "${proj}/current")

sha_c=$(commit_file 'v3')
kill "${server_pid}"
wait "${server_pid}" 2>/dev/null || true
server_pid=""
static_conf "${cfg}/site.conf" "${proj}" \
  "health_url=http://127.0.0.1:${port}/health" \
  "health_body={\"ok\":true}"
expect_fail 'rollback when health fails' 'Health check failed; rolling back' \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha_c}"
[[ $(readlink -f "${proj}/current") == "${good}" ]] || fail 'rollback did not restore current'
failed_count=$(find "${proj}/releases" -mindepth 1 -maxdepth 1 -type d -name "${sha_c}-*" | wc -l)
[[ ${failed_count} -eq 0 ]] || fail "failed release was kept (${failed_count})"

# Force the previously deployed commit off main. The object remains in the cache.
git -C "${tmp}/repo" update-ref refs/heads/main "${sha}"
static_conf "${cfg}/site.conf" "${proj}"
expect_fail 'reject commit not on main' 'commit is not on main' \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha_b}"
[[ $(readlink -f "${proj}/current") == "${good}" ]] || fail 'not-on-main deploy moved current'
git -C "${tmp}/repo" update-ref refs/heads/main "${sha_c}"

python3 - <<PY &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/ok"):
            status = 200
            location = None
        else:
            status = 308
            location = self.path + "/"
        body = b'{"ok":true}'
        self.send_response(status)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        return
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
open("${tmp}/redir-port", "w").write(str(server.server_address[1]))
server.serve_forever()
PY
server_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -s ${tmp}/redir-port ]] && break
  sleep 0.1
done
redir_port=$(<"${tmp}/redir-port")
[[ -n ${redir_port} ]] || fail 'redirect server did not start'

set +e
curl -fsS -m 3 -o /dev/null -- "http://127.0.0.1:${redir_port}/shutter"
curl_308=$?
set -e
[[ ${curl_308} -eq 0 ]] || fail "curl -f unexpectedly rejected 308 (${curl_308})"
printf 'ok curl -f accepts 308\n'

cfg_redir=${tmp}/cfg-redir
proj_redir=${tmp}/opt-redir
mkdir -p "${proj_redir}"
static_conf "${cfg_redir}/site.conf" "${proj_redir}" \
  "health_url=http://127.0.0.1:${redir_port}/shutter" \
  "health_file="
expect_fail 'http 308 is not healthy' 'Health check failed; rolling back' \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg_redir}" "${receiver}" deploy site "${sha_c}"
[[ ! -e ${proj_redir}/current ]] || fail '308 health check left current in place'
redir_left=$(find "${proj_redir}/releases" -mindepth 1 -maxdepth 1 -type d | wc -l)
[[ ${redir_left} -eq 0 ]] || fail "308 health check kept the release (${redir_left})"

# Mirrors the status check in .github/workflows/deploy-project.yml.
public_health() {
  local url=$1
  local expect_body=${2:-}
  local code body tmp status
  tmp=$(mktemp)
  status=0
  code=$(curl -fsS --retry 5 --retry-delay 2 --retry-all-errors -m 10 \
    -o "${tmp}" -w '%{http_code}' -- "${url}") || status=$?
  if [[ ${status} -ne 0 ]]; then
    rm -f -- "${tmp}"
    return 1
  fi
  if [[ ! ${code} =~ ^2[0-9][0-9]$ ]]; then
    rm -f -- "${tmp}"
    printf 'health_url returned HTTP %s; only 2xx is success\n' "${code}" >&2
    return 1
  fi
  if [[ -n ${expect_body} ]]; then
    body=$(<"${tmp}")
    body=${body//$'\r'/}
    body=${body%$'\n'}
    rm -f -- "${tmp}"
    [[ ${body} == "${expect_body}" ]]
  else
    rm -f -- "${tmp}"
  fi
}
public_health "http://127.0.0.1:${redir_port}/ok" '{"ok":true}' \
  || fail 'public health rejected 200'
if public_health "http://127.0.0.1:${redir_port}/shutter" '{"ok":true}' 2>/dev/null; then
  fail 'public health accepted 308'
fi
printf 'ok public health rejects 3xx\n'
kill "${server_pid}" 2>/dev/null || true
wait "${server_pid}" 2>/dev/null || true
server_pid=""

cfg=${tmp}/cfg-rate
proj=${tmp}/opt-rate
mkdir -p "${proj}"
static_conf "${cfg}/site.conf" "${proj}" "min_interval=60"
expect_ok 'rate limit first deploy' "Deployed site ${sha_c}" \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha_c}"
expect_fail 'rate limit second deploy' 'rate limited' \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha_c}"

cfg=${tmp}/cfg-lock
proj=${tmp}/opt-lock
mkdir -p "${proj}"
static_conf "${cfg}/site.conf" "${proj}"
flock -n "${proj}/.deploy.lock" -c 'sleep 30' &
lock_pid=$!
sleep 0.2
expect_fail 'lock is exclusive' 'another deployment holds the lock' \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha_c}"
kill "${lock_pid}" 2>/dev/null || true
wait "${lock_pid}" 2>/dev/null || true
lock_pid=""

cfg=${tmp}/cfg-prune
proj=${tmp}/opt-prune
mkdir -p "${proj}"
static_conf "${cfg}/site.conf" "${proj}" "keep=1"
expect_ok 'prune first' "Deployed site ${sha}" \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha}"
expect_ok 'prune second' "Deployed site ${sha_b}" \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha_b}"
expect_ok 'prune third' "Deployed site ${sha_c}" \
  env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_CONFIG_DIR="${cfg}" "${receiver}" deploy site "${sha_c}"
count=$(find "${proj}/releases" -mindepth 1 -maxdepth 1 -type d | wc -l)
[[ ${count} -eq 2 ]] || fail "expected current and previous only, found ${count}"
[[ $(readlink -f "${proj}/current") == "${proj}/releases/${sha_c}-"* ]] || fail 'prune moved current'
[[ $(readlink -f "${proj}/previous") == "${proj}/releases/${sha_b}-"* ]] || fail 'previous was pruned'

wrapper=${tmp}/bin
mkdir -p "${wrapper}"
cat > "${wrapper}/git" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *fetch* ]]; then
  count=0
  if [[ -f ${tmp}/fetch-fails ]]; then
    count=\$(<"${tmp}/fetch-fails")
  fi
  if (( count < 2 )); then
    printf '%s\n' "\$((count + 1))" > "${tmp}/fetch-fails"
    echo "simulated fetch failure" >&2
    exit 1
  fi
fi
exec /usr/bin/git "\$@"
EOF
chmod 755 "${wrapper}/git"
cfg=${tmp}/cfg-retry
proj=${tmp}/opt-retry
mkdir -p "${proj}"
static_conf "${cfg}/site.conf" "${proj}"
out=$(env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_TEST_PATH="${wrapper}" RENDE_DEPLOY_CONFIG_DIR="${cfg}" \
  "${receiver}" deploy site "${sha_c}" 2>&1)
[[ ${out} == *'git fetch attempt 1 failed'* ]] || fail "missing retry log: ${out}"
[[ ${out} == *'git fetch attempt 2 failed'* ]] || fail "missing second retry: ${out}"
[[ ${out} == *"Deployed site ${sha_c}"* ]] || fail "retry did not deploy: ${out}"
printf 'ok fetch retries then succeeds\n'

npm_bin=$(command -v npm || true)
[[ -n ${npm_bin} ]] || fail 'npm is required to reproduce double-loading config'
npm_dir=$(dirname -- "${npm_bin}")
same_npmrc=${tmp}/double-npmrc
: > "${same_npmrc}"
set +e
double_out=$(npm_config_userconfig="${same_npmrc}" NPM_CONFIG_GLOBALCONFIG="${same_npmrc}" "${npm_bin}" --version 2>&1)
double_code=$?
set -e
[[ ${double_code} -ne 0 ]] || fail "same-file npm config unexpectedly succeeded: ${double_out}"
[[ ${double_out} == *'double-loading config'*'as "global", previously loaded as "user"'* ]] \
  || fail "npm did not reproduce double-load: ${double_out}"
printf 'ok npm double-load reproduced\n'

cfg_npm=${tmp}/cfg-npm
proj_npm=${tmp}/opt-npm
mkdir -p "${proj_npm}"
static_conf "${cfg_npm}/site.conf" "${proj_npm}" \
  "build=npm --version && mkdir -p dist && touch dist/index.html"
set +e
npm_out=$(env RENDE_DEPLOY_TEST=1 RENDE_DEPLOY_TEST_PATH="${npm_dir}" RENDE_DEPLOY_CONFIG_DIR="${cfg_npm}" \
  "${receiver}" deploy site "${sha_c}" 2>&1)
npm_code=$?
set -e
[[ ${npm_code} -eq 0 ]] || fail "npm deploy failed (${npm_code}): ${npm_out}"
[[ ${npm_out} != *'double-loading config'* ]] || fail "receiver double-loaded npm config: ${npm_out}"
[[ ${npm_out} == *"Deployed site ${sha_c}"* ]] || fail "npm deploy missing success line: ${npm_out}"
[[ -f ${proj_npm}/.receiver-npmrc && -f ${proj_npm}/.receiver-npmrc-global ]] \
  || fail 'receiver npmrc files missing'
[[ ! ${proj_npm}/.receiver-npmrc -ef ${proj_npm}/.receiver-npmrc-global ]] \
  || fail 'user and global npmrc are the same file'
printf 'ok npm user and global configs stay separate\n'

if grep -q 'PermitUserEnvironment' "${root_dir}/server/examples/sshd/rende-deploy.conf"; then
  fail 'PermitUserEnvironment inside the Match block makes sshd -t fail'
fi
# shellcheck disable=SC2016
pattern_create='-m 0644 /dev/null "${keys}/rende-deploy"'
# shellcheck disable=SC2016
pattern_keep='chmod 0644 -- "${keys}/rende-deploy"'
grep -q -F -- "${pattern_create}" "${install}" \
  || fail 'authorized_keys must be created mode 0644'
grep -q -F -- "${pattern_keep}" "${install}" \
  || fail 'existing authorized_keys must be chmod 0644'
grep -q 'mode 0644' "${root_dir}/server/examples/authorized_keys.example" \
  || fail 'authorized_keys.example must document mode 0644'
printf 'ok sshd drop-in and authorized_keys mode\n'

grep -q 'systemctl restart -- caiben' "${root_dir}/server/examples/sudoers.d/rende-deploy" \
  || fail 'sudoers must allow systemctl restart -- caiben'
[[ -f ${root_dir}/server/examples/pm2/shutter-count.config.cjs ]] \
  || fail 'shutter ecosystem must be named *.config.cjs'
[[ -f ${root_dir}/server/examples/pm2/easypic-api.config.cjs ]] \
  || fail 'easypic ecosystem must be named *.config.cjs'
[[ ! -e ${root_dir}/server/examples/pm2/shutter-count.cjs ]] \
  || fail 'old shutter-count.cjs name is still present'
grep -q 'shutter-count.config.cjs' "${root_dir}/server/examples/projects/shutter.conf" \
  || fail 'shutter.conf must point at shutter-count.config.cjs'
grep -q 'easypic-api.config.cjs' "${root_dir}/server/examples/projects/easypic.conf" \
  || fail 'easypic.conf must point at easypic-api.config.cjs'
grep -q 'health_url=http://127.0.0.1:3020/shutter/api/health' \
  "${root_dir}/server/examples/projects/shutter.conf" \
  || fail 'shutter health_url must be /shutter/api/health'
grep -q 'MAX_UPLOAD_MB' "${root_dir}/server/examples/pm2/shutter-count.config.cjs" \
  || fail 'shutter ecosystem missing MAX_UPLOAD_MB'
grep -q 'TRUST_PROXY' "${root_dir}/server/examples/pm2/shutter-count.config.cjs" \
  || fail 'shutter ecosystem missing TRUST_PROXY'
grep -q 'SHUTTER_APP_DIR' "${root_dir}/server/examples/pm2/shutter-count.config.cjs" \
  || fail 'shutter ecosystem missing SHUTTER_APP_DIR'
grep -q 'node-v22.23.2-linux-x64/bin/node' \
  "${root_dir}/server/examples/pm2/shutter-count.config.cjs" \
  || fail 'shutter ecosystem missing Node 22 interpreter'
unit=${root_dir}/server/examples/systemd/pm2-'<project>'.service
[[ -f ${unit} ]] || fail 'missing pm2-<project>.service example'
grep -q 'User=rende-deploy' "${unit}" || fail 'pm2 unit must run as rende-deploy'
grep -q 'PM2_HOME=/opt/<project>/.pm2' "${unit}" || fail 'pm2 unit PM2_HOME placeholder missing'
caller_group=$(awk '/^concurrency:/{c=1} c && /^  group:/{print; exit}' \
  "${root_dir}/docs/caller-workflow.yml")
[[ ${caller_group} != *rende-deploy-* ]] \
  || fail "caller concurrency group collides with the reusable workflow: ${caller_group}"
grep -q 'only 2xx is success' "${root_dir}/.github/workflows/deploy-project.yml" \
  || fail 'workflow public health check must reject non-2xx'
printf 'ok cutover examples\n'

build_re='^[A-Za-z0-9 _./:=@&+-]+$'
for example in "${root_dir}/server/examples/projects/"*.conf; do
  build_line=$(grep -E '^build=' "${example}")
  [[ -n ${build_line} ]] || fail "example missing build: ${example}"
  [[ ${build_line#build=} =~ ${build_re} ]] || fail "example build rejected: ${example}"
  grep -q '^root=/opt/[A-Za-z0-9._-]*$' "${example}" || fail "example root rejected: ${example}"
  grep -q '^repo_url=https://github\.com/[A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*\.git$' "${example}" \
    || fail "example repo_url rejected: ${example}"
done
printf 'ok example configs\n'

printf 'all receiver tests passed\n'
