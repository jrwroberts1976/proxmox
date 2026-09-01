# Linux VM IaC Deployment Runbook

## 1. Purpose

This runbook defines the controlled procedure for deploying a new Debian Linux VM on the Proxmox platform using Infrastructure as Code.

The normal deployment chain is:

```text
1. OpenTofu VM creation
        |
2. cloud-init / guest acceptance
        |
3. Linux security hardening
        |
4. Alloy observability acceptance
        |
5. PostgreSQL
        |
6. TimescaleDB
        |
7. Nginx
```

Manual VM creation or persistent GUI-only corrections are not the normal path. Git/OpenTofu/Ansible are the source of truth.

Security and observability are mandatory build gates, not optional follow-up work.

---

## 2. Current platform baseline

Verified current Proxmox platform:

```text
Proxmox host:      PROXMOX
Management IP:     192.168.2.70
Bridge:            vmbr0
Preferred storage: vm-ssd
Storage type:      LVM-thin
Backing disk:      KINGSTON SA400S37480G
```

Current Debian template:

```text
VMID: 9000
Name: debian-13-cloud-template
OS: Debian 13 genericcloud
```

Current application-platform VM:

```text
VMID:       101
Hostname:   app-platform-01
IP:         192.168.2.253
MAC:        BC:24:11:08:A2:33
vCPU:       2
RAM:        4096 MB
Disk:       64 GB
Storage:    vm-ssd
NIC:        VirtIO
Guest agent: enabled/healthy
```

VM101 currently uses DHCP. Reserve the address by MAC before treating it as a long-lived application/database endpoint rather than silently adding an unmanaged static address.

---

## 3. Design rules

1. Git is the source of truth.
2. Use OpenTofu for VM lifecycle.
3. Use cloud-init for first-boot identity/access only.
4. Use Ansible for OS, security, observability and applications.
5. Store guest disks on `vm-ssd` unless a documented exception exists.
6. Never commit API tokens, private keys, passwords, state secrets or Vault passwords.
7. Review a saved plan before apply.
8. Do not make corrective persistent GUI changes after an IaC failure; fix code and re-plan.
9. Security hardening must pass before observability/applications.
10. Observability must fully pass before PostgreSQL/TimescaleDB/Nginx.
11. A second Ansible run should prove idempotence for each managed layer.
12. Destroy operations require explicit confirmation that the VM is disposable and contains no required data.

---

## 4. Required values

Record before creation:

```text
VM_NAME=
VM_ID=
VM_IP=
VM_PREFIX=24
VM_GATEWAY=192.168.2.1
VM_DNS=
VM_CPU=2
VM_MEMORY_MB=4096
VM_DISK_GB=64
VM_STORAGE=vm-ssd
VM_BRIDGE=vmbr0
TEMPLATE_VM_ID=9000
PROXMOX_NODE=PROXMOX
SSH_PUBLIC_KEY_FILE=
```

Do not guess a VM ID or address. Confirm both are unused/approved before apply.

---

# Stage 0 - Proxmox preflight

On `PROXMOX`:

```bash
pvesm status
pvesh get /nodes/PROXMOX/status
qm list
free -h
lsblk
```

Required:

- `vm-ssd` active;
- sufficient RAM/storage;
- chosen VMID unused;
- source template present;
- no storage errors.

Template check:

```bash
qm config 9000
```

Future template builds should include `qemu-guest-agent` before conversion so new guests do not require a post-clone correction.

---

# Stage 1 - OpenTofu source

Current repository branch for VM101 work:

```text
iac/app-platform-vm101
```

Use the repository's existing OpenTofu structure and `bpg/proxmox` provider implementation. Credentials must come from the approved environment/secret mechanism, not `.tf` source.

Required declared properties include:

```text
name
vm_id
node_name
clone/template source
cpu
memory
disk/storage
bridge
cloud-init network
DNS
cloud-init user
SSH public key
QEMU guest agent
startup state
```

Expose at least:

```text
vm_id
vm_name
ipv4_address
```

for Ansible hand-off.

---

# Stage 2 - Validate and plan

From the environment directory:

```bash
tofu fmt -recursive
tofu init
tofu validate
tofu plan -out=tfplan
```

Review:

- exactly the intended VM;
- correct template/VMID;
- `vm-ssd` storage;
- `vmbr0` network;
- intended CPU/RAM/disk;
- intended network/bootstrap values;
- no unrelated destroy/replace;
- no secret leakage.

Stop if an unplanned destroy/replacement appears.

---

# Stage 3 - Apply

```bash
tofu apply tfplan
```

On Proxmox:

```bash
qm list
qm status <VM_ID>
qm config <VM_ID>
pvesm status
```

Confirm the disk is on `vm-ssd` and the VM is running as intended.

---

# Stage 4 - Guest acceptance

From the administration host:

```bash
ping -c 3 <VM_IP>
ssh <ADMIN_USER>@<VM_IP>
```

Inside the VM:

```bash
hostnamectl
ip -br addr
ip route
cat /etc/os-release
uname -a
timedatectl
systemctl --failed
cloud-init status --long
```

Required:

- Debian 13 identity correct;
- expected hostname/network;
- default route correct;
- DNS works;
- cloud-init complete;
- no unexpected failed services;
- SSH key access works.

Guest agent:

```bash
systemctl status qemu-guest-agent --no-pager
```

From Proxmox:

```bash
qm agent <VM_ID> ping
```

---

# Stage 5 - Ansible hand-off

Do not add a guest to application groups until Stage 4 passes.

The VM then enters the managed Ansible layers:

```text
security hardening
Alloy observability
PostgreSQL
TimescaleDB
Nginx
```

Validate controller connectivity before every new layer:

```bash
ansible <GROUP> -m ansible.builtin.ping --limit <VM_NAME>
```

Do not disable SSH host-key checking to bypass an identity problem.

---

# Stage 6 - Security gate

Use:

```text
runbooks/linux-vm-security-hardening.md
```

Current validated controls include:

- removing OpenSSH UMAC-64 MAC algorithms;
- persistently blocking IPv4 ICMP timestamp requests;
- fresh SSH validation;
- idempotence;
- external scan verification.

Do not proceed directly to PostgreSQL when security passes. The next mandatory stage is observability.

---

# Stage 7 - Observability gate

Use:

```text
runbooks/linux-vm-observability-bootstrap.md
```

Current new-VM standard:

```text
Grafana Alloy native service
 -> Linux node metrics
 -> ids-01 Prometheus 192.168.2.242:9090
 -> systemd journal
 -> ids-01 Loki 192.168.2.242:3100
 -> Grafana on ids-01
```

The authoritative Ansible implementation is:

```text
ansible/roles/alloy/
ansible/playbooks/alloy.yml
```

Observability is complete only after:

- Alloy syntax/preflight passes;
- deployment succeeds;
- second run is idempotent;
- readiness/health pass;
- journal access as unprivileged `alloy` passes;
- `node_uname_info` and core metrics are visible centrally;
- unique journal marker is visible in Loki;
- duplicate metrics path check passes;
- Grafana source queries work;
- required alerts are validated;
- reboot persistence passes.

Do **not** treat "monitoring scheduled" as sufficient. This gate must be complete before database/web application commissioning.

---

# Stage 8 - Application sequence

Only after security and observability gates close:

```text
runbooks/postgresql-install.md
runbooks/timescaledb-install.md
runbooks/nginx-install.md
```

Each application runbook must re-check that the accepted Alloy/host telemetry has not regressed after package/service changes.

---

# Stage 9 - Drift/idempotence

After successful VM creation and baseline commissioning:

```bash
tofu plan
```

Expected: no unintended VM drift.

Ansible-managed layers should also be rerun for idempotence before closure.

Persistent GUI changes create drift and must be brought back into code.

---

# Stage 10 - Rollback/destroy

Only for an explicitly disposable VM with no required data:

```bash
tofu plan -destroy
tofu destroy
```

Then:

```bash
qm list
pvesm status
```

Confirm no orphaned disk remains.

Never destroy a database VM with retained data without a proven backup/restore path.

---

## Acceptance checklist

The Linux VM platform build is ready for application installation only when:

- [ ] VM is declared in OpenTofu.
- [ ] OpenTofu validation/plan passes.
- [ ] VM uses intended storage/network.
- [ ] cloud-init completes.
- [ ] SSH key access works.
- [ ] guest agent works where enabled.
- [ ] no unexpected failed units exist.
- [ ] security-hardening playbook passes.
- [ ] fresh SSH works after hardening.
- [ ] hardening idempotence passes.
- [ ] Alloy deployment passes.
- [ ] Alloy idempotence passes.
- [ ] metrics E2E passes.
- [ ] logs E2E passes.
- [ ] duplicate metrics check passes.
- [ ] Grafana source data passes.
- [ ] alert coverage passes.
- [ ] reboot persistence passes.
- [ ] post-apply OpenTofu plan is clean.

Only then proceed to PostgreSQL.

---

## VM101 status record

As of 2026-09-01:

```text
VM101 IaC:                    PASS
Guest commissioning:         PASS
Security hardening:           PASS
Security idempotence:         PASS
Alloy deployment:             PASS
Alloy version:                v1.19.2
Alloy idempotence:            PASS (changed=0)
Metrics E2E:                  PASS
Logs E2E:                     PASS
Duplicate metric path:        PASS
Grafana source data:          PASS
Alert coverage:               OUTSTANDING
Reboot observability proof:   OUTSTANDING
```

PostgreSQL remains gated until the outstanding observability items are closed.
