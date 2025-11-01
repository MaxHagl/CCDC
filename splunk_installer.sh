#!/bin/bash
# ---------------------------------------------------------
# Splunk Universal Forwarder Setup Script for Ubuntu (ARM64)
# Version: 10.0.1
# Author: Maximilian Hagl

#Usage:

#chmod +x setup-splunk-forwarder.sh
#sudo ./setup-splunk-forwarder.sh
#

# ---------------------------------------------------------

# --- CONFIGURATION ---
SPLUNK_URL="https://download.splunk.com/products/universalforwarder/releases/10.0.1/linux/splunkforwarder-10.0.1-c486717c322b-linux-arm64.tgz"
SPLUNK_TGZ="splunkforwarder-10.0.1-c486717c322b-linux-arm64.tgz"
INSTALL_DIR="/opt"
SPLUNK_HOME="$INSTALL_DIR/splunkforwarder"
SPLUNK_BIN="$SPLUNK_HOME/bin/splunk"
RECEIVER_IP="172.20.241.20"
RECEIVER_PORT="9997"
HOSTNAME=$(hostname)

# --- FUNCTIONS ---
log() { echo -e "\033[1;32m[+] $1\033[0m"; }
err() { echo -e "\033[1;31m[!] $1\033[0m"; }

# --- PREREQS ---
log "Updating system and installing wget/tar..."
sudo apt update -y && sudo apt install -y wget tar

# --- DOWNLOAD ---
log "Downloading Splunk Universal Forwarder (v10.0.1, ARM64)..."
wget -O "$SPLUNK_TGZ" "$SPLUNK_URL" || { err "Download failed"; exit 1; }

# --- EXTRACT ---
log "Extracting Splunk to $INSTALL_DIR..."
sudo tar -xvzf "$SPLUNK_TGZ" -C "$INSTALL_DIR"

# --- CREATE SPLUNK USER ---
if ! id splunk &>/dev/null; then
  log "Creating dedicated 'splunk' service account..."
  sudo useradd -r -m -d $SPLUNK_HOME -s /bin/bash splunk
fi

# --- SET PERMISSIONS ---
log "Setting secure permissions..."
sudo chown -R splunk:splunk $SPLUNK_HOME
sudo chmod -R 750 $SPLUNK_HOME

# --- START SPLUNK AS SPLUNK USER ---
log "Starting Splunk for the first time and accepting license..."
sudo -u splunk $SPLUNK_BIN start --accept-license --answer-yes --no-prompt

# --- ENABLE AT BOOT ---
log "Enabling Splunk to start at boot..."
sudo $SPLUNK_BIN enable boot-start -user splunk

# --- CONFIGURE FORWARDING ---
log "Configuring forwarding to $RECEIVER_IP:$RECEIVER_PORT..."
sudo -u splunk $SPLUNK_BIN add forward-server $RECEIVER_IP:$RECEIVER_PORT

# --- ADD MONITORED LOGS ---
log "Adding log monitors..."
for LOGFILE in /var/log/auth.log /var/log/syslog /var/log/messages /var/log/daemon.log; do
  if [ -f "$LOGFILE" ]; then
    sudo -u splunk $SPLUNK_BIN add monitor "$LOGFILE" -index main -host "$HOSTNAME"
  fi
done

# --- VERIFY CONFIGURATION ---
log "Verifying forwarding configuration..."
sudo -u splunk $SPLUNK_BIN list forward-server

# --- RESTART SPLUNK ---
log "Restarting Splunk to apply settings..."
sudo -u splunk $SPLUNK_BIN restart

log "✅ Splunk Universal Forwarder installation and configuration complete!"
log "Logs are now being forwarded to $RECEIVER_IP:$RECEIVER_PORT"
