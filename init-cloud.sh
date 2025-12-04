#!/bin/bash

set +e  # Don't exit on error (we log errors)

# Input vars
SSH_USER=$1
SSH_PASS=$2
SSH_HOST=$3
SSH_PORT=$4

LOG=/root/setup.log
echo "Setup Initiated: $(date -Iseconds)" > "$LOG"

# helper: log
log() {
  echo "$(date -Iseconds) - $*" | tee -a "$LOG"
}

# ===== Detect local OS major version (Rocky 9 vs 10)
if [ -f /etc/os-release ]; then
  OS_MAJOR=$(awk -F= '/VERSION_ID/{print int($2)}' /etc/os-release)
else
  OS_MAJOR=9
fi
log "Local OS major version detected: $OS_MAJOR"

# ===== Change root password and disable password expiration (compatible)
if [ -n "$SSH_PASS" ]; then
  echo "root:$SSH_PASS" | chpasswd 2>/dev/null && log "Root password changed"
else
  log "SSH_PASS empty, skipping root password change"
fi

# try to unlock & remove expiration flags (works on both)
passwd -u root 2>/dev/null || true
chage -I -1 -m 0 -M 99999 -E -1 root 2>/dev/null || true
chage -d $(date +%Y-%m-%d) root 2>/dev/null || true
log "Password expiration flags updated"

# ===== Test Gemini (small function)
URL="https://gemini.google.com/"
response=$(curl -4 -s -w "%{http_code}" "$URL")
http_code="${response: -3}"
body="${response::-3}"
isBlocked=false
if [[ "$http_code" =~ ^4[0-9][0-9]$ ]] || [[ "$body" == *"Gemini isn’t currently supported in your country"* ]]; then
    isBlocked=true
fi
log "isBlocked: $isBlocked"

# ===== Base packages installation (use dnf if available)
PKG_MANAGER="yum"
if command -v dnf &>/dev/null; then
  PKG_MANAGER="dnf"
fi
log "Using package manager: $PKG_MANAGER"

$PKG_MANAGER -y install epel-release || log "epel-release install failed (continuing)"
$PKG_MANAGER -y install htop wget vim telnet firewalld sshpass nginx || log "some base packages failed to install"
log "Installed requirements including nginx (if available)"

# ===== Firewall setup (support older firewall-offline-cmd on R9)
if command -v firewall-offline-cmd &>/dev/null; then
  firewall-offline-cmd --add-port "$SSH_PORT"/tcp 2>/dev/null || true
fi

systemctl enable --now firewalld || log "firewalld enable/start failed"
for port in $SSH_PORT 80 443 8080 8443 2082 2083; do
  for proto in tcp udp; do
    firewall-cmd --permanent --add-port=${port}/${proto} 2>/dev/null || true
  done
done
firewall-cmd --reload 2>/dev/null || log "firewall-cmd reload failed"
log "Firewall configured"

# ===== Speedtest CLI: dual approach
if [ "$OS_MAJOR" -eq 9 ]; then
  log "Installing speedtest via packagecloud for Rocky 9"
  curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | bash 2>/dev/null || log "speedtest repo script failed"
  $PKG_MANAGER -y install speedtest || log "speedtest install failed"
else
  log "Installing speedtest binary for Rocky 10"
  # fetch latest stable binary (fallback). You might want to update URL if new version exists.
  TMPDIR=$(mktemp -d)
  cd "$TMPDIR" || exit 1
  # try to download tarball (if fails, skip)
  if wget -qO speedtest.tgz "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"; then
    tar xzf speedtest.tgz
    if [ -f speedtest ]; then
      mv speedtest /usr/local/bin/speedtest
      chmod +x /usr/local/bin/speedtest
      log "speedtest binary installed"
    fi
  else
    log "speedtest binary download failed, skipping"
  fi
  cd - >/dev/null || true
  rm -rf "$TMPDIR"
fi

# ===== Docker / moby installation (dual)
if command -v dnf &>/dev/null; then
  dnf install -y dnf-plugins-core || true
fi

if [ "$OS_MAJOR" -eq 9 ]; then
  log "Installing docker-ce for Rocky 9"
  $PKG_MANAGER -y install yum-utils 2>/dev/null || true
  if command -v dnf &>/dev/null; then
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true
  else
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true
  fi
  $PKG_MANAGER -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin || log "docker-ce install failed"
else
  log "Installing moby-engine for Rocky 10 (docker alternative)"
  # try moby packages
  $PKG_MANAGER -y install moby-engine moby-cli moby-buildx moby-compose || log "moby install failed"
fi

# enable & start docker (moby provides same service name on many systems)
systemctl enable --now docker 2>/dev/null || systemctl enable --now moby 2>/dev/null || log "docker/moby enable failed"
docker ps >/dev/null 2>&1 || log "docker process not running or docker command failed"
log "Docker installation attempted"

# ===== Prepare logs for sssd (best-effort)
mkdir -p /var/log/sssd
: > /var/log/sssd/sssd_kcm.log || true

# ===== Remote copy of /opt items (conf.d outline myvpn)
for item in conf.d outline myvpn; do
  sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -r -P "$SSH_PORT" root@"$SSH_HOST":/opt/"$item"/ /opt/ 2>/dev/null || log "scp /opt/$item failed or not present on source"
done

# ===== nginx setup copy (if available on source)
systemctl enable --now nginx 2>/dev/null || log "nginx enable/start failed"
sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -P "$SSH_PORT" root@"$SSH_HOST":/etc/nginx/nginx.conf /etc/nginx/nginx.conf 2>/dev/null || log "nginx.conf not copied"
systemctl restart nginx 2>/dev/null || log "nginx restart failed"
log "Configured nginx (best-effort)"

# ===== Change SSH port in sshd_config
if [ -n "$SSH_PORT" ]; then
  if grep -q "^#Port 22" /etc/ssh/sshd_config 2>/dev/null; then
    sed -i 's/^#Port 22/Port '"$SSH_PORT"'/g' /etc/ssh/sshd_config
  else
    # replace any existing Port line or append
    if grep -q "^Port " /etc/ssh/sshd_config 2>/dev/null; then
      sed -i 's/^Port .*/Port '"$SSH_PORT"'/g' /etc/ssh/sshd_config
    else
      echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
    fi
  fi
  systemctl restart sshd 2>/dev/null || log "sshd restart failed (check sshd service name)"
  log "Changed ssh port to $SSH_PORT"
else
  log "SSH_PORT empty, skipping SSH port change"
fi

# ===== Outline setup (best-effort)
rm -rf /opt/outline/access.txt 2>/dev/null || true
wget -q https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh -O /root/install_server.sh 2>/dev/null || log "Outline installer download failed"
chmod 755 /root/install_server.sh 2>/dev/null || true
if [ -f /root/install_server.sh ]; then
  /root/install_server.sh --keys-port 443 --api-port 2083 >/dev/null 2>&1 || log "outline-server installer run failed"
  log "Outline installer invoked (if supported)"
fi

# ===== Networking: migrate secondary IP from source to local (works for R9<->R10 and R10<->R10)
log "Starting secondary IP migration attempt from $SSH_HOST"

REMOTE_OS_MAJOR=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" root@"$SSH_HOST" "awk -F= '/VERSION_ID/{print int(\$2)}' /etc/os-release 2>/dev/null || echo 9" 2>/dev/null)
log "Remote OS major version detected: $REMOTE_OS_MAJOR"

# try to fetch ifcfg-eth0:1 from remote (legacy)
IFCFG_REMOTE="/etc/sysconfig/network-scripts/ifcfg-eth0:1"
TMP_IFCFG="/tmp/ifcfg-eth0:1.remote"
sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -P "$SSH_PORT" root@"$SSH_HOST":"$IFCFG_REMOTE" "$TMP_IFCFG" 2>/dev/null
if [ -f "$TMP_IFCFG" ]; then
  log "Found remote legacy ifcfg file"
  # extract IPADDR or IPADDR0 etc
  IPADDR=$(grep -oP 'IPADDR=\K[0-9.]+(/[0-9]+)?' "$TMP_IFCFG" | head -n1)
fi

# if not found, try nmcli on remote to get secondary address
if [ -z "$IPADDR" ]; then
  log "Legacy ifcfg not found, trying nmcli on remote"
  # prefer showing addresses on device eth0 (if exists)
  REMOTE_NM_IPS=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" root@"$SSH_HOST" "command -v nmcli >/dev/null 2>&1 && nmcli -g IP4.ADDRESS device show eth0 2>/dev/null || true" 2>/dev/null)
  if [ -n "$REMOTE_NM_IPS" ]; then
    # nmcli may return lines like 192.0.2.5/24
    IPADDR=$(echo "$REMOTE_NM_IPS" | head -n1 | tr -d '[:space:]')
    log "Remote nmcli device show returned: $IPADDR"
  else
    # fallback: check system-connections files for ipv4.addresses
    REMOTE_CONN_IP=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" root@"$SSH_HOST" "grep -HoP 'ipv4.addresses=\\K[^\\n]+' /etc/NetworkManager/system-connections/* 2>/dev/null | head -n1 || true" 2>/dev/null)
    if [ -n "$REMOTE_CONN_IP" ]; then
      IPADDR=$(echo "$REMOTE_CONN_IP" | tr -d '[:space:]')
      log "Found remote nm connection ip: $IPADDR"
    fi
  fi
fi

# extra fallback: try parsing 'ip addr' on remote to find secondary addresses (addresses not on eth0 primary)
if [ -z "$IPADDR" ]; then
  log "Trying remote 'ip addr' parse as last resort"
  REMOTE_IPS=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" root@"$SSH_HOST" "ip -4 -o addr show scope global | awk '{print \$4}'" 2>/dev/null)
  # prefer non-primary addresses: if more than 1, pick the one not equal to device primary (heuristic)
  if [ -n "$REMOTE_IPS" ]; then
    # choose last addr (often the secondary)
    IPADDR=$(echo "$REMOTE_IPS" | awk 'NR>1{print $0}' | head -n1)
    if [ -z "$IPADDR" ]; then
      IPADDR=$(echo "$REMOTE_IPS" | head -n1)
    fi
    IPADDR=$(echo "$IPADDR" | tr -d '[:space:]')
    log "Remote ip addr show returned: $IPADDR"
  fi
fi

# final check
if [ -z "$IPADDR" ]; then
  log "No secondary IP found on remote (nothing to migrate)"
else
  log "Secondary IP to migrate: $IPADDR"

  # parse IP and prefix
  # IPADDR may be "192.0.2.5/24" or "192.0.2.5"
  if [[ "$IPADDR" == *"/"* ]]; then
    IP_ONLY="${IPADDR%%/*}"
    PREFIX="${IPADDR##*/}"
  else
    IP_ONLY="$IPADDR"
    PREFIX="32"
  fi

  # helper to convert prefix to netmask (for legacy ifcfg)
  cidr_to_netmask() {
    local p=$1
    local mask=""
    local i
    local v
    for ((i=0;i<4;i++)); do
      if [ $p -ge 8 ]; then
        v=255
        p=$((p-8))
      else
        v=$((256 - 2**(8-p)))
        p=0
      fi
      mask+="$v"
      if [ $i -lt 3 ]; then mask+="."; fi
    done
    echo "$mask"
  }

  NETMASK=$(cidr_to_netmask "$PREFIX")
  log "Parsed: IP=$IP_ONLY PREFIX=$PREFIX NETMASK=$NETMASK"

  # apply immediately (ip command)
  ip addr add "${IP_ONLY}/${PREFIX}" dev eth0 2>/dev/null || log "ip addr add failed (maybe already present)"

  # persist based on local OS type
  if [ "$OS_MAJOR" -le 9 ]; then
    # create legacy ifcfg alias if not exists
    LOCAL_IFCFG="/etc/sysconfig/network-scripts/ifcfg-eth0:1"
    if [ ! -f "$LOCAL_IFCFG" ]; then
      cat > "$LOCAL_IFCFG" <<EOF
DEVICE=eth0:1
ONBOOT=yes
BOOTPROTO=none
IPADDR=${IP_ONLY}
PREFIX=${PREFIX}
NETMASK=${NETMASK}
EOF
      chmod 644 "$LOCAL_IFCFG"
      log "Created legacy $LOCAL_IFCFG to persist alias"
    else
      log "$LOCAL_IFCFG already exists, not overwriting"
    fi
  else
    # Rocky 10 -> use nmcli to add secondary address to connection 'eth0' or to device
    if command -v nmcli &>/dev/null; then
      # try to find connection name for device eth0
      CONN_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v dev=eth0 '$2==dev{print $1; exit}')
      if [ -z "$CONN_NAME" ]; then
        # fallback: first connection touching eth0
        CONN_NAME=$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v dev=eth0 '$2==dev{print $1; exit}')
      fi

      if [ -n "$CONN_NAME" ]; then
        # append address to ipv4.addresses list
        # get current addresses
        CUR=$(nmcli -g ipv4.addresses connection show "$CONN_NAME" 2>/dev/null || true)
        if [ -z "$CUR" ]; then
          NEWADDR="${IP_ONLY}/${PREFIX}"
        else
          # ensure we don't duplicate
          if echo "$CUR" | grep -q "$IP_ONLY"; then
            NEWADDR="$CUR"
          else
            NEWADDR="${CUR},${IP_ONLY}/${PREFIX}"
          fi
        fi
        nmcli connection modify "$CONN_NAME" ipv4.addresses "$NEWADDR" ipv4.method manual 2>/dev/null || log "nmcli modify failed for $CONN_NAME"
        nmcli connection up "$CONN_NAME" 2>/dev/null || nmcli device reapply eth0 2>/dev/null || log "nmcli up/reapply failed"
        log "Persisted secondary IP via nmcli on connection $CONN_NAME"
      else
        # if no connection found, create a new connection for alias
        nmcli connection add type ethernet ifname eth0 con-name eth0-secondary ipv4.addresses "${IP_ONLY}/${PREFIX}" ipv4.method manual autoconnect yes 2>/dev/null && log "Created new nm connection 'eth0-secondary' with ${IP_ONLY}/${PREFIX}" || log "Failed to create nm connection for alias"
      fi
    else
      log "nmcli not available to persist secondary IP on Rocky 10; you may need to create system-connections file manually"
    fi
  fi
fi

log "Networking migration attempt complete"

# ===== Final message
log "All done."

exit 0