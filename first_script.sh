# Ubuntu minimal backup snapshot
# --------------------------------
# Purpose: Create a quick, plain backup of key system configs.
# What it does:
#   - Requires root.
#   - Copies PAM configs/modules (/etc/pam.d, /etc/pam.conf if present,
#     and /lib/*-linux-gnu/security) to /var/backups.
#   - Copies the entire /etc tree to /var/backups (preserves perms/ownership).
#   - If /var/www exists, copies it to /var/backups.
#   - If MySQL/MariaDB is present, runs:
#       mysqldump -u root -p --all-databases > /var/backups/mysql.sql
# Notes:
#   - Uses `cp -a` (no compression/rotation); re-runs may overwrite prior copies.
#   - /var/backups may contain sensitive data; protect accordingly.
# Usage: sudo ./this-script.sh
#!/bin/sh

# Root check
if [ "$(id -u)" -ne 0 ]; then
    echo "Script must be run as root"
    exit 1
fi

# Simple bold echo
becho() {
    if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
        printf "%s%s...%s\n" "$(tput bold)" "$*" "$(tput sgr0)"
    else
        printf "%s...\n" "$*"
    fi
}

# Create backups directory
mkdir -p /var/backups

becho "Backing up PAM"
# Ubuntu: configs live in /etc/pam.d (optionally pam.conf)
[ -e /etc/pam.conf ] && cp -a /etc/pam.conf /var/backups
[ -d /etc/pam.d ] && cp -a /etc/pam.d /var/backups
# PAM modules (Ubuntu uses /lib/*-linux-gnu/security)
for d in /lib/*-linux-gnu/security /lib/security /lib/security*; do
    [ -d "$d" ] && cp -a "$d" /var/backups
done

becho "Backing up configuration files from /etc"
cp -a /etc /var/backups

if [ -d "/var/www" ]; then
    becho "Backing up web files"
    cp -a /var/www /var/backups
fi

if [ -d "/var/lib/mysql" ] && command -v mysqldump >/dev/null 2>&1; then
    becho "Backing up MySQL"
    mysqldump -u root -p --all-databases > /var/backups/mysql.sql
fi

