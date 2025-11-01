#!/usr/bin/env bash
# Splunk UF harden (Ubuntu)
# -------------------------
# What it does:
#   • Backs up UF config, tightens perms on system/local.
#   • (Optional) Enforces TLS verification for forwarding: sslVerifyServerCert=true + sslRootCAPath.
#   • Firewalls mgmt port 8089: allow loopback only, deny inbound from network (UFW).
# Usage:
#   sudo CA_FILE=/path/to/indexer-ca.pem ./harden-splunk-uf.sh
#   # If you don’t have a CA yet, run without CA_FILE; TLS verification step will be skipped (warned).

set -euo pipefail

# ----- settings -----
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunkforwarder}"
LOCAL_DIR="$SPLUNK_HOME/etc/system/local"
BACKUP_DIR="/var/backups"
TS="$(date +%Y%m%d-%H%M%S)"
CA_FILE="${CA_FILE:-}"   # path to indexer CA PEM (recommended)
CERT_DIR="$SPLUNK_HOME/etc/auth/mycerts"
CA_DEST="$CERT_DIR/indexer-ca.pem"

b(){ printf "\033[1m%s\033[0m\n" "$*"; }

# ----- sanity checks -----
[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
[ -x "$SPLUNK_HOME/bin/splunk" ] || { echo "Splunk UF not found at $SPLUNK_HOME." >&2; exit 2; }
mkdir -p "$LOCAL_DIR" "$BACKUP_DIR"

# ----- backup current config -----
b "Backing up Splunk UF config"
tar -C "$SPLUNK_HOME/etc" -czf "$BACKUP_DIR/splunkuf-local-$TS.tgz" system/local 2>/dev/null || true
echo "Backup: $BACKUP_DIR/splunkuf-local-$TS.tgz"

# ----- secure permissions on local configs -----
b "Tightening permissions on $LOCAL_DIR"
find "$LOCAL_DIR" -type d -exec chmod 750 {} \; 2>/dev/null || true
find "$LOCAL_DIR" -type f -exec chmod 640 {} \; 2>/dev/null || true
# Keep ownership consistent with existing tree
chown -R --reference="$SPLUNK_HOME/etc" "$LOCAL_DIR" 2>/dev/null || true

# ----- enforce TLS verification for forwarding (if CA provided) -----
if [[ -n "$CA_FILE" && -f "$CA_FILE" ]]; then
  b "Enforcing TLS verification for outputs (sslVerifyServerCert=true)"
  mkdir -p "$CERT_DIR"
  cp -f "$CA_FILE" "$CA_DEST"
  chmod 600 "$CA_DEST"
  chown --reference="$SPLUNK_HOME/etc" "$CA_DEST"

  # Ensure global tcpout settings exist
  OUT="$LOCAL_DIR/outputs.conf"
  touch "$OUT"
  # Append (idempotently-ish): remove prior global verify lines we added before
  sed -i '/^sslVerifyServerCert *=/d;/^sslRootCAPath *=/d' "$OUT" || true
  # Add/ensure [tcpout] stanza exists
  grep -q '^\[tcpout\]' "$OUT" || echo "[tcpout]" >> "$OUT"
  {
    echo "sslVerifyServerCert = true"
    echo "sslRootCAPath = $CA_DEST"
    echo "useACK = true"
  } >> "$OUT"
else
  b "Skipping TLS verification hardening (no CA_FILE provided)."
  echo "TIP: Run again with CA_FILE=/path/to/indexer-ca.pem to enable server cert verification."
fi

# ----- firewall the UF management port (8089) -----
b "Locking down management port 8089 with UFW (localhost only)"
if command -v ufw >/dev/null 2>&1; then
  # Allow localhost to 8089, deny everyone else inbound
  ufw allow from 127.0.0.1 to any port 8089 proto tcp >/dev/null 2>&1 || true
  ufw deny 8089/tcp >/dev/null 2>&1 || true
  # Do not auto-enable UFW (respect existing policy). Show status if UFW is active.
  ufw status | sed -n '1,200p'
else
  echo "UFW not installed; skipping firewall step. You can: apt-get install -y ufw"
fi

# ----- restart UF -----
b "Restarting Splunk UF"
systemctl restart splunkforwarder || "$SPLUNK_HOME/bin/splunk" restart --answer-yes --no-prompt

# ----- quick checks -----
b "Quick checks"
echo "• splunkd status:"; systemctl --no-pager -l status splunkforwarder | sed -n '1,15p' || true
echo "• outputs (merged):"; "$SPLUNK_HOME/bin/splunk" btool outputs list --debug | sed -n '1,80p' || true
echo "• listening sockets (expect 8089 on localhost only):"
ss -ltnp | awk '$4 ~ /:8089$/ {print}'

b "Done. Rollback:"
echo "  tar -C \"$SPLUNK_HOME/etc\" -xzf \"$BACKUP_DIR/splunkuf-local-$TS.tgz\""
echo "  (Optionally) ufw delete deny 8089/tcp && ufw delete allow from 127.0.0.1 to any port 8089 proto tcp"
