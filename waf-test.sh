#!/usr/bin/env bash
# waf-test.sh — Quick WAF smoke + block tests for your PrestaShop fronted by OWASP CRS
# Usage: sudo ./waf-test.sh --port 8081 --backend-local 18081

set -euo pipefail

PORT=8081                # public/scored port (WAF)
BACKEND_LOCAL=18081      # local-only backend publish (if you kept one)
HOST=127.0.0.1

usage(){ cat <<EOF
Usage: $0 [--port N] [--backend-local N] [--host IP]
Defaults: --port 8081 --backend-local 18081 --host 127.0.0.1
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2;;
    --backend-local) BACKEND_LOCAL="$2"; shift 2;;
    --host) HOST="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "[ERR] Unknown arg: $1"; usage; exit 1;;
  esac
done

have(){ command -v "$1" >/dev/null 2>&1; }

http_code(){
  curl -s -o /dev/null -w '%{http_code}' "http://$HOST:$1$2" || echo 000
}

say(){ printf '%s\n' "$*"; }

# --- 0) Show who owns the ports
say "[i] Listeners:"
ss -lntp | awk -v p=":${PORT}$" '$4~p' || echo "    (no listener on :$PORT yet)"
if [[ -n "${BACKEND_LOCAL:-}" ]]; then
  ss -lntp | awk -v p=":${BACKEND_LOCAL}$" '$4~p' || true
fi
echo

# --- 1) Basic up checks through WAF
say "[1] WAF HEAD / (expect 200/301/302/403):"
HC=$(http_code "$PORT" "/")
echo "    HTTP $HC"
[[ "$HC" != "000" ]] || { echo "[FAIL] nothing answering on :$PORT"; exit 1; }
echo

say "[2] Benign GET / (first 5 lines, truncated):"
curl -s "http://$HOST:$PORT/" | head -n 5 || true
echo

# --- 2) Block / detect tests
say "[3] SQLi probe (UNION SELECT) through WAF:"
SQL_CODE=$(http_code "$PORT" "/?id=1%20UNION%20SELECT%201")
echo "    HTTP $SQL_CODE (403=BLOCKING, 200/302=DetectionOnly)"
echo

say "[4] XSS probe through WAF:"
XSS_PAY='?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E'
XSS_CODE=$(http_code "$PORT" "/$XSS_PAY")
echo "    HTTP $XSS_CODE (403=BLOCKING, 200/302=DetectionOnly)"
echo

# --- 3) Optional: backend bypass sanity (should be reachable locally, not externally)
if [[ -n "${BACKEND_LOCAL:-}" ]]; then
  say "[5] Direct backend (localhost:$BACKEND_LOCAL) HEAD /:"
  BHC=$(http_code "$BACKEND_LOCAL" "/")
  echo "    HTTP $BHC (302 often returns to :$PORT — that’s fine)"
  # Check iptables loopback-protect (IPv4)
  if have iptables; then
    if iptables -C INPUT -p tcp --dport "$BACKEND_LOCAL" ! -s 127.0.0.1 -j DROP 2>/dev/null; then
      echo "    [OK] Non-local access to $BACKEND_LOCAL is DROPPED (bypass blocked)"
    else
      echo "    [WARN] No DROP rule found to protect $BACKEND_LOCAL from external hits"
    fi
  fi
  echo
fi

# --- 4) Pull WAF logs to show ModSecurity activity (best-effort)
say "[6] Recent WAF logs (looking for ModSecurity hits):"
WID="$(docker ps -q --filter "publish=$PORT" | head -n1)"
if [[ -z "$WID" ]]; then
  # try compose label fallback
  WID="$(docker ps -q --filter label=com.docker.compose.service=waf | head -n1 || true)"
fi
if [[ -n "$WID" ]]; then
  docker logs --tail=120 "$WID" | grep -E "ModSecurity|OWASP_CRS|Inbound Anomaly|9421|941" -n || echo "    (no recent ModSecurity lines)"
else
  echo "    (couldn't locate WAF container by port/label — skipping logs)"
fi
echo

# --- 5) Verdict
if [[ "$SQL_CODE" == "403" || "$XSS_CODE" == "403" ]]; then
  echo "[PASS] WAF is in BLOCKING mode (at least for common attacks)."
else
  echo "[PASS] WAF is reachable; likely in DetectionOnly (attacks not blocked)."
  echo "       Switch to blocking by running your protector with --enforce (paranoia ${PARANOIA:-1})."
fi

exit 0
