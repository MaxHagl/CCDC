"""
Ubuntu service hardening — disable unwanted services
----------------------------------------------------
What it does:
  • Checks each name in SERVICES; if the unit exists, stop it now and disable at boot.

How to change:
  • Edit the SERVICES list below. (WARNING: On remote hosts, leave 'ssh' enabled to avoid lockout.)

Usage:
  • sudo python3 disable-services.py   # or chmod +x and run directly

Notes:
  • Requires systemd (systemctl). Safe to re-run; missing/already-disabled services are skipped.
"""




#!/usr/bin/env python3
"""
Ubuntu service hardening (disable unwanted services)
----------------------------------------------------
What it does:
  - Checks if each listed service exists on this Ubuntu system.
  - If present, stops it and disables it at boot.
How to change:
  - Edit the `SERVICES` list below.
  - WARNING: Disabling 'ssh' on a remote box can lock you out. Comment it out if needed.
"""

import os
import subprocess
from shutil import which

# List of services to disable on Ubuntu
SERVICES = [
    "vsftpd",
    "proftpd",
    "ssh",            # Ubuntu uses 'ssh' (not 'sshd')
    "postfix",
    "apache2",
    "rpcbind",
    "exim4",
    "avahi-daemon",
    "ModemManager"
]

def run_command(cmd, use_shell=False):
    """Run command and return (returncode, stdout, stderr)."""
    try:
        res = subprocess.run(
            cmd if use_shell else cmd.split(),
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            shell=use_shell,
        )
        return res.returncode, res.stdout.strip(), res.stderr.strip()
    except Exception as e:
        return 1, "", str(e)

def have_systemctl():
    return which("systemctl") is not None

def service_exists(svc):
    """
    On Ubuntu, this reliably detects installed units whether active or not.
    """
    # List all unit files and look for an exact '<svc>.service' match
    cmd = f"systemctl list-unit-files --type=service --all --no-legend --no-pager"
    code, out, _ = run_command(cmd, use_shell=True)
    if code != 0 or not out:
        return False
    target = f"{svc}.service"
    for line in out.splitlines():
        name = line.split()[0].strip()
        if name == target:
            return True
    return False

def main():
    # Prefer running as root; otherwise we’ll prefix with sudo
    use_sudo = os.geteuid() != 0
    sudo = "sudo " if use_sudo else ""

    if not have_systemctl():
        print("❌ systemctl not found. This script requires systemd (Ubuntu default).")
        raise SystemExit(1)

    for svc in SERVICES:
        print(f"\n🔍 Checking status of {svc}...")

        if not service_exists(svc):
            print(f"⚠️  {svc} not found (not installed) or unit file missing.")
            continue

        print(f"✅ {svc} exists. Stopping and disabling it...")

        # Stop (ok if already inactive)
        code, out, err = run_command(f"{sudo}systemctl stop {svc}")
        if code == 0:
            print(f"🛑 Stopped {svc}.")
        else:
            print(f"ℹ️  Could not stop {svc}: {err or out}")

        # Disable (ok if already disabled)
        code, out, err = run_command(f"{sudo}systemctl disable {svc}")
        if code == 0:
            print(f"🚫 Disabled {svc}.")
        else:
            print(f"ℹ️  Could not disable {svc}: {err or out}")

    print("\n✅ All specified services have been processed.")

if __name__ == "__main__":
    main()
