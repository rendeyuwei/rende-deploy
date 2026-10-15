#!/usr/bin/env bash
# Install the shared rende-deploy receiver onto the ECS. Run as root.
# Does not reload sshd unless --sshd is passed, and even then only after sshd -t.
# Does not restart application services and does not change ownership of an
# existing /opt/<project> tree.
set -euo pipefail
umask 022

die() {
  printf 'install stopped: %s\n' "$*" >&2
  exit 1
}

(( EUID == 0 )) || die 'run server/install.sh as root on the ECS'

apply_sshd=0
for arg in "$@"; do
  case ${arg} in
    --sshd) apply_sshd=1 ;;
    *) die "unknown argument: ${arg}" ;;
  esac
done

src=$(cd -- "$(dirname -- "$0")" && pwd)
libexec=/usr/local/libexec/rende-deploy
share=/usr/local/share/rende-deploy
confdir=/etc/rende-deploy/projects
pm2dir=/etc/rende-deploy/pm2
keys=/etc/ssh/authorized_keys

install -d -o root -g root -m 0755 \
  "${libexec}" "${share}" "${confdir}" "${pm2dir}" "${keys}" \
  /usr/local/share /etc/rende-deploy /etc/sudoers.d

install -o root -g root -m 0755 -- "${src}/receive-deploy.sh" "${libexec}/receive-deploy.sh"

rm -rf -- "${share}/examples"
install -d -o root -g root -m 0755 -- "${share}/examples"
cp -a -- "${src}/examples/." "${share}/examples/"
chown -R root:root -- "${share}/examples"
find "${share}/examples" -type d -exec chmod 0755 {} +
find "${share}/examples" -type f -exec chmod 0644 {} +

shopt -s nullglob
for conf in "${src}/examples/projects/"*.conf; do
  base=$(basename -- "${conf}")
  if [[ -e ${confdir}/${base} ]]; then
    printf 'keeping existing %s\n' "${confdir}/${base}"
  else
    install -o root -g root -m 0644 -- "${conf}" "${confdir}/${base}"
    printf 'installed %s\n' "${confdir}/${base}"
  fi
done

for eco in "${src}/examples/pm2/"*.cjs; do
  base=$(basename -- "${eco}")
  if [[ -e ${pm2dir}/${base} ]]; then
    printf 'keeping existing %s\n' "${pm2dir}/${base}"
  else
    install -o root -g root -m 0644 -- "${eco}" "${pm2dir}/${base}"
    printf 'installed %s\n' "${pm2dir}/${base}"
  fi
done
shopt -u nullglob

sudoers_src=${src}/examples/sudoers.d/rende-deploy
sudoers_dest=/etc/sudoers.d/rende-deploy
if [[ -e ${sudoers_dest} ]]; then
  printf 'keeping existing %s\n' "${sudoers_dest}"
else
  command -v visudo >/dev/null 2>&1 || die 'visudo is required to install sudoers'
  visudo -cf "${sudoers_src}"
  install -o root -g root -m 0440 -- "${sudoers_src}" "${sudoers_dest}"
  printf 'installed %s\n' "${sudoers_dest}"
fi

if id rende-deploy >/dev/null 2>&1; then
  printf 'user rende-deploy already exists; not changing its shell or home\n'
else
  useradd \
    --system \
    --create-home \
    --home-dir /var/lib/rende-deploy \
    --shell "${libexec}/receive-deploy.sh" \
    --comment 'rende.fun shared deploy' \
    rende-deploy
  printf 'created user rende-deploy\n'
fi

while IFS= read -r proj_root; do
  [[ -n ${proj_root} ]] || continue
  if [[ -d ${proj_root} ]]; then
    printf 'leaving existing %s ownership unchanged\n' "${proj_root}"
  else
    install -d -o rende-deploy -g rende-deploy -m 0755 -- "${proj_root}"
    printf 'created %s\n' "${proj_root}"
  fi
done < <(sed -n 's/^root=//p' "${src}/examples/projects/"*.conf)

if [[ ! -e ${keys}/rende-deploy ]]; then
  install -o root -g root -m 0600 /dev/null "${keys}/rende-deploy"
  printf 'created empty %s\n' "${keys}/rende-deploy"
else
  printf 'keeping existing %s\n' "${keys}/rende-deploy"
fi

if (( apply_sshd == 1 )); then
  dropin=/etc/ssh/sshd_config.d/rende-deploy.conf
  install -o root -g root -m 0644 -- "${src}/examples/sshd/rende-deploy.conf" "${dropin}"
  if ! sshd -t; then
    rm -f -- "${dropin}"
    die 'sshd -t failed; drop-in removed. ssh was not reloaded'
  fi
  printf 'sshd drop-in installed and sshd -t passed. ssh was NOT reloaded.\n'
  printf 'Review %s, then reload with: systemctl reload ssh\n' "${dropin}"
fi

cat <<'EOF'

Receiver installed. sshd was not reloaded unless --sshd was passed, and application
processes were not restarted. Existing /opt trees were not re-owned.

Still required before the first deploy:
  1. Review /etc/rende-deploy/projects/*.conf
  2. Put one public key in /etc/ssh/authorized_keys/rende-deploy
  3. Install the Match block (server/examples/sshd/rende-deploy.conf) and reload ssh
  4. Confirm each app's systemd/PM2 unit executes /opt/<project>/current
  5. Only then point a caller repo at the reusable workflow

Do not install server/examples/systemd/*.service over a live unit without diffing
it against `systemctl cat <unit>` first. This script does not copy those units.
EOF
