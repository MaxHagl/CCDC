#!/usr/bin/env bash
set -euo pipefail
# Set INPUT back to ACCEPT and flush only INPUT rules (leave other tables alone)
sudo iptables  -P INPUT ACCEPT
sudo iptables  -F INPUT
sudo ip6tables -P INPUT ACCEPT 2>/dev/null || true
sudo ip6tables -F INPUT       2>/dev/null || true
echo "[OK] Firewall rolled back (INPUT ACCEPT + flushed)."
