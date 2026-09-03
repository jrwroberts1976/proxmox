#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TOFU_DIR="$REPO/tofu"
ENV_FILE="/home/james/.config/homelab-iac/proxmox.env"

EXPECTED_BRANCH="${VM101_EXPECTED_BRANCH:-main}"
RESOURCE="proxmox_virtual_environment_vm.app_platform"
VMID="101"
VM_NAME="zabbix-server-01"
VM_MAC="BC:24:11:08:A2:33"
PVE_HOST="192.168.2.70"
BACKUP_DIR="/home/james/tofu-state-backups"

PROMETHEUS_URL="http://192.168.2.242:9090"
LOKI_URL="http://192.168.2.242:3100"
MONITOR_SETTLE_SECONDS="${VM101_MONITOR_SETTLE_SECONDS:-30}"

STAMP="$(date +%Y%m%d-%H%M%S)"
PLAN="/tmp/vm101-decommission-$STAMP.tfplan"
PLAN_JSON="${PLAN}.json"
STATE_BACKUP="$BACKUP_DIR/vm101-pre-decommission-$STAMP.tfstate"

fail() {
    echo
    echo "FAIL: $*"
    exit 1
}

pass() {
    echo "PASS: $*"
}

PVE_SSH=(
    ssh
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o StrictHostKeyChecking=yes
    "root@$PVE_HOST"
)

cleanup() {
    rm -f "$PLAN" "$PLAN_JSON"
}
trap cleanup EXIT

monitoring_retirement() {
    local cutoff
    local end
    local prom_json
    local prom_samples
    local loki_json
    local loki_entries
    local loki_start
    local loki_end

    echo
    echo "===== MONITORING RETIREMENT ====="

    # Establish the telemetry cutoff after Proxmox has already proven the VM
    # absent. The short delay prevents a same-second boundary from including a
    # sample generated immediately before destruction.
    sleep 2
    cutoff="$(date +%s)"
    echo "telemetry_cutoff_epoch=$cutoff"

    echo "settle_seconds=$MONITOR_SETTLE_SECONDS"
    sleep "$MONITOR_SETTLE_SECONDS"
    end="$(date +%s)"

    echo
    echo "===== PROMETHEUS POST-DECOMMISSION GATE ====="

    prom_json="$(
        curl -fsS -G \
          "$PROMETHEUS_URL/api/v1/query_range" \
          --data-urlencode "query=up{job=\"linux-hosts\",host=\"$VM_NAME\"}" \
          --data-urlencode "start=$cutoff" \
          --data-urlencode "end=$end" \
          --data-urlencode "step=15s"
    )" || fail "Prometheus post-decommission query failed"

    jq -e '.status == "success"' <<<"$prom_json" >/dev/null || \
        fail "Prometheus did not return a successful query response"

    prom_samples="$(
        jq '[.data.result[]?.values[]?] | length' <<<"$prom_json"
    )"

    echo "post_decommission_prometheus_samples=$prom_samples"

    [[ "$prom_samples" -eq 0 ]] || \
        fail "fresh VM101 Prometheus telemetry exists after the decommission cutoff"

    pass "no VM101 Prometheus samples after decommission cutoff"

    echo
    echo "===== LOKI POST-DECOMMISSION GATE ====="

    loki_start="${cutoff}000000000"
    loki_end="${end}000000000"

    loki_json="$(
        curl -fsS -G \
          "$LOKI_URL/loki/api/v1/query_range" \
          --data-urlencode "query={hostname=\"$VM_NAME\"}" \
          --data-urlencode "start=$loki_start" \
          --data-urlencode "end=$loki_end" \
          --data-urlencode "direction=forward" \
          --data-urlencode "limit=100"
    )" || fail "Loki post-decommission query failed"

    jq -e '.status == "success"' <<<"$loki_json" >/dev/null || \
        fail "Loki did not return a successful query response"

    loki_entries="$(
        jq '[.data.result[]?.values[]?] | length' <<<"$loki_json"
    )"

    echo "post_decommission_loki_entries=$loki_entries"

    [[ "$loki_entries" -eq 0 ]] || \
        fail "fresh VM101 Loki log entries exist after the decommission cutoff"

    pass "no VM101 Loki entries after decommission cutoff"
    pass "Grafana has no post-decommission VM101 telemetry to display"
    pass "historical Prometheus/Loki data retained; no delete API invoked"
}

final_banner() {
    echo
    echo "===================================="
    echo "PASS: VM101 DECOMMISSION COMPLETE"
    echo "===================================="
}

for cmd in git tofu jq ssh curl; do
    command -v "$cmd" >/dev/null 2>&1 || fail "required command missing: $cmd"
done

echo "===== VM101 DECOMMISSION ====="

echo
echo "===== APPROVAL GATE ====="
[[ "${VM101_DECOM_APPROVED:-}" == "YES" ]] || \
    fail "approval missing; run with VM101_DECOM_APPROVED=YES"
pass "explicit decommission approval supplied"

echo
echo "===== REPOSITORY GATE ====="
cd "$REPO"
CURRENT_BRANCH="$(git branch --show-current)"
echo "branch=$CURRENT_BRANCH"
[[ "$CURRENT_BRANCH" == "$EXPECTED_BRANCH" ]] || \
    fail "expected branch $EXPECTED_BRANCH"
[[ -z "$(git status --porcelain)" ]] || {
    git status --short
    fail "repository is not clean"
}
pass "repository authority is clean"

echo
echo "===== PROVIDER ENVIRONMENT GATE ====="
[[ -f "$ENV_FILE" ]] || fail "provider environment file missing: $ENV_FILE"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
[[ -n "${PROXMOX_VE_ENDPOINT:-}" ]] || \
    fail "PROXMOX_VE_ENDPOINT is missing after loading provider environment"
pass "Proxmox provider environment loaded"

echo
echo "===== PROXMOX ACCESS GATE ====="
"${PVE_SSH[@]}" true || fail "non-interactive Proxmox SSH failed"
pass "Proxmox SSH access"

echo
echo "===== MONITORING BACKEND GATE ====="
curl -fsS "$PROMETHEUS_URL/-/ready" >/dev/null || \
    fail "Prometheus is not ready at $PROMETHEUS_URL"
curl -fsS "$LOKI_URL/ready" >/dev/null || \
    fail "Loki is not ready at $LOKI_URL"
pass "Prometheus and Loki are reachable before decommission"

echo
echo "===== OWNERSHIP STATE ====="
cd "$TOFU_DIR"
STATE="$(tofu state list)"
if "${PVE_SSH[@]}" "qm status '$VMID'" >/dev/null 2>&1; then
    VM_EXISTS=1
else
    VM_EXISTS=0
fi

echo "state=${STATE:-EMPTY}"
echo "proxmox_vm_exists=$VM_EXISTS"

if [[ -z "$STATE" && "$VM_EXISTS" -eq 0 ]]; then
    pass "VM101 already decommissioned: state empty and VM absent"
    monitoring_retirement
    final_banner
    exit 0
fi

if [[ "$STATE" == "$RESOURCE" && "$VM_EXISTS" -eq 0 ]]; then
    echo
    echo "===== STALE STATE RECOVERY ====="
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    tofu state pull > "$STATE_BACKUP"
    chmod 600 "$STATE_BACKUP"
    echo "state_backup=$STATE_BACKUP"
    tofu state rm "$RESOURCE"
    [[ -z "$(tofu state list)" ]] || fail "state is not empty after stale-state repair"
    pass "stale VM101 ownership removed after proving VM absent"
    monitoring_retirement
    final_banner
    exit 0
fi

[[ "$STATE" == "$RESOURCE" && "$VM_EXISTS" -eq 1 ]] || \
    fail "OpenTofu/Proxmox ownership state is inconsistent"

echo
echo "===== VM101 IDENTITY GATE ====="
CONFIG="$("${PVE_SSH[@]}" "qm config '$VMID'")"
grep -qx "name: $VM_NAME" <<<"$CONFIG" || \
    fail "VMID $VMID name does not match $VM_NAME"
grep -qi "^net0:.*virtio=$VM_MAC" <<<"$CONFIG" || \
    fail "VMID $VMID MAC does not match $VM_MAC"
pass "VM101 identity verified"

echo
echo "===== STATE BACKUP ====="
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
tofu state pull > "$STATE_BACKUP"
chmod 600 "$STATE_BACKUP"
[[ -s "$STATE_BACKUP" ]] || fail "state backup is empty"
echo "state_backup=$STATE_BACKUP"
pass "OpenTofu state backed up"

echo
echo "===== EXACT DESTROY PLAN ====="
tofu plan -input=false -destroy -out="$PLAN"
tofu show -json "$PLAN" > "$PLAN_JSON"

jq -e --arg resource "$RESOURCE" '
  [
    .resource_changes[]?
    | select(.change.actions != ["no-op"])
  ] as $changes
  |
  ($changes | length) == 1
  and $changes[0].address == $resource
  and $changes[0].change.actions == ["delete"]
' "$PLAN_JSON" >/dev/null || {
    echo "Unexpected plan actions:"
    jq -r '.resource_changes[]? | select(.change.actions != ["no-op"]) | "resource=\(.address) actions=\(.change.actions)"' "$PLAN_JSON"
    fail "expected exactly one delete for $RESOURCE"
}
pass "exactly one VM101 delete planned"

echo
echo "===== APPLY EXACT DESTROY PLAN ====="
tofu apply -input=false "$PLAN"

echo
echo "===== FINAL OWNERSHIP GATE ====="
[[ -z "$(tofu state list)" ]] || fail "OpenTofu state is not empty after decommission"
if "${PVE_SSH[@]}" "qm status '$VMID'" >/dev/null 2>&1; then
    fail "VM101 still exists in Proxmox"
fi

pass "OpenTofu state empty"
pass "VM101 absent from Proxmox"

monitoring_retirement
final_banner
