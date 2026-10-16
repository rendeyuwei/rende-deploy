#!/usr/bin/env bash
# Shared deploy receiver for rende.fun sites.
# SSH ForceCommand entrypoint for the single deploy user (rende-deploy).
# Accepts exactly: deploy <project> <40-hex-sha>
# The client cannot choose a repository, path, or shell command. This process
# loads root-owned /etc/rende-deploy/projects/<project>.conf, fetches that
# commit from GitHub, and requires it to be on origin/main.
set -euo pipefail
umask 022
export LC_ALL=C
export GIT_TERMINAL_PROMPT=0
# Ignore ~/.gitconfig so a previous build cannot rewrite the next fetch.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
unset BASH_ENV ENV CDPATH

die() {
  printf 'Deployment stopped: %s\n' "$*" >&2
  if [[ -n ${root:-} && -d ${root} ]]; then
    mkdir -p -- "${root}/log" 2>/dev/null || true
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${root}/log/failures.log" 2>/dev/null || true
  fi
  exit 1
}

# A real SSH session must not be able to flip test-only switches via SendEnv.
if [[ -n ${SSH_CONNECTION:-} ]]; then
  unset RENDE_DEPLOY_TEST RENDE_DEPLOY_CONFIG_DIR RENDE_DEPLOY_TEST_PATH
fi

(( EUID != 0 )) || die 'refusing to run as root'

raw=${SSH_ORIGINAL_COMMAND-}
if [[ -z ${raw} ]]; then
  if [[ ${1:-} == "-c" ]]; then
    raw=${2:-}
  else
    raw=${*}
  fi
fi

if [[ ! ${raw} =~ ^deploy\ ([a-z][a-z0-9-]{0,31})\ ([0-9a-f]{40})$ ]]; then
  die 'expected: deploy <project> <40-hex-sha>'
fi
project=${BASH_REMATCH[1]}
sha=${BASH_REMATCH[2]}

config_dir=/etc/rende-deploy/projects
if [[ ${RENDE_DEPLOY_TEST:-} == 1 ]]; then
  [[ -n ${RENDE_DEPLOY_CONFIG_DIR:-} ]] || die 'test mode requires RENDE_DEPLOY_CONFIG_DIR'
  config_dir=${RENDE_DEPLOY_CONFIG_DIR}
fi

path_prefix=/usr/local/bin:/usr/bin:/bin
if [[ ${RENDE_DEPLOY_TEST:-} == 1 && -n ${RENDE_DEPLOY_TEST_PATH:-} ]]; then
  path_prefix=${RENDE_DEPLOY_TEST_PATH}:${path_prefix}
fi
export PATH=${path_prefix}

cfg=${config_dir}/${project}.conf
[[ -f ${cfg} && ! -L ${cfg} ]] || die 'unknown project'

cfg_mode=$(stat -c %a -- "${cfg}")
if (( (8#${cfg_mode} & 022) != 0 )); then
  die 'config is group or world writable'
fi
if [[ ${RENDE_DEPLOY_TEST:-} != 1 ]]; then
  [[ $(stat -c %u -- "${cfg}") -eq 0 ]] || die 'config must be owned by root'
  cfg_dir_mode=$(stat -c %a -- "${config_dir}")
  if (( (8#${cfg_dir_mode} & 022) != 0 )); then
    die 'config directory is group or world writable'
  fi
  [[ $(stat -c %u -- "${config_dir}") -eq 0 ]] || die 'config directory must be owned by root'
fi

root=""
repo_url=""
service=""
build=""
unit=""
pm2_app=""
pm2_home=""
pm2_ecosystem=""
publish_subdir=""
health_url=""
health_body=""
health_file=""
env_file=""
path_extra=""
keep=5
min_interval=30
health_attempts=30
health_timeout=3
seen_keys=" "

mark_key() {
  case ${seen_keys} in
    *" $1 "*) die "duplicate config key: $1" ;;
  esac
  seen_keys="${seen_keys}$1 "
}

while IFS= read -r line || [[ -n ${line} ]]; do
  line=${line%$'\r'}
  [[ ${line} =~ ^[[:space:]]*$ ]] && continue
  [[ ${line} =~ ^[[:space:]]*# ]] && continue
  [[ ${line} =~ ^([A-Za-z][A-Za-z0-9_]*)=(.*)$ ]] || die "bad config line: ${line}"
  key=${BASH_REMATCH[1]}
  value=${BASH_REMATCH[2]}
  mark_key "${key}"
  case ${key} in
    root) root=${value} ;;
    repo_url) repo_url=${value} ;;
    service) service=${value} ;;
    build) build=${value} ;;
    unit) unit=${value} ;;
    pm2_app) pm2_app=${value} ;;
    pm2_home) pm2_home=${value} ;;
    pm2_ecosystem) pm2_ecosystem=${value} ;;
    publish_subdir) publish_subdir=${value} ;;
    health_url) health_url=${value} ;;
    health_body) health_body=${value} ;;
    health_file) health_file=${value} ;;
    env_file) env_file=${value} ;;
    path_extra) path_extra=${value} ;;
    keep) keep=${value} ;;
    min_interval) min_interval=${value} ;;
    health_attempts) health_attempts=${value} ;;
    health_timeout) health_timeout=${value} ;;
    *) die "unknown config key: ${key}" ;;
  esac
done < "${cfg}"

[[ -n ${root} ]] || die 'config missing root'
[[ -n ${repo_url} ]] || die 'config missing repo_url'
[[ -n ${service} ]] || die 'config missing service'
[[ -n ${build} ]] || die 'config missing build'
[[ -n ${health_url} || -n ${health_file} ]] || die 'config needs health_url or health_file'

if [[ ${RENDE_DEPLOY_TEST:-} == 1 ]]; then
  [[ ${root} =~ ^/[A-Za-z0-9._/-]+$ && ${root} != *..* && ${root} != / ]] || die 'invalid root'
else
  [[ ${root} =~ ^/opt/[A-Za-z0-9._-]+$ ]] || die 'invalid root'
fi
[[ ${service} =~ ^(none|systemd|pm2)$ ]] || die 'invalid service'
build_re='^[A-Za-z0-9 _./:=@&+-]+$'
[[ ${build} =~ ${build_re} ]] || die 'invalid build command'
[[ ${#build} -le 2000 ]] || die 'invalid build command'

if [[ ${repo_url} == file://* ]]; then
  [[ ${RENDE_DEPLOY_TEST:-} == 1 ]] || die 'refusing non-https repo url'
  [[ ${repo_url} =~ ^file:///[A-Za-z0-9._/-]+$ ]] || die 'invalid repo_url'
  [[ ${repo_url} != *..* ]] || die 'invalid repo_url'
else
  [[ ${repo_url} =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]] || die 'invalid repo_url'
fi

[[ ${keep} =~ ^[0-9]+$ && ${keep} -ge 1 && ${keep} -le 50 ]] || die 'invalid keep'
[[ ${min_interval} =~ ^[0-9]+$ && ${min_interval} -le 3600 ]] || die 'invalid min_interval'
[[ ${health_attempts} =~ ^[0-9]+$ && ${health_attempts} -ge 1 && ${health_attempts} -le 120 ]] || die 'invalid health_attempts'
[[ ${health_timeout} =~ ^[0-9]+$ && ${health_timeout} -ge 1 && ${health_timeout} -le 30 ]] || die 'invalid health_timeout'

if [[ -n ${health_url} ]]; then
  health_url_re='^https?://[A-Za-z0-9._~:/#?&=%+-]+$'
  [[ ${health_url} =~ ${health_url_re} ]] || die 'invalid health_url'
fi
if [[ -n ${health_body} ]]; then
  [[ -n ${health_url} ]] || die 'health_body requires health_url'
  [[ ${#health_body} -le 512 ]] || die 'invalid health_body'
fi
if [[ -n ${publish_subdir} ]]; then
  [[ ${publish_subdir} =~ ^[A-Za-z0-9._/-]+$ && ${publish_subdir} != *..* && ${publish_subdir} != /* ]] || die 'invalid publish_subdir'
fi
if [[ -n ${health_file} ]]; then
  [[ ${health_file} =~ ^[A-Za-z0-9._/-]+$ && ${health_file} != *..* && ${health_file} != /* ]] || die 'invalid health_file'
fi
if [[ ${service} == systemd ]]; then
  [[ ${unit} =~ ^[a-zA-Z0-9][a-zA-Z0-9:@._-]{0,63}$ ]] || die 'config missing unit'
fi
if [[ ${service} == pm2 ]]; then
  [[ ${pm2_app} =~ ^[a-zA-Z0-9][a-zA-Z0-9@._-]{0,63}$ ]] || die 'config missing pm2_app'
  [[ ${pm2_home} =~ ^/[A-Za-z0-9._/-]+$ && ${pm2_home} != *..* ]] || die 'config missing pm2_home'
  case ${pm2_home} in
    "${root}"|"${root}"/*) ;;
    *) die 'pm2_home must be inside the project root' ;;
  esac
  if [[ -n ${pm2_ecosystem} ]]; then
    [[ ${pm2_ecosystem} =~ ^/[A-Za-z0-9._/-]+$ && ${pm2_ecosystem} != *..* ]] || die 'invalid pm2_ecosystem'
    case ${pm2_ecosystem} in
      /etc/rende-deploy/pm2/*|"${root}"/*) ;;
      *) die 'invalid pm2_ecosystem' ;;
    esac
    [[ -f ${pm2_ecosystem} && ! -L ${pm2_ecosystem} ]] || die "pm2 ecosystem missing: ${pm2_ecosystem}"
  fi
fi
if [[ -n ${env_file} ]]; then
  [[ ${env_file} =~ ^/[A-Za-z0-9._/-]+$ && ${env_file} != *..* ]] || die 'invalid env_file'
  case ${env_file} in
    "${root}"/*|/etc/*) ;;
    *) die 'invalid env_file' ;;
  esac
fi
if [[ -n ${path_extra} ]]; then
  [[ ${path_extra} =~ ^/[A-Za-z0-9._+/-]+$ ]] || die 'invalid path_extra'
  extra_path=""
  IFS=':' read -r -a path_parts <<< "${path_extra}"
  for part in "${path_parts[@]}"; do
    [[ -d ${part} ]] || die "path_extra directory missing: ${part}"
    extra_path=${extra_path:+${extra_path}:}${part}
  done
  export PATH=${extra_path}:${PATH}
fi

[[ -d ${root} && ! -L ${root} ]] || die "project root missing: ${root}"
[[ -w ${root} ]] || die "project root not writable: ${root}"
mkdir -p -- "${root}/releases" "${root}/log"

release=""
remove_failed_release() {
  [[ -n ${release} && -d ${release} ]] || return 0
  local base cur prev
  base=${release##*/}
  [[ ${base} =~ ^[0-9a-f]{40}-[0-9]{14}$ ]] || return 0
  [[ ${release} == "${root}/releases/${base}" ]] || return 0
  cur=$(readlink -f -- "${root}/current" 2>/dev/null || true)
  prev=$(readlink -f -- "${root}/previous" 2>/dev/null || true)
  [[ ${release} == "${cur}" || ${release} == "${prev}" ]] && return 0
  rm -rf -- "${release}"
}

exec 9>"${root}/.deploy.lock"
lock_wait=600
if [[ ${RENDE_DEPLOY_TEST:-} == 1 ]]; then
  lock_wait=1
fi
flock -w "${lock_wait}" 9 || die 'another deployment holds the lock'

if (( min_interval > 0 )) && [[ -f ${root}/.last-deploy ]]; then
  age=$(( $(date +%s) - $(stat -c %Y -- "${root}/.last-deploy") ))
  if (( age < min_interval )); then
    die "rate limited; retry in $((min_interval - age))s"
  fi
fi
touch -- "${root}/.last-deploy"

cache=${root}/repo.git
if [[ ! -d ${cache} ]]; then
  git init -q --bare -- "${cache}"
fi

retry_sleep() {
  local seconds=$1
  if [[ ${RENDE_DEPLOY_TEST:-} == 1 ]]; then
    seconds=0
  fi
  sleep "${seconds}"
}

fetch_ok=0
for ((attempt = 1; attempt <= 5; attempt++)); do
  git_opts=(
    -C "${cache}"
    -c "safe.directory=${cache}"
    -c http.lowSpeedLimit=1000
    -c http.lowSpeedTime=60
  )
  if [[ ${repo_url} == file://* ]]; then
    git_opts+=(-c protocol.file.allow=always)
  fi
  if timeout 300 git "${git_opts[@]}" fetch -q --no-tags -- "${repo_url}" '+refs/heads/main:refs/remotes/origin/main'; then
    fetch_ok=1
    break
  fi
  echo "git fetch attempt ${attempt} failed; retrying" >&2
  if (( attempt < 5 )); then
    retry_sleep $((attempt * 10))
  fi
done
(( fetch_ok == 1 )) || die 'could not fetch from GitHub'

git -C "${cache}" -c "safe.directory=${cache}" cat-file -e "${sha}^{commit}" 2>/dev/null \
  || die 'commit not found after fetch'
git -C "${cache}" -c "safe.directory=${cache}" merge-base --is-ancestor "${sha}" refs/remotes/origin/main \
  || die 'commit is not on main'

release=""
for ((attempt = 1; attempt <= 3; attempt++)); do
  stamp=$(date -u +%Y%m%d%H%M%S)
  candidate=${root}/releases/${sha}-${stamp}
  if [[ ! -e ${candidate} ]]; then
    release=${candidate}
    break
  fi
  sleep 1
done
[[ -n ${release} ]] || die 'release path already exists'
mkdir -p -- "${release}"

if ! git -C "${cache}" -c "safe.directory=${cache}" archive --format=tar "${sha}" | tar -x -C "${release}"; then
  remove_failed_release
  die 'could not extract commit'
fi

if [[ -n ${env_file} ]]; then
  if [[ ! -f ${env_file} || -L ${env_file} ]]; then
    remove_failed_release
    die "env file missing: ${env_file}"
  fi
  ln -sfn -- "${env_file}" "${release}/.env"
fi

if command -v node >/dev/null 2>&1; then
  node_bin=$(readlink -f -- "$(command -v node)")
  nodedir=$(dirname "$(dirname "${node_bin}")")
  if [[ -f ${nodedir}/include/node/node.h ]]; then
    export npm_config_nodedir=${nodedir}
  fi
fi
export npm_config_cache=${root}/.npm-cache
export npm_config_fund=false
export npm_config_update_notifier=false
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
# Do not read ~/.npmrc. Truncate a receiver-owned file immediately before build.
# npm refuses to load the same file as both user and global config, so use two.
: > "${root}/.receiver-npmrc"
: > "${root}/.receiver-npmrc-global"
export npm_config_userconfig=${root}/.receiver-npmrc
export NPM_CONFIG_GLOBALCONFIG=${root}/.receiver-npmrc-global

if ! (
  cd -- "${release}"
  bash --noprofile --norc -c "${build}"
); then
  remove_failed_release
  die 'build failed'
fi

printf '%s\n' "${sha}" > "${release}/REVISION"
if [[ -n ${publish_subdir} ]]; then
  [[ -d ${release}/${publish_subdir} ]] || {
    remove_failed_release
    die "publish dir missing: ${publish_subdir}"
  }
  printf '%s\n' "${sha}" > "${release}/${publish_subdir}/REVISION"
fi
if [[ -n ${health_file} ]]; then
  [[ -f ${release}/${health_file} && ! -L ${release}/${health_file} ]] || {
    remove_failed_release
    die "health file missing: ${health_file}"
  }
fi

previous=$(readlink -f -- "${root}/current" 2>/dev/null || true)
if [[ -n ${previous} ]]; then
  case ${previous} in
    "${root}/releases/"*) ;;
    *) previous="" ;;
  esac
fi

switch_to() {
  local target=$1
  ln -sfn -- "${target}" "${root}/.current.tmp"
  mv -Tf -- "${root}/.current.tmp" "${root}/current"
}

restart_service() {
  case ${service} in
    none) ;;
    systemd)
      sudo -n /usr/bin/systemctl restart -- "${unit}"
      ;;
    pm2)
      mkdir -p -- "${pm2_home}"
      if [[ -n ${pm2_ecosystem} ]]; then
        [[ -f ${pm2_ecosystem} && ! -L ${pm2_ecosystem} ]] || return 1
        PM2_HOME=${pm2_home} pm2 startOrRestart "${pm2_ecosystem}" --update-env
      else
        PM2_HOME=${pm2_home} pm2 restart "${pm2_app}" --update-env
      fi
      ;;
  esac
}

http_healthy_once() {
  local body code tmp
  # curl -f accepts 3xx. Only a 2xx response is a successful health check.
  tmp=$(mktemp)
  code=$(curl -sS -m "${health_timeout}" -o "${tmp}" -w '%{http_code}' -- "${health_url}") || code=""
  if [[ ! ${code} =~ ^2[0-9][0-9]$ ]]; then
    rm -f -- "${tmp}"
    return 1
  fi
  if [[ -z ${health_body} ]]; then
    rm -f -- "${tmp}"
    return 0
  fi
  body=$(<"${tmp}")
  rm -f -- "${tmp}"
  body=${body//$'\r'/}
  body=${body%$'\n'}
  [[ ${body} == "${health_body}" ]]
}

healthy() {
  [[ -n ${health_url} ]] || return 0
  local i
  for ((i = 1; i <= health_attempts; i++)); do
    if http_healthy_once; then
      return 0
    fi
    if (( i < health_attempts )); then
      sleep 1
    fi
  done
  return 1
}

rollback() {
  echo "$1; rolling back" >&2
  if [[ -n ${previous} && -d ${previous} ]]; then
    switch_to "${previous}"
    restart_service || echo 'rollback restart failed' >&2
    if ! healthy; then
      echo 'rollback also unhealthy' >&2
    fi
  else
    rm -f -- "${root}/current"
    echo 'no previous release to restore' >&2
  fi
  remove_failed_release
  exit 1
}

switch_to "${release}"
if ! restart_service; then
  rollback 'process restart failed'
fi
if ! healthy; then
  rollback 'Health check failed'
fi

if [[ -n ${previous} && ${previous} != "${release}" && -d ${previous} ]]; then
  ln -sfn -- "${previous}" "${root}/.previous.tmp"
  mv -Tf -- "${root}/.previous.tmp" "${root}/previous"
fi

mapfile -t old_releases < <(find "${root}/releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@\t%p\n' | sort -nr | cut -f2-)
cur=$(readlink -f -- "${root}/current" 2>/dev/null || true)
prev=$(readlink -f -- "${root}/previous" 2>/dev/null || true)
if ((${#old_releases[@]} > keep)); then
  for ((i = keep; i < ${#old_releases[@]}; i++)); do
    d=${old_releases[$i]}
    base=${d##*/}
    [[ ${base} =~ ^[0-9a-f]{40}-[0-9]{14}$ ]] || continue
    [[ ${d} == "${root}/releases/${base}" ]] || continue
    [[ ${d} == "${cur}" || ${d} == "${prev}" ]] && continue
    rm -rf -- "${d}"
  done
fi

printf 'Deployed %s %s\n' "${project}" "${sha}"
