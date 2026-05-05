#!/usr/bin/env bash
# install-update-stack.sh — install the unattended update stack on a Proxmox host.
# Idempotent. Run as root on the Proxmox node.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$(readlink -f "$0")")"/.. && pwd)
SCRIPTS=$REPO_DIR/scripts

[[ $EUID -eq 0 ]] || { echo "must run as root"; exit 1; }

echo "[Fred] installing dependencies"
apt-get update
apt-get install -y msmtp msmtp-mta ca-certificates jq curl openssh-client python3-yaml

if ! command -v yq >/dev/null 2>&1; then
  echo "[Fred] yq not in apt; installing static binary"
  curl -fsSL -o /usr/local/bin/yq \
    https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
  chmod +x /usr/local/bin/yq
fi

echo "[Fred] installing scripts to /usr/local/sbin and /usr/local/lib"
install -m 0755 -d /usr/local/sbin /usr/local/lib /etc/update /var/log/update /var/lib/container-update
install -m 0644 "$SCRIPTS/lib-update.sh" /usr/local/lib/lib-update.sh
for f in update-all.sh update-pve-host.sh update-pve-lxc.sh update-pve-vms.sh \
         update-truenas-docker.sh update-webserver.sh update-containers.sh \
         notify-email.sh; do
  install -m 0755 "$SCRIPTS/$f" "/usr/local/sbin/$f"
done
ln -sf /usr/local/sbin/update-all.sh /usr/local/sbin/run-update

if [[ ! -f /etc/msmtprc ]]; then
  echo "[Fred] dropping /etc/msmtprc template (chmod 600)"
  install -m 0600 "$SCRIPTS/templates/msmtprc" /etc/msmtprc
  chown root:root /etc/msmtprc
fi

if [[ ! -f /etc/update/inventory.yaml ]]; then
  echo "[Fred] dropping /etc/update/inventory.yaml from example"
  install -m 0644 "$REPO_DIR/inventory.example.yaml" /etc/update/inventory.yaml
fi

if [[ ! -f /root/.ssh/update_id_ed25519 ]]; then
  echo "[Fred] generating SSH key /root/.ssh/update_id_ed25519"
  install -m 0700 -d /root/.ssh
  ssh-keygen -t ed25519 -N '' -C "fred-update-key" -f /root/.ssh/update_id_ed25519
fi

cat >/etc/systemd/system/update.service <<'UNIT'
[Unit]
Description=Fred — unattended infrastructure update
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/update-all.sh
Environment=NOTIFY=jemplayer82@gmail.com
Nice=10
IOSchedulingClass=idle
UNIT

cat >/etc/systemd/system/update.timer <<'TIMER'
[Unit]
Description=Daily Fred update

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
TIMER

cat >/etc/logrotate.d/update <<'LOGROT'
/var/log/update/*.log /var/log/container-update.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
LOGROT

systemctl daemon-reload
systemctl enable --now update.timer

cat <<EOF

[Fred] Install complete.

Next steps:
  1. Edit /etc/msmtprc and replace REPLACE_WITH_GOOGLE_APP_PASSWORD with a 16-char
     Google App Password (https://myaccount.google.com/apppasswords).
  2. Edit /etc/update/inventory.yaml — set truenas.host, webservers, pbs.storage,
     and truenas.zfs_rollback.datasets to match your environment.
  3. Add this pubkey to ~/.ssh/authorized_keys on TrueNAS, the webserver, and any
     VMs that don't have qemu-guest-agent installed:

$(cat /root/.ssh/update_id_ed25519.pub)

  4. Test: sudo systemctl start update.service
           journalctl -u update.service -f
     or:   sudo run-update --dry-run
EOF
