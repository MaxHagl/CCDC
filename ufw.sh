# Ubuntu UFW baseline firewall
# --------------------------------
# What it does:
#   - Ensures UFW is installed, then resets any existing rules.
#   - Sets default policies: deny incoming, allow outgoing.
#   - Allows web (80/tcp, 443/tcp), DNS (53/tcp, 53/udp), NTP (123/udp),
#     and RNDC (953/tcp, 953/udp).
#   - (Optional) SSH 22/tcp — uncomment the line in the script if you need remote access.
#   - Enables UFW and shows the resulting rule set.
#
# How to change it:
#   - Add/remove ports by editing the `ufw allow ...` lines below.
#       e.g., allow SMTP:   ufw allow 25/tcp
#             remove rule:  ufw delete allow 80/tcp
#   - Restrict to a source network:
#       ufw allow from 10.0.0.0/24 to any port 22 proto tcp
#   - Adjust defaults if needed:
#       ufw default deny outgoing   # (rare) lock down egress
#
# Safety:
#   - BEFORE enabling on a remote host, ensure SSH is allowed or you may lock yourself out.
# Usage:
#   sudo ./ufw-baseline.sh


set -euo pipefail

# Root check
[ "$(id -u)" -ne 0 ] && echo "Run as root" >&2 && exit 1

# Ensure UFW is installed
if ! command -v ufw >/dev/null 2>&1; then
  apt-get update -y && apt-get install -y ufw
fi

# Clean slate
ufw --force reset

# Default policy: drop inbound, allow outbound
ufw default deny incoming
ufw default allow outgoing

# Allow HTTP/HTTPS
ufw allow 80/tcp
ufw allow 443/tcp

# Allow DNS (TCP/UDP) and NTP (UDP)
ufw allow 53/tcp
ufw allow 53/udp
ufw allow 123/udp

# Allow RNDC (port 953) like your original (both TCP/UDP for parity)
ufw allow 953/tcp
ufw allow 953/udp

# ICMP: UFW’s defaults allow essential ICMP; no explicit rule needed.
# If you NEED SSH access, add BEFORE enabling:
# ufw allow 22/tcp

# Enable firewall
ufw --force enable

# Show result
ufw status numbered
