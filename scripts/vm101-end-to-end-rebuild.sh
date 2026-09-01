#!/usr/bin/env bash
set -Eeuo pipefail

REPO="/home/james/projects/proxmox"
TOFU_DIR="$REPO/tofu"
ENV_FILE="/home/james/.config/homelab-iac/proxmox.env"
STATE_BACKUP_DIR="/home/james/tofu-state-backups"

EXPECTED_BRANCH="iac/app-platform-vm101"

RESOURCE="proxmox_virtual_environment_vm.app_platform"

VMID="101"
VM_NAME="app-platform-01"
VM_IP="192.168.2.253"
VM_MAC="BC:24:11:08:A2:33"

TEMPLATE_VMID="9001"
TEMP_VMID="9901"

PVE_HOST="192.168.2.70"
PVE_BACKUP_STORAGE="local"
VM_STORAGE="vm-ssd"

SSH_KEY="/home/james/.ssh/id_ed25519"

STAMP="$(date +%Y%m%d-%H%M%S)"

WORK_ROOT="/tmp/vm101-e2e-$STAMP"

DESTROY_PLAN="$WORK_ROOT/destroy.tfplan"
CREATE_PLAN="$WORK_ROOT/create.tfplan"
FINAL_PLAN="$WORK_ROOT/final.tfplan"
KNOWN_HOSTS="$WORK_ROOT/known_hosts"

LOG="$WORK_ROOT/run.log"

STATE_BACKUP="$STATE_BACKUP_DIR/vm101-pre-e2e-$STAMP.tfstate"

mkdir -p "$WORK_ROOT" "$STATE_BACKUP_DIR"

chmod 700 "$WORK_ROOT" "$STATE_BACKUP_DIR"

touch "$LOG"
chmod 600 "$LOG"

exec > >(tee -a "$LOG") 2>&1


fail() {
    echo
    echo "FAIL: $*"
    echo "log=$LOG"
    exit 1
}


pass() {
    echo "PASS: $*"
}


PVE_SSH=(
    ssh
    -o BatchMode=yes
    -o ConnectTimeout=5
    "root@$PVE_HOST"
)


TEMPLATE_PROBE_CREATED=0

cleanup_template_probe() {
    if [[ "${TEMPLATE_PROBE_CREATED:-0}" -ne 1 ]]; then
        return 0
    fi

    set +e

    "${PVE_SSH[@]}" "
        if qm status '$TEMP_VMID' >/dev/null 2>&1; then
            qm stop '$TEMP_VMID' --skiplock 1 >/dev/null 2>&1 || true

            qm destroy '$TEMP_VMID' \
              --purge 1 \
              --destroy-unreferenced-disks 1 \
              >/dev/null 2>&1 || true
        fi
    " >/dev/null 2>&1

    TEMPLATE_PROBE_CREATED=0

    set -e
}


trap cleanup_template_probe EXIT


require_cmd() {
    command -v "$1" >/dev/null 2>&1 || \
        fail "required command missing: $1"
}


plan_action_gate() {
    local plan="$1"
    local expected_action="$2"
    local json="$WORK_ROOT/$(basename "$plan").json"

    tofu show -json "$plan" > "$json"

    jq -e \
      --arg resource "$RESOURCE" \
      --arg action "$expected_action" '
        [
          .resource_changes[]?
          | select(.change.actions != ["no-op"])
        ] as $changes
        |
        ($changes | length) == 1
        and $changes[0].address == $resource
        and $changes[0].change.actions == [$action]
      ' "$json" >/dev/null || {

        echo "Unexpected plan actions:"

        jq -r '
          .resource_changes[]?
          | select(.change.actions != ["no-op"])
          | "resource=\(.address) actions=\(.change.actions)"
        ' "$json"

        fail \
          "plan action gate failed; expected exactly one $expected_action for $RESOURCE"
    }

    pass \
      "plan action gate: exactly one $expected_action for $RESOURCE"
}


echo "===== VM101 END-TO-END REBUILD ====="

echo "work_root=$WORK_ROOT"
echo "log=$LOG"


echo
echo "===== DESTRUCTIVE APPROVAL GATE ====="

[[ "${VM101_E2E_APPROVED:-}" == "YES" ]] || \
    fail \
      "destructive approval missing; export VM101_E2E_APPROVED=YES before running"

pass "explicit unattended rebuild approval supplied"


echo
echo "===== LOCAL TOOLING GATE ====="

for cmd in \
    git \
    tofu \
    jq \
    ssh \
    ssh-keyscan \
    sha256sum
do
    require_cmd "$cmd"
done

pass "required local commands available"


echo
echo "===== LOCAL FILE GATE ====="

[[ -f "$ENV_FILE" ]] || \
    fail "provider environment file missing: $ENV_FILE"

[[ -f "$SSH_KEY" ]] || \
    fail "SSH private key missing: $SSH_KEY"

[[ -f "${SSH_KEY}.pub" ]] || \
    fail "SSH public key missing: ${SSH_KEY}.pub"

[[ -f "$TOFU_DIR/terraform.tfstate" ]] || \
    fail "OpenTofu state file missing"

pass "required local files present"


echo
echo "===== REPOSITORY SAFETY GATE ====="

cd "$REPO"

CURRENT_BRANCH="$(git branch --show-current)"

echo "branch=$CURRENT_BRANCH"

[[ "$CURRENT_BRANCH" == "$EXPECTED_BRANCH" ]] || \
    fail "expected branch $EXPECTED_BRANCH"

if [[ -n "$(git status --porcelain)" ]]; then

    git status --short

    fail "repository is not clean"

fi

pass "repository clean"


echo
echo "===== NON-INTERACTIVE PROXMOX ACCESS GATE ====="

"${PVE_SSH[@]}" 'true' || \
    fail \
      "root SSH to Proxmox is not non-interactive; configure key-based access before unattended use"

pass "Proxmox root SSH is non-interactive"


echo
echo "===== PROXMOX PREREQUISITE GATE ====="

"${PVE_SSH[@]}" "
    command -v qm >/dev/null &&
    command -v vzdump >/dev/null &&
    command -v zstd >/dev/null &&
    qm status '$VMID' >/dev/null &&
    qm config '$TEMPLATE_VMID' >/dev/null
" || fail "Proxmox VM/template/backup prerequisite failed"

pass "Proxmox prerequisites present"


echo
echo "===== OPENTOFU VALIDATION ====="

set -a

# shellcheck disable=SC1090
. "$ENV_FILE"

set +a

cd "$TOFU_DIR"

tofu init \
  -input=false \
  -lockfile=readonly

tofu fmt -check

tofu validate

pass "OpenTofu init/fmt/validate"


echo
echo "===== CURRENT DRIFT / TEMPLATE MIGRATION GATE ====="

PREFLIGHT_PLAN="$WORK_ROOT/preflight.tfplan"
PREFLIGHT_JSON="$WORK_ROOT/preflight.tfplan.json"

set +e

tofu plan \
  -input=false \
  -detailed-exitcode \
  -out="$PREFLIGHT_PLAN"

PREFLIGHT_RC=$?

set -e

echo "preflight_plan_rc=$PREFLIGHT_RC"

case "$PREFLIGHT_RC" in

    0)
        pass "current infrastructure matches OpenTofu"
        ;;

    2)
        tofu show -json "$PREFLIGHT_PLAN" > "$PREFLIGHT_JSON"

        if jq -e \
          --arg resource "$RESOURCE" \
          --argjson old_template 9000 \
          --argjson new_template "$TEMPLATE_VMID" '
            [
              .resource_changes[]?
              | select(.change.actions != ["no-op"])
            ] as $changes
            |
            ($changes | length) == 1
            and $changes[0].address == $resource
            and $changes[0].change.actions == ["delete", "create"]
            and $changes[0].change.replace_paths == [["clone", 0, "vm_id"]]
            and $changes[0].change.before.clone[0].vm_id == $old_template
            and $changes[0].change.after.clone[0].vm_id == $new_template
          ' "$PREFLIGHT_JSON" >/dev/null
        then
            echo "template_migration=9000->$TEMPLATE_VMID"
            pass "controlled template-only replacement accepted"
        else
            echo "Unexpected pre-flight changes:"

            jq -r '
              .resource_changes[]?
              | select(.change.actions != ["no-op"])
              | "resource=\(.address) actions=\(.change.actions) replace_paths=\(.change.replace_paths)"
            ' "$PREFLIGHT_JSON"

            fail "unexpected infrastructure drift; VM101 will not be destroyed"
        fi
        ;;

    *)
        fail "OpenTofu pre-flight plan failed with rc=$PREFLIGHT_RC"
        ;;

esac


echo
echo "===== TEMPLATE 9001 GUEST-AGENT SMOKE GATE ====="

if "${PVE_SSH[@]}" \
     "qm status '$TEMP_VMID' >/dev/null 2>&1"
then
    fail "temporary VMID $TEMP_VMID already exists; refusing to remove or reuse it"
fi

TEMPLATE_PROBE_CREATED=1


"${PVE_SSH[@]}" "
    qm clone '$TEMPLATE_VMID' '$TEMP_VMID' \
      --name vm101-template-agent-smoke \
      --full 1 \
      --storage '$VM_STORAGE' &&

    qm set '$TEMP_VMID' \
      --agent enabled=1 &&

    qm set '$TEMP_VMID' \
      --net0 virtio,bridge=vmbr0,link_down=1 &&

    qm start '$TEMP_VMID'
" || fail "template smoke clone could not be started"


TEMPLATE_AGENT_READY=0

for attempt in $(seq 1 30); do

    if "${PVE_SSH[@]}" \
         "qm agent '$TEMP_VMID' ping" \
         >/dev/null 2>&1
    then

        echo \
          "attempt=$attempt template_guest_agent=PASS"

        TEMPLATE_AGENT_READY=1

        break
    fi

    echo \
      "attempt=$attempt template_guest_agent=WAIT"

    sleep 5
done


cleanup_template_probe


[[ "$TEMPLATE_AGENT_READY" -eq 1 ]] || \
    fail \
      "template 9001 does not provide a working qemu-guest-agent; VM101 has not been touched"

pass "template 9001 guest agent"


echo
echo "===== STATE BACKUP ====="

cp \
  "$TOFU_DIR/terraform.tfstate" \
  "$STATE_BACKUP"

chmod 600 "$STATE_BACKUP"


STATE_SHA_SOURCE="$(
    sha256sum "$TOFU_DIR/terraform.tfstate" |
    awk '{print $1}'
)"

STATE_SHA_BACKUP="$(
    sha256sum "$STATE_BACKUP" |
    awk '{print $1}'
)"


echo "state_source_sha=$STATE_SHA_SOURCE"
echo "state_backup_sha=$STATE_SHA_BACKUP"


[[ "$STATE_SHA_SOURCE" == "$STATE_SHA_BACKUP" ]] || \
    fail "state backup checksum mismatch"


pass \
  "protected OpenTofu state backup: $STATE_BACKUP"


echo
echo "===== FRESH VM101 BACKUP ====="

BACKUP_RESULT="$(
    "${PVE_SSH[@]}" "
        set -e

        before=\"\$(
            ls -1t \
              /var/lib/vz/dump/vzdump-qemu-${VMID}-*.vma.zst \
              2>/dev/null |
            head -1 ||
            true
        )\"

        vzdump '$VMID' \
          --storage '$PVE_BACKUP_STORAGE' \
          --mode snapshot \
          --compress zstd

        after=\"\$(
            ls -1t \
              /var/lib/vz/dump/vzdump-qemu-${VMID}-*.vma.zst \
              2>/dev/null |
            head -1 ||
            true
        )\"

        [ -n \"\$after\" ]

        [ \"\$after\" != \"\$before\" ]

        zstd -t \"\$after\" >/dev/null

        echo BACKUP_FILE=\"\$after\"
    "
)" || fail "fresh VM101 backup failed"


printf '%s\n' "$BACKUP_RESULT" |
tail -20


BACKUP_FILE="$(
    printf '%s\n' "$BACKUP_RESULT" |
    sed -n 's/^BACKUP_FILE=//p' |
    tail -1
)"


[[ -n "$BACKUP_FILE" ]] || \
    fail "backup archive path not captured"


pass \
  "fresh VM101 backup validated: $BACKUP_FILE"


echo
echo "===== DESTROY PLAN ====="

cd "$TOFU_DIR"

tofu plan \
  -input=false \
  -destroy \
  -out="$DESTROY_PLAN"


plan_action_gate \
  "$DESTROY_PLAN" \
  "delete"


echo
echo "===== APPLY EXACT DESTROY PLAN ====="

tofu apply \
  -input=false \
  "$DESTROY_PLAN"


echo
echo "===== DESTROY STATE GATE ====="

if [[ -n "$(tofu state list)" ]]; then

    tofu state list

    fail \
      "OpenTofu state is not empty after destroy"

fi

pass "OpenTofu state empty after destroy"


echo
echo "===== PROXMOX DESTROY GATE ====="

if "${PVE_SSH[@]}" \
     "qm status '$VMID'" \
     >/dev/null 2>&1
then

    fail "VM101 still exists after destroy"

fi

pass "VM101 absent from Proxmox"


echo
echo "===== CREATE PLAN ====="

tofu plan \
  -input=false \
  -out="$CREATE_PLAN"


plan_action_gate \
  "$CREATE_PLAN" \
  "create"


echo
echo "===== APPLY EXACT CREATE PLAN ====="

tofu apply \
  -input=false \
  "$CREATE_PLAN"


echo
echo "===== OPENTOFU STATE AFTER REBUILD ====="

STATE_LIST="$(tofu state list)"

printf '%s\n' "$STATE_LIST"


[[ "$STATE_LIST" == "$RESOURCE" ]] || \
    fail \
      "unexpected OpenTofu state after rebuild"


pass "OpenTofu state contains exactly VM101"


echo
echo "===== PROXMOX IDENTITY GATE ====="

"${PVE_SSH[@]}" \
  "qm status '$VMID' | grep -q '^status: running$'" || \
    fail \
      "VM101 is not running"


"${PVE_SSH[@]}" \
  "qm config '$VMID' | grep -qi '^net0:.*virtio=${VM_MAC}'" || \
    fail \
      "VM101 MAC identity mismatch"


pass \
  "VM101 running with expected MAC $VM_MAC"


echo
echo "===== GUEST AGENT GATE ====="

AGENT_READY=0

for attempt in $(seq 1 36); do

    if "${PVE_SSH[@]}" \
         "qm agent '$VMID' ping" \
         >/dev/null 2>&1
    then

        echo \
          "attempt=$attempt guest_agent=PASS"

        AGENT_READY=1

        break
    fi

    echo \
      "attempt=$attempt guest_agent=WAIT"

    sleep 5
done


[[ "$AGENT_READY" -eq 1 ]] || \
    fail \
      "VM101 guest agent did not become ready"


echo
echo "===== GUEST IP GATE ====="

"${PVE_SSH[@]}" \
  "qm agent '$VMID' network-get-interfaces" |
grep -F "$VM_IP" \
  >/dev/null || \
    fail \
      "guest agent did not report expected IP $VM_IP"


pass \
  "guest agent reports $VM_IP"


echo
echo "===== DIRECT SSH IDENTITY GATE ====="

: > "$KNOWN_HOSTS"

chmod 600 "$KNOWN_HOSTS"


SSH_READY=0

for attempt in $(seq 1 24); do

    if ssh \
        -i "$SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o UserKnownHostsFile="$KNOWN_HOSTS" \
        -o StrictHostKeyChecking=accept-new \
        "james@$VM_IP" \
        'test "$(hostname)" = "app-platform-01" &&
         grep -q "VERSION_CODENAME=trixie" /etc/os-release' \
        >/dev/null 2>&1
    then

        echo \
          "attempt=$attempt rebuilt_guest_ssh=PASS"

        SSH_READY=1

        break
    fi

    echo \
      "attempt=$attempt rebuilt_guest_ssh=WAIT"

    sleep 5
done


[[ "$SSH_READY" -eq 1 ]] || \
    fail \
      "rebuilt VM failed SSH identity gate"


pass \
  "SSH identity: $VM_NAME / Debian trixie"


echo
echo "===== FINAL OPENTOFU DRIFT GATE ====="

set +e

tofu plan \
  -input=false \
  -detailed-exitcode \
  -out="$FINAL_PLAN"

FINAL_RC=$?

set -e


echo "final_plan_rc=$FINAL_RC"


[[ "$FINAL_RC" -eq 0 ]] || \
    fail \
      "final OpenTofu drift gate failed"


pass \
  "final OpenTofu plan has no changes"


echo
echo "===== END-TO-END REBUILD PASS ====="

echo "vmid=$VMID"
echo "name=$VM_NAME"
echo "ip=$VM_IP"
echo "mac=$VM_MAC"

echo \
  "state_backup=$STATE_BACKUP"

echo \
  "vm_backup=$BACKUP_FILE"

echo \
  "log=$LOG"
