#!/usr/bin/env bash

set -euo pipefail

OUT_DIR="/var/lib/prometheus/node-exporter"
OUT_FILE="${OUT_DIR}/patch_status.prom"
TMP_FILE="${OUT_FILE}.tmp"

mkdir -p "$OUT_DIR"

# Refresh package metadata quietly.
apt-get update -qq

# Count all available package updates.
UPDATES_AVAILABLE=$(
  apt list --upgradable 2>/dev/null |
  tail -n +2 |
  wc -l
)

# Count security-related updates.
SECURITY_UPDATES=$(
  apt list --upgradable 2>/dev/null |
  grep -ciE 'security|Debian-Security' || true
)

# Check whether a reboot is required.
if [ -f /var/run/reboot-required ]; then
  REBOOT_REQUIRED=1
else
  REBOOT_REQUIRED=0
fi

# Check whether unattended-upgrades is enabled.
if systemctl is-enabled unattended-upgrades >/dev/null 2>&1; then
  UNATTENDED_ENABLED=1
else
  UNATTENDED_ENABLED=0
fi

# Check whether unattended-upgrades is active.
if systemctl is-active unattended-upgrades >/dev/null 2>&1; then
  UNATTENDED_ACTIVE=1
else
  UNATTENDED_ACTIVE=0
fi

#
# Determine the most recent successful unattended-upgrades run.
#
# A run is considered successful when:
#   - packages were upgraded
#   - all upgrades were installed
#   - or the check completed and there was nothing to upgrade
#
LAST_SUCCESS=0

if [ -f /var/log/unattended-upgrades/unattended-upgrades.log ]; then

  LAST_LINE=$(
    grep -E \
      'Packages that were upgraded|All upgrades installed|No packages found that can be upgraded unattended' \
      /var/log/unattended-upgrades/unattended-upgrades.log |
    tail -1 || true
  )

  if [ -n "$LAST_LINE" ]; then
    DATE_PART=$(echo "$LAST_LINE" | awk '{print $1" "$2}')
    LAST_SUCCESS=$(date -d "$DATE_PART" +%s 2>/dev/null || echo 0)
  fi

fi

#
# Write Prometheus textfile metrics atomically.
#
{
  echo '# HELP homelab_updates_available Number of available APT package updates.'
  echo '# TYPE homelab_updates_available gauge'
  echo "homelab_updates_available ${UPDATES_AVAILABLE}"

  echo '# HELP homelab_security_updates_available Number of available security updates.'
  echo '# TYPE homelab_security_updates_available gauge'
  echo "homelab_security_updates_available ${SECURITY_UPDATES}"

  echo '# HELP homelab_reboot_required Whether the host requires a reboot.'
  echo '# TYPE homelab_reboot_required gauge'
  echo "homelab_reboot_required ${REBOOT_REQUIRED}"

  echo '# HELP homelab_unattended_upgrades_enabled Whether unattended upgrades are enabled.'
  echo '# TYPE homelab_unattended_upgrades_enabled gauge'
  echo "homelab_unattended_upgrades_enabled ${UNATTENDED_ENABLED}"

  echo '# HELP homelab_unattended_upgrades_active Whether unattended upgrades service is active.'
  echo '# TYPE homelab_unattended_upgrades_active gauge'
  echo "homelab_unattended_upgrades_active ${UNATTENDED_ACTIVE}"

  echo '# HELP homelab_patch_last_success_timestamp_seconds Last successful unattended upgrade check timestamp.'
  echo '# TYPE homelab_patch_last_success_timestamp_seconds gauge'
  echo "homelab_patch_last_success_timestamp_seconds ${LAST_SUCCESS}"

  echo '# HELP homelab_patch_check_timestamp_seconds Last patch status collection time.'
  echo '# TYPE homelab_patch_check_timestamp_seconds gauge'
  echo "homelab_patch_check_timestamp_seconds $(date +%s)"

} > "$TMP_FILE"

mv "$TMP_FILE" "$OUT_FILE"
