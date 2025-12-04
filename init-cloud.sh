#!/bin/bash
set +e

SSH_USER=$1
SSH_PASS=$2
SSH_HOST=$3
SSH_PORT=$4

LOG=/root/setup.log
echo "Setup Initiated: $(date -Iseconds)" > "$LOG"
log() { echo "$(date -Iseconds) - $*" | tee -a "$LOG"; }

# ---------------- detect local OS major
if [ -f /etc/os-release ]; then
  OS_MAJOR=$(awk -F= '/VERSION_ID/{print int($2)}' /etc/os-release 2>/dev/null || echo 9)
else
  OS_MAJOR=9
fi
log "Local OS major: $OS_MAJOR"

# ---------------- detect primary network interface (first non-loopback, non-docker)
detect_iface() {
  IFACE=$(ip -o -4 addr show scope global | awk '{print $2}' | egrep -v '^(lo|docker|br-|veth|virbr|cni|tun)' | head -n1)
  if [ -z "$IFACE" ]; then
    # fallback: first non-loopback device
    IFACE=$(ip -o link show | awk -F': ' '{print $2}' | egrep -v '^(lo|docker|br-|veth|virbr|cni|tun)' | head -n1)
  fi
  echo "$IFACE"
}
IFACE=$(detect_iface)
log "Detected local interface: ${IFACE:-<none>}"
if [ -z "$IFACE" ]; then log "No network interface detected, aborting floating-IP steps"; fi

# ---------------- change root password + disable expiry (if provided)
if [ -n "$SSH_PASS" ]; then
  echo "root:$SSH_PASS" | chpasswd 2>/dev/null && log "root password changed"
  passwd -u root 2>/dev/null || true
  chage -I -1 -m 0 -M 99999 -E -1 root 2>/dev/null || true
  chage -d $(date +%Y-%m-%d) root 2>/dev/null || true
  log "Password expiration flags updated"
else
  log "SSH_PASS empty, skipping password change"
fi

# Wait a bit so sshd stabilizes if we changed password earlier
sleep 4

# ---------------- helper: run ssh command with retries (returns stdout)
ssh_run() {
  local tries=5
  local cmd="$1"
  for i in $(seq 1 $tries); do
    out=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -p "$SSH_PORT" "$SSH_USER"@"$SSH_HOST" "$cmd" 2>/dev/null)
    rc=$?
    if [ $rc -eq 0 ] && [ -n "$out" ]; then
      echo "$out"
      return 0
    fi
    sleep 2
  done
  return 1
}

# ---------------- remote OS detection (multi-method, retry)
detect_remote_os() {
  # try /etc/os-release
  out=$(ssh_run "awk -F= '/VERSION_ID/{print int(\$2)}' /etc/os-release 2>/dev/null || true")
  if [ $? -eq 0 ] && [ -n "$out" ]; then echo "$out"; return 0; fi

  out=$(ssh_run "hostnamectl status --no-pager --pretty 2>/dev/null | sed -n 's/.*Operating System: //p' || true")
  if [ $? -eq 0 ] && [ -n "$out" ]; then
    # try to extract a major version number
    ver=$(echo "$out" | grep -oE '[0-9]+' | head -n1)
    if [ -n "$ver" ]; then echo "$ver"; return 0; fi
  fi

  out=$(ssh_run "cat /etc/redhat-release 2>/dev/null || true")
  if [ $? -eq 0 ] && [ -n "$out" ]; then
    ver=$(echo "$out" | grep -oE '[0-9]+' | head -n1)
    if [ -n "$ver" ]; then echo "$ver"; return 0; fi
  fi

  # rpm macro attempt
  out=$(ssh_run "rpm -q --qf '%{?dist}' -f /etc/os-release 2>/dev/null || true")
  if [ $? -eq 0 ] && [ -n "$out" ]; then
    ver=$(echo "$out" | grep -oE '[0-9]+' | head -n1)
    if [ -n "$ver" ]; then echo "$ver"; return 0; fi
  fi

  return 1
}

REMOTE_OS_MAJOR=$(detect_remote_os || echo "")
log "Remote OS major detected: ${REMOTE_OS_MAJOR:-<unknown>}"

# ---------------- remote floating IP detection (multi-method)
REMOTE_FLOAT_IP=""
REMOTE_FLOAT_PREF=""
log "Trying to discover floating/secondary IP on remote host..."

# 1) try legacy ifcfg-eth0:1
if ssh_run "[ -f /etc/sysconfig/network-scripts/ifcfg-eth0:1 ] && echo ok || true" &>/dev/null; then
  tmp=$(ssh_run "grep -oP 'IPADDR=\K[0-9.]+(/[0-9]+)?' /etc/sysconfig/network-scripts/ifcfg-eth0:1 2>/dev/null || true")
  if [ -n "$tmp" ]; then REMOTE_FLOAT_IP="$tmp"; fi
  log "Checked remote legacy ifcfg"
fi

# 2) try nmcli device show for eth0 (addresses typically like 1.2.3.4/32)
if [ -z "$REMOTE_FLOAT_IP" ]; then
  out=$(ssh_run "command -v nmcli >/dev/null 2>&1 && nmcli -g IP4.ADDRESS device show | sed '/^$/d' || true")
  if [ $? -eq 0 ] && [ -n "$out" ]; then
    # pick any /32 address or pick the last one which is usually secondary
    tmp=$(echo "$out" | tr '\n' ' ' | awk '{for(i=NF;i>=1;i--) print $i}' | egrep -o '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' | head -n1)
    REMOTE_FLOAT_IP="$tmp"
    log "nmcli device show returned: $tmp"
  fi
fi

# 3) try nmcli connection files (system-connections)
if [ -z "$REMOTE_FLOAT_IP" ]; then
  out=$(ssh_run "command -v grep >/dev/null 2>&1 && grep -HoP 'ipv4.addresses=\\K[^\\n]+' /etc/NetworkManager/system-connections/* 2>/dev/null | head -n1 || true")
  if [ $? -eq 0 ] && [ -n "$out" ]; then
    tmp=$(echo "$out" | tr -d '[:space:]')
    REMOTE_FLOAT_IP="$tmp"
    log "Found remote system-connections ip: $tmp"
  fi
fi

# 4) parse ip addr show on remote (prefer /32 addresses or addresses that are not the primary)
if [ -z "$REMOTE_FLOAT_IP" ]; then
  out=$(ssh_run "ip -4 -o addr show scope global 2>/dev/null | awk '{print \$2\" \"\$4\" \"\$7}' | sed 's/ $//' || true")
  if [ $? -eq 0 ] && [ -n "$out" ]; then
    # out lines like: eth0 1.2.3.4/24 brd ...  or eth0 5.6.7.8/32
    # prefer /32 (Hetzner floating) or addresses that look secondary (last)
    tmp=$(echo "$out" | awk '{print $2}' | egrep -o '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' | egrep '/32' | head -n1)
    if [ -z "$tmp" ]; then
      tmp=$(echo "$out" | awk '{print $2}' | egrep -o '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' | tail -n1)
    fi
    REMOTE_FLOAT_IP="$tmp"
    log "Remote ip addr parse returned: $tmp"
  fi
fi

# final normalize
if [ -n "$REMOTE_FLOAT_IP" ]; then
  # if it's like "1.2.3.4" add /32 for Hetzner floating
  if [[ "$REMOTE_FLOAT_IP" != */* ]]; then
    REMOTE_FLOAT_PREF="${REMOTE_FLOAT_IP}/32"
  else
    REMOTE_FLOAT_PREF="$REMOTE_FLOAT_IP"
  fi
  log "Discovered remote floating IP: $REMOTE_FLOAT_PREF"
else
  log "No floating/secondary IP discovered on remote"
fi

# ---------------- if we have a floating IP, migrate it to local
if [ -n "$REMOTE_FLOAT_PREF" ] && [ -n "$IFACE" ]; then
  # parse IP and prefix
  IP_ONLY="${REMOTE_FLOAT_PREF%%/*}"
  PREFIX="${REMOTE_FLOAT_PREF##*/}"

  # add address locally (temporary)
  ip addr add "${IP_ONLY}/${PREFIX}" dev "$IFACE" 2>/dev/null && log "ip addr add ${IP_ONLY}/${PREFIX} dev $IFACE OK" || log "ip addr add failed or already present"

  # find local gateway for IFACE (use existing default via this iface, or system default)
  GW=$(ip route show default 0.0.0.0/0 dev "$IFACE" 2>/dev/null | awk '/default/ {print $3; exit}')
  if [ -z "$GW" ]; then
    # fallback: system default gateway
    GW=$(ip route | awk '/default/ {print $3; exit}')
  fi
  log "Using gateway: ${GW:-<none>}"

  # add route for floating ip via gateway with onlink (Hetzner recommendation for /32)
  if [ -n "$GW" ]; then
    ip route replace "${IP_ONLY}/${PREFIX}" via "$GW" dev "$IFACE" onlink 2>/dev/null && log "Added onlink route via $GW" || log "Adding onlink route failed, trying direct dev route"
  else
    log "No gateway found; attempting direct dev route"
  fi

  # fallback to dev route if onlink failed
  ip route replace "${IP_ONLY}/${PREFIX}" dev "$IFACE" 2>/dev/null || log "Dev-route add failed (maybe already present)"

  # persist: prefer nmcli
  if command -v nmcli &>/dev/null; then
    # try to find connection name for the interface
    CONN=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v dev="$IFACE" '$2==dev{print $1; exit}')
    if [ -z "$CONN" ]; then
      CONN=$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v dev="$IFACE" '$2==dev{print $1; exit}')
    fi

    if [ -n "$CONN" ]; then
      CUR=$(nmcli -g ipv4.addresses connection show "$CONN" 2>/dev/null || true)
      if echo "$CUR" | grep -q "$IP_ONLY" 2>/dev/null; then
        log "IP already present in connection $CONN"
      else
        if [ -z "$CUR" ]; then
          NEWADDR="${IP_ONLY}/${PREFIX}"
        else
          NEWADDR="${CUR},${IP_ONLY}/${PREFIX}"
        fi
        nmcli connection modify "$CONN" ipv4.addresses "$NEWADDR" ipv4.method manual 2>/dev/null && log "nmcli: persisted ${IP_ONLY}/${PREFIX} into $CONN" || log "nmcli modify failed for $CONN"
        nmcli connection up "$CONN" 2>/dev/null || nmcli device reapply "$IFACE" 2>/dev/null || log "nmcli up/reapply failed"
      fi
    else
      # create a shallow connection specifically for secondary
      nmcli connection add type ethernet ifname "$IFACE" con-name "${IFACE}-floating-${IP_ONLY}" ipv4.addresses "${IP_ONLY}/${PREFIX}" ipv4.method manual autoconnect yes 2>/dev/null && log "Created new nm connection for floating IP" || log "Failed creating new nm connection for floating IP"
    fi
  else
    # no nmcli: if OS 9 create legacy ifcfg alias
    if [ "$OS_MAJOR" -le 9 ]; then
      LOCAL_IFCFG="/etc/sysconfig/network-scripts/ifcfg-${IFACE}:1"
      if [ ! -f "$LOCAL_IFCFG" ]; then
        NETMASK=""
        # convert prefix to netmask
        cidr_to_netmask() {
          p=$1; mask=""; for i in 0 1 2 3; do
            if [ $p -ge 8 ]; then v=255; p=$((p-8)); else v=$((256 - 2**(8-p))); p=0; fi
            mask+="$v"; if [ $i -lt 3 ]; then mask+="."; fi
          done; echo "$mask"
        }
        NETMASK=$(cidr_to_netmask "$PREFIX")
        cat > "$LOCAL_IFCFG" <<EOF
DEVICE=${IFACE}:1
ONBOOT=yes
BOOTPROTO=none
IPADDR=${IP_ONLY}
PREFIX=${PREFIX}
NETMASK=${NETMASK}
EOF
        chmod 644 "$LOCAL_IFCFG"
        log "Created legacy ifcfg alias $LOCAL_IFCFG"
      else
        log "$LOCAL_IFCFG exists, not overwriting"
      fi
    else
      log "No nmcli and not OS9 — cannot persist floating IP automatically; manual nm connection file needed"
    fi
  fi

  log "Floating IP migration applied for ${IP_ONLY}/${PREFIX} on $IFACE"
else
  log "Skipping floating-IP migration (either none detected on remote or no local iface)"
fi

log "Networking migration attempt complete"
log "All done."
exit 0