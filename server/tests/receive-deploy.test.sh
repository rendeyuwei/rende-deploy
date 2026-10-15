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
