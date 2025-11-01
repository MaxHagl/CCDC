#!/usr/bin/env bash
set -euo pipefail

# ===== EDIT ME: list ONLY the scored services =====
# Format: tcp:80  udp:53  (if proto omitted -> tcp)
ALLOW_LIST=(
  tcp:80      # HTTP (use tcp:8080 if scorer uses 8080)
  tcp:443     # HTTPS (set to tcp:0 to disable)
  udp:53    # DNS (uncomment if scored)
  # tcp:25 tcp:465 tcp:587  # SMTP variants (uncomment if scored)
  # tcp:110 tcp:995 tcp:143 tcp:993  # POP/IMAP (uncomment if scored)
  # udp:123   # NTP (uncomment if scored)
)

# ===== Don’t touch below unless you need to =====
SSH_PORT=${SSH_PORT:-22}                                 # keep your shell open
EXTERN_HTTP_PORT=${EXTERN_HTTP_PORT:-80}                 # make sure WAF/web port is allowed
EXTERN_HTTPS_PORT=${EXTERN_HTTPS_PORT:-443}              # set to 0 to skip
[[ "$EXTERN_HTTP_PORT"  != "0" ]] && ALLOW_LIST+=("tcp:${EXTERN_HTTP_PORT}")
[[ "${EXTERN_HTTPS_PORT:-0}" != "0" ]] && ALLOW_LIST+=("tcp:${EXTERN_HTTPS_PORT}")

# Always allow loopback + established
allow_base() {
  sudo "$1" -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
  sudo "$1" -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  sudo "$1" -C INPUT -i lo -j ACCEPT 2>/dev/null || sudo "$1" -I INPUT 1 -i lo -j ACCEPT
}

# Allow a port (v4/v6)
allow_svc() {
  local proto="$1" port="$2"
  [[ "$port" == "0" ]] && return 0
  sudo iptables  -C INPUT -p "$proto" --dport "$port" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || \
  sudo iptables  -I INPUT 1 -p "$proto" --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
  sudo ip6tables -C INPUT -p "$proto" --dport "$port" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || \
  sudo ip6tables -I INPUT 1 -p "$proto" --dport "$port" -m conntrack --ctstate NEW -j ACCEPT || true
}

# 0) Ensure we don’t lock out SSH
allow_svc tcp "$SSH_PORT"

# 1) Baseline allows
allow_base iptables
allow_base ip6tables || true

# 2) Allow the scored services
for item in "${ALLOW_LIST[@]}"; do
  if [[ "$item" == *:* ]]; then proto="${item%%:*}"; port="${item##*:}"; else proto=tcp; port="$item"; fi
  allow_svc "$proto" "$port"
  echo "[OK] Allowed ${proto^^}/${port}"
done

# 3) Default-deny everything else (INPUT only)
sudo iptables  -P INPUT DROP
sudo ip6tables -P INPUT DROP 2>/dev/null || true

echo "[DONE] Default-deny enforced. Allowed: SSH:$SSH_PORT + ${ALLOW_LIST[*]}"
echo "[HINT] Rollback: run fw-rollback.sh"
