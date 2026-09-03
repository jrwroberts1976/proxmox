#!/usr/bin/env bash
set -Eeuo pipefail

REPO="/home/james/projects/proxmox"
TOFU_DIR="$REPO/tofu"
BUILD_SCRIPT="$REPO/scripts/vm101-end-to-end-rebuild.sh"

PVE_HOST="192.168.2.70"
VMID="101"
HOSTNAME="zabbix-server-01"
TEMPLATE_VMID="9001"

fail() {
    echo
    echo "FAIL: $*"
    exit 1
}

pass() {
    echo "PASS: $*"
}

echo "===== ONE-BUTTON ZABBIX SERVER BUILD ====="
echo "vmid=$VMID"
echo "hostname=$HOSTNAME"

cd "$REPO"

echo
echo "===== SAFETY GATE ====="

[[ "$(git branch --show-current)" == "main" ]] || \
    fail "repository must be on main"

[[ -z "$(git status --porcelain)" ]] || \
    fail "repository must be clean"

[[ -x "$BUILD_SCRIPT" ]] || \
    fail "build script missing or not executable"

pass "repository safety"

echo
echo "===== CLEAN START GATE ====="

cd "$TOFU_DIR"

STATE="$(tofu state list)"

[[ -z "$STATE" ]] || {
    echo "$STATE"
    fail "OpenTofu state is not empty"
}

pass "OpenTofu state empty"

if ssh -o BatchMode=yes root@"$PVE_HOST" \
     "qm status '$VMID' >/dev/null 2>&1"
then
    fail "VM$VMID already exists; refusing to overwrite it"
fi

pass "VM$VMID absent"

ssh -o BatchMode=yes root@"$PVE_HOST" \
  "qm config '$TEMPLATE_VMID' >/dev/null" || \
    fail "template VM$TEMPLATE_VMID unavailable"

pass "template VM$TEMPLATE_VMID available"

echo
echo "===== START FULL BUILD ====="

cd "$REPO"

export VM101_E2E_APPROVED=YES

exec "$BUILD_SCRIPT" "$HOSTNAME"
