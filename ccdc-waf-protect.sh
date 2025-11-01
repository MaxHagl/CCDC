#!/usr/bin/env bash
# ccdc-waf-protect.sh — Put OWASP CRS WAF in front of your e-commerce app on any public port.
# Works with Docker Compose v2. Uses tmpfs for /etc/nginx/modsecurity.d (writable) and NO RO mounts.
# Starts in DetectionOnly unless --enforce is used.

set -euo pipefail

### -------- Settings (can be overridden via flags) --------
PUBLIC_PORT="${PUBLIC_PORT:-8081}"                  # Scored/public port
BACKEND_PORT="${BACKEND_PORT:-80}"                  # App's container port (usually 80)
APP_SERVICE="${APP_SERVICE:-prestashop}"            # Compose service name for the app
BASE_COMPOSE="${BASE_COMPOSE:-/opt/prestashop/docker-compose.yml}"   # Base compose path
OVERRIDE_NAME="${OVERRIDE_NAME:-compose.override.yml}"               # Override filename
WAF_IMAGE="${WAF_IMAGE:-owasp/modsecurity-crs:4.19.0-nginx-alpine-202510180710}"
ENFORCE="${ENFORCE:-0}"                             # 0=DetectionOnly, 1=Blocking
PARANOIA="${PARANOIA:-1}"                           # 1..4
ANOMALY_INBOUND="${ANOMALY_INBOUND:-10}"            # Higher to reduce noise when accessing via IP
ANOMALY_OUTBOUND="${ANOMALY_OUTBOUND:-8}"
ADD_FIREWALL_DROP="${ADD_FIREWALL_DROP:-1}"         # 1=drop non-local access to temp backend host-port
TEMP_BACKEND_HOSTPORT=""                             # e.g., 18081 to free PUBLIC_PORT
SSH_PORT="${SSH_PORT:-22}"

### -------- CLI flags --------
usage() {
  cat <<EOF
Usage: $0 [options]

  --port <N>            Public/scored port (default: ${PUBLIC_PORT})
  --backend <N>         App's internal container port (default: ${BACKEND_PORT})
  --service <name>      App's Compose service key (default: ${APP_SERVICE})
  -f | --file <yml>     Path to base compose file (default: ${BASE_COMPOSE})
  --waf-image <ref>     WAF image (default: ${WAF_IMAGE})
  --enforce             Start WAF in BLOCKING mode (default: DetectionOnly)
  --paranoia <1..4>     Paranoia level (default: ${PARANOIA})
  --temp-port <N>       Remap app's host publish to this port if it owns the public port (e.g., 18081)
  --no-fw               Do NOT add firewall drops for the temp backend port
  --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)        PUBLIC_PORT="$2"; shift 2;;
    --backend)     BACKEND_PORT="$2"; shift 2;;
    --service)     APP_SERVICE="$2"; shift 2;;
    -f|--file)     BASE_COMPOSE="$2"; shift 2;;
    --waf-image)   WAF_IMAGE="$2"; shift 2;;
    --enforce)     ENFORCE=1; shift;;
    --paranoia)    PARANOIA="$2"; shift 2;;
    --temp-port)   TEMP_BACKEND_HOSTPORT="$2"; shift 2;;
    --no-fw)       ADD_FIREWALL_DROP=0; shift;;
    --help|-h)     usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done

BASE_DIR="$(dirname "$BASE_COMPOSE")"
OVERRIDE_PATH="${BASE_DIR}/${OVERRIDE_NAME}"

command -v docker >/dev/null || { echo "[ERR] docker not found"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "[ERR] docker compose v2 required"; exit 1; }
[[ -f "$BASE_COMPOSE" ]] || { echo "[ERR] Base compose file not found: $BASE_COMPOSE"; exit 1; }

echo "[INFO] Public/scored port: ${PUBLIC_PORT}"
echo "[INFO] App service: ${APP_SERVICE}, backend container port: ${BACKEND_PORT}"
echo "[INFO] Base compose: ${BASE_COMPOSE}"
echo "[INFO] WAF image: ${WAF_IMAGE}"
echo "[INFO] Mode: $([[ $ENFORCE -eq 1 ]] && echo BLOCKING || echo DetectionOnly)"

who_owns() { ss -lntp | awk -vp=":${1}$" '$4 ~ p {print}' || true; }

# 1) Ensure the app service exists
if ! docker compose -f "$BASE_COMPOSE" config --services | grep -qx "$APP_SERVICE"; then
  echo "[ERR] Service '$APP_SERVICE' not found in $BASE_COMPOSE"
  echo "[HINT] Available services:"
  docker compose -f "$BASE_COMPOSE" config --services
  exit 1
fi

# 2) Create/overwrite override compose:
#    - Remove host publishes from app (keep only expose BACKEND_PORT)
#    - Add WAF on PUBLIC_PORT, with writable tmpfs for modsecurity.d
#    - No volumes mount (entrypoint needs to write into modsecurity.d)
echo "[INFO] Writing override: $OVERRIDE_PATH"
sudo tee "$OVERRIDE_PATH" >/dev/null <<YAML
services:
  ${APP_SERVICE}:
    ports: []                 # remove host publishes
    expose:
      - "${BACKEND_PORT}"

  waf:
    image: ${WAF_IMAGE}
    depends_on:
      - ${APP_SERVICE}
    environment:
      BACKEND: "http://${APP_SERVICE}:${BACKEND_PORT}"
      SERVER_NAME: "shop.local"
      MODSEC_RULE_ENGINE: "$([[ $ENFORCE -eq 1 ]] && echo On || echo DetectionOnly)"
      MODSEC_AUDIT_ENGINE: "on"
      BLOCKING_PARANOIA: "${PARANOIA}"
      DETECTION_PARANOIA: "${PARANOIA}"
      ANOMALY_INBOUND: "${ANOMALY_INBOUND}"
      ANOMALY_OUTBOUND: "${ANOMALY_OUTBOUND}"
    ports:
      - "${PUBLIC_PORT}:8080"   # WAF owns public port
    tmpfs:
      - /etc/nginx/modsecurity.d
YAML

# 3) If merge still leaves the app publishing PUBLIC_PORT, remap to TEMP_BACKEND_HOSTPORT
if docker compose -f "$BASE_COMPOSE" -f "$OVERRIDE_PATH" config | sed -n "/^services:/,/^volumes:/p" | awk "/^  ${APP_SERVICE}:/,/^[a-z]/" | grep -q "published: \"${PUBLIC_PORT}\""; then
  if [[ -z "${TEMP_BACKEND_HOSTPORT}" ]]; then
    echo "[WARN] ${APP_SERVICE} still publishes ${PUBLIC_PORT}. Re-run with --temp-port <N> (e.g., 18081)."
    exit 1
  fi
  echo "[INFO] Remapping app host port ${PUBLIC_PORT} -> ${TEMP_BACKEND_HOSTPORT} in base compose"
  sudo cp "$BASE_COMPOSE" "${BASE_COMPOSE}.bak.$(date +%s)"
  sudo sed -i "s/published: \"${PUBLIC_PORT}\"/published: \"${TEMP_BACKEND_HOSTPORT}\"/g" "$BASE_COMPOSE" || true
  sudo sed -i "s/\"${PUBLIC_PORT}:${BACKEND_PORT}\"/\"${TEMP_BACKEND_HOSTPORT}:${BACKEND_PORT}\"/g" "$BASE_COMPOSE" || true
fi

# 4) Recreate app (now internal only) and start WAF
echo "[INFO] Recreating app '${APP_SERVICE}' and starting WAF on :${PUBLIC_PORT}"
docker compose -f "$BASE_COMPOSE" -f "$OVERRIDE_PATH" up -d "$APP_SERVICE"

# Wait a moment for networking
sleep 1

# Ensure PUBLIC_PORT is free before starting WAF
if who_owns "$PUBLIC_PORT" | grep -q docker-proxy; then
  echo "[WARN] ${PUBLIC_PORT} still appears bound, retrying app recreate..."
  docker compose -f "$BASE_COMPOSE" -f "$OVERRIDE_PATH" rm -sf "$APP_SERVICE"
  docker compose -f "$BASE_COMPOSE" -f "$OVERRIDE_PATH" up -d "$APP_SERVICE"
  sleep 1
fi

if who_owns "$PUBLIC_PORT" | grep -q docker-proxy; then
  echo "[ERR] ${PUBLIC_PORT} is still bound by another container."
  echo "[HINT] Inspect merged config for '${APP_SERVICE}':"
  docker compose -f "$BASE_COMPOSE" -f "$OVERRIDE_PATH" config | sed -n "/${APP_SERVICE}:/,/^[a-z]/p"
  exit 1
fi

docker compose -f "$BASE_COMPOSE" -f "$OVERRIDE_PATH" up -d waf || {
  echo "[ERR] Failed to start WAF. Compose logs:"; 
  docker compose -f "$BASE_COMPOSE" -f "$OVERRIDE_PATH" logs --tail=200 waf || true; 
  exit 1;
}

# Confirm WAF is running
WID="$(docker compose -f "$BASE_COMPOSE" -f "$OVERRIDE_PATH" ps -q waf || true)"
if [[ -z "${WID}" ]]; then
  echo "[ERR] WAF container not running. Logs:"
  docker compose -f "$BASE_COMPOSE" -f "$OVERRIDE_PATH" logs --tail=200 waf || true
  exit 1
fi

echo "[INFO] Listeners on ${PUBLIC_PORT}:"
who_owns "$PUBLIC_PORT" || true

# 5) Optional: lock temp backend port to loopback
if [[ -n "${TEMP_BACKEND_HOSTPORT}" && "${ADD_FIREWALL_DROP}" -eq 1 ]]; then
  echo "[INFO] Locking backend host port ${TEMP_BACKEND_HOSTPORT} to loopback only"
  sudo iptables  -C INPUT -p tcp --dport "${TEMP_BACKEND_HOSTPORT}" ! -s 127.0.0.1 -j DROP 2>/dev/null || \
  sudo iptables  -A INPUT -p tcp --dport "${TEMP_BACKEND_HOSTPORT}" ! -s 127.0.0.1 -j DROP
  sudo ip6tables -C INPUT -p tcp --dport "${TEMP_BACKEND_HOSTPORT}" ! -s ::1        -j DROP 2>/dev/null || \
  sudo ip6tables -A INPUT -p tcp --dport "${TEMP_BACKEND_HOSTPORT}" ! -s ::1        -j DROP
fi

# 6) Keep scoring safe: allow PUBLIC_PORT + SSH
sudo iptables  -C INPUT -p tcp --dport "${PUBLIC_PORT}" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || \
sudo iptables  -I INPUT 1 -p tcp --dport "${PUBLIC_PORT}" -m conntrack --ctstate NEW -j ACCEPT
sudo iptables  -C INPUT -p tcp --dport "${SSH_PORT}"    -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || \
sudo iptables  -I INPUT 1 -p tcp --dport "${SSH_PORT}"   -m conntrack --ctstate NEW -j ACCEPT
sudo ip6tables -C INPUT -p tcp --dport "${PUBLIC_PORT}" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || \
sudo ip6tables -I INPUT 1 -p tcp --dport "${PUBLIC_PORT}" -m conntrack --ctstate NEW -j ACCEPT || true
sudo ip6tables -C INPUT -p tcp --dport "${SSH_PORT}"    -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || \
sudo ip6tables -I INPUT 1 -p tcp --dport "${SSH_PORT}"   -m conntrack --ctstate NEW -j ACCEPT || true

# 7) Quick tests
echo
echo "[TEST] HEAD via WAF http://127.0.0.1:${PUBLIC_PORT}/"
curl -sI "http://127.0.0.1:${PUBLIC_PORT}/" | head -n 5 || true
echo
echo "[TEST] Probe (expect block in enforce mode; log in detection)"
curl -s "http://127.0.0.1:${PUBLIC_PORT}/?id=1%20UNION%20SELECT%201" | head -n 20 || true

echo
echo "[OK] WAF fronting '${APP_SERVICE}:${BACKEND_PORT}' on :${PUBLIC_PORT} ($([[ $ENFORCE -eq 1 ]] && echo BLOCKING || echo DetectionOnly))."
echo "[TIP] WAF logs:  docker logs -f \$(docker compose -f \"$BASE_COMPOSE\" -f \"$OVERRIDE_PATH\" ps -q waf)"
