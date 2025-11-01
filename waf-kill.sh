#!/usr/bin/env bash
# waf-kill.sh — Remove any running WAF containers and the compose WAF service.
# Defaults match your PrestaShop stack at /opt/prestashop.

set -euo pipefail

# --- Defaults (override via flags) ---
BASE_DIR="/opt/prestashop"
BASE_COMPOSE=""
OVERRIDE_COMPOSE=""
PUBLIC_PORT="8081"     # scored/public port to verify
SHOW_PORTS_REGEX='waf|8081|18081'

# --- Helpers ---
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<USAGE
Usage: sudo waf-kill.sh [options]

Options:
  -b, --base-dir <dir>      Base directory for compose files (default: /opt/prestashop)
  -f, --file <path>         Explicit base compose file (default: <base-dir>/docker-compose.yml)
  -o, --override <path>     Explicit override compose file (default: <base-dir>/compose.override.yml)
  -p, --port <N>            Public/scored port to check and report (default: 8081)
  -h, --help                Show this help

Examples:
  sudo waf-kill.sh
  sudo waf-kill.sh -b /opt/prestashop -p 8081
USAGE
}

# --- Parse flags ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--base-dir) BASE_DIR="$2"; shift 2;;
    -f|--file)     BASE_COMPOSE="$2"; shift 2;;
    -o|--override) OVERRIDE_COMPOSE="$2"; shift 2;;
    -p|--port)     PUBLIC_PORT="$2"; shift 2;;
    -h|--help)     usage; exit 0;;
    *) echo "[ERR] Unknown option: $1"; usage; exit 1;;
  esac
done

# Compose command (v2 plugin preferred, fallback to docker-compose)
if have docker && docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif have docker-compose; then
  COMPOSE="docker-compose"
else
  echo "[ERR] Neither 'docker compose' nor 'docker-compose' found."; exit 1
fi

# Compose file paths
: "${BASE_COMPOSE:=${BASE_DIR%/}/docker-compose.yml}"
: "${OVERRIDE_COMPOSE:=${BASE_DIR%/}/compose.override.yml}"

# Pretty print function
say() { printf '%s\n' "$*"; }

# --- Start ---
say "[*] Using compose files:"
say "    base:     $BASE_COMPOSE"
say "    override: $OVERRIDE_COMPOSE (if present)"
say

# 1) Remove any standalone/test WAF containers
say "[*] Removing any standalone WAF containers…"
for name in prestashop-waf-1 waf waf-test waf-proof; do
  docker rm -f "$name" 2>/dev/null && say "    - removed container: $name" || true
done
say

# 2) Remove compose-managed WAF service (if files exist)
if [[ -f "$BASE_COMPOSE" && -f "$OVERRIDE_COMPOSE" ]]; then
  say "[*] Removing compose-managed WAF service (with override)…"
  $COMPOSE -f "$BASE_COMPOSE" -f "$OVERRIDE_COMPOSE" rm -sf waf 2>/dev/null || true
elif [[ -f "$BASE_COMPOSE" ]]; then
  say "[*] Removing compose-managed WAF service (base only)…"
  $COMPOSE -f "$BASE_COMPOSE" rm -sf waf 2>/dev/null || true
else
  say "[WARN] Base compose not found: $BASE_COMPOSE (skipping compose removal)"
fi
say

# 3) Report listener status on PUBLIC_PORT
say "[*] Checking listener on :$PUBLIC_PORT …"
if ss -lntp | awk -v p=":${PUBLIC_PORT}$" '$4 ~ p {print; found=1} END{exit found?0:1}'; then
  say "[WARN] :$PUBLIC_PORT is still bound by the above process."
else
  say "[OK] :$PUBLIC_PORT is free."
fi
say

# 4) Show containers on relevant ports
say "[*] Current containers & port publishes (filtered):"
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep -E "$SHOW_PORTS_REGEX" || say "(none)"
say

say "[DONE] Old WAF removed. You can now run your protector script."

exit 0
