# Linux VM IaC Deployment Runbook

## 1. Purpose

This runbook defines the controlled procedure for deploying a new Debian Linux VM on the Proxmox platform using Infrastructure as Code.

The VM must be created through OpenTofu/Terraform, bootstrapped with cloud-init, handed over to Ansible for operating-system configuration, and pass the validated Linux security-hardening gate before application services are installed. Manual VM creation in the Proxmox GUI is not the normal deployment path.

The application-platform build sequence is:

```text
1. Linux VM IaC deployment
        |
2. Guest commissioning / cloud-init acceptance
        |
3. Linux security hardening
        |
4. Observability / baseline acceptance
        |
5. PostgreSQL
        |
6. TimescaleDB
        |
7. Nginx
```

Security hardening is part of the build, not an optional post-install activity.

---

## 2. Current platform baseline

Target hypervisor:

```text
Proxmox host: PROXMOX
Management IP: 192.168.2.70
Bridge: vmbr0
Preferred guest storage: vm-ssd
Storage type: LVM-thin
Backing disk: KINGSTON SA400S37480G
```

Initial disposable/test VM sizing for the current 8 GB host:

```text
vCPU:        2
RAM:         4096 MB
Disk:        64 GB
Storage:     vm-ssd
OS:          Debian 13
Firmware:    UEFI or the established template default
NIC:         VirtIO
Disk bus:    SCSI/VirtIO SCSI
Guest agent: enabled
```

This sizing is for build and validation. Revisit RAM before treating PostgreSQL/TimescaleDB as a permanent production workload.

---

## 3. Design rules

1. Git is the source of truth.
2. Use OpenTofu/Terraform for VM lifecycle.
3. Use cloud-init only for first-boot bootstrap and access.
4. Use Ansible for ongoing OS, security and application configuration.
5. Store VM disks on `vm-ssd` unless a documented exception exists.
6. Do not commit Proxmox API tokens, SSH private keys, passwords, Terraform/OpenTofu state secrets, or Ansible Vault passwords.
7. Plan must be reviewed before apply.
8. The first deployment must be disposable.
9. The validated Linux security-hardening gate must pass before PostgreSQL, TimescaleDB or Nginx installation.
10. Observability must be commissioned before the VM is accepted for production use.
11. Destruction must only be performed against a VM explicitly confirmed as disposable.

---

## 4. Required values

Record these before creating code:

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
TEMPLATE_VM_ID=
PROXMOX_NODE=
SSH_PUBLIC_KEY_FILE=
```

Do not guess a VM ID or IP address. Confirm both are unused before apply.

---

# Stage 0 - Pre-flight gates

## 5. Verify Proxmox capacity

On `PROXMOX`:

```bash
pvesm status
pvesh get /nodes/PROXMOX/status
qm list
free -h
lsblk
```

Required:

- `vm-ssd` is `active`;
- sufficient free RAM exists for the temporary VM;
- chosen VM ID is unused;
- no storage error is present.

Stop if the host is under memory pressure or `vm-ssd` is unavailable.

## 6. Verify the source template

The Debian cloud-init template must already exist and be known-good.

```bash
qm list
qm config <TEMPLATE_VM_ID>
```

Expected template properties:

- Debian 13;
- cloud-init capable;
- QEMU guest agent installed/enabled where practical;
- no embedded passwords or private credentials;
- boot succeeds on `vmbr0`.

If the template is not proven, create and validate the template as a separate controlled task before continuing.

---

# Stage 1 - Repository structure

## 7. IaC layout

Use the repository structure:

```text
tofu/
├── providers.tf
├── variables.tf
├── outputs.tf
├── modules/
│   └── linux-vm/
└── environments/
    └── homelab/
        ├── main.tf
        ├── variables.tf
        └── terraform.tfvars.example
```

Real secret-bearing `.tfvars` files and local state must not be committed.

## 8. Provider model

Use a maintained Proxmox provider compatible with both OpenTofu and the installed Proxmox VE release. The intended provider is `bpg/proxmox` unless validation identifies a reason to change.

Pin the provider version after it has been tested against the homelab. Do not use an unconstrained provider version in production.

Provider credentials must come from an approved environment/secret mechanism, not source files.

---

# Stage 2 - VM definition

## 9. Required VM properties

The reusable module must declare, rather than manually configure:

```text
name
vm_id
node_name
clone/template source
cpu cores
memory
boot disk
storage datastore
network bridge
IPv4 configuration
DNS servers
cloud-init user
SSH public keys
QEMU guest agent
startup state
```

For the first platform VM use:

```text
storage = vm-ssd
bridge  = vmbr0
cores   = 2
memory  = 4096 MB
disk    = 64 GB
```

Do not place passwords in cloud-init metadata when SSH-key authentication can be used.

## 10. Outputs

At minimum expose:

```text
vm_id
vm_name
ipv4_address
```

These values become the hand-off into the Ansible inventory.

---

# Stage 3 - Validate and plan

## 11. Initialise

From the IaC directory:

```bash
cd tofu/environments/homelab

tofu fmt -recursive
tofu init
tofu validate
```

All commands must complete successfully.

## 12. Review plan

```bash
tofu plan -out=tfplan
```

Review the plan for:

- exactly the intended VM;
- correct VM ID;
- correct source template;
- `vm-ssd` storage;
- `vmbr0` network;
- intended IP/gateway/DNS;
- 2 vCPU / 4096 MB RAM / 64 GB disk for the initial build;
- no unrelated resources scheduled for deletion or replacement;
- no secrets displayed unexpectedly.

If the plan contains an unplanned destroy or replacement, stop.

---

# Stage 4 - Apply

## 13. Create the VM

```bash
tofu apply tfplan
```

Do not make corrective GUI changes if apply fails. Diagnose and correct the IaC source, then generate a new plan.

## 14. Verify from Proxmox

On `PROXMOX`:

```bash
qm list
qm status <VM_ID>
qm config <VM_ID>
pvesm status
```

Confirm the VM disk is backed by `vm-ssd`.

---

# Stage 5 - Guest acceptance

## 15. Network and identity

From an administration host:

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

- Debian 13 identity is correct;
- intended hostname and IP are present;
- default route points to `192.168.2.1`;
- DNS resolution works;
- cloud-init reports completion;
- no unexpected failed services exist;
- SSH key authentication works.

## 16. Guest agent

If QEMU guest agent is part of the template:

```bash
systemctl status qemu-guest-agent --no-pager
```

From Proxmox:

```bash
qm agent <VM_ID> ping
```

---

# Stage 6 - Ansible hand-off

## 17. Add inventory only after IaC acceptance

Add the host to the appropriate Ansible inventory only after the VM passes Stage 5.

For security hardening the host must be present in the `linux_security_hardening` group. For VM101, use its approved address rather than guessing one.

Example:

```yaml
all:
  children:
    linux_security_hardening:
      hosts:
        app-platform-01:
          ansible_host: <VM_IP>
          ansible_user: james
          ansible_become: true
```

Validate:

```bash
cd ansible/linux-security-hardening
ansible-playbook -i inventory.yml playbook.yml --syntax-check
ansible -i inventory.yml linux_security_hardening -m ping --limit <VM_NAME>
```

Do not continue if Ansible cannot reach the VM.

---

# Stage 7 - Mandatory Linux security hardening

## 18. Apply the validated hardening role

Use:

```text
runbooks/linux-vm-security-hardening.md
```

The authoritative Ansible implementation is:

```text
ansible/linux-security-hardening/
```

The currently validated controls are intentionally narrow:

1. Remove `umac-64-etm@openssh.com` and `umac-64@openssh.com` from the effective OpenSSH MAC policy.
2. Persistently block IPv4 ICMP timestamp requests through `homelab-icmp-timestamp-block.service`.

The role does not enable a global firewall and does not disable TCP timestamps.

For the first deployment, run only against the new VM:

```bash
cd ansible/linux-security-hardening
ansible-playbook \
  -i inventory.yml \
  playbook.yml \
  --limit <VM_NAME> \
  --ask-become-pass
```

After the run:

- establish a fresh SSH session;
- verify both UMAC-64 algorithms are absent;
- verify the ICMP timestamp DROP rule exists;
- verify normal ping still works;
- verify ICMP timestamp probes receive no timestamp reply;
- run the playbook a second time and prove idempotence;
- re-run the matching Greenbone checks.

Do not proceed to PostgreSQL until this gate passes.

---

# Stage 8 - Observability gate

## 19. Commission monitoring before production acceptance

Use:

```text
runbooks/linux-vm-observability-bootstrap.md
```

The VM is not production-ready until:

- Linux metrics are visible centrally;
- logs are visible centrally;
- host-down monitoring is active;
- disk and memory usage can be observed.

---

# Stage 9 - Idempotence and drift

## 20. Re-plan

After successful creation and baseline configuration:

```bash
tofu plan
```

Expected result: no unintended changes.

Do not make persistent VM configuration changes in the Proxmox GUI. If a change is required, update Git and re-apply.

---

# Stage 10 - Rollback

## 21. Disposable VM rollback

Only if the VM is explicitly disposable and contains no required data:

```bash
tofu plan -destroy
```

Review the destruction plan carefully, then:

```bash
tofu destroy
```

After destruction:

```bash
qm list
pvesm status
```

Confirm no orphaned disk remains for the destroyed test VM.

Never destroy a database VM with retained data without first proving the backup/recovery path.

---

## 22. Acceptance criteria

The Linux VM build is complete when:

- [ ] VM exists only because it is declared in IaC.
- [ ] OpenTofu validate passes.
- [ ] Apply contains no unrelated changes.
- [ ] VM uses `vm-ssd`.
- [ ] Network identity is correct.
- [ ] SSH key access works.
- [ ] cloud-init completed successfully.
- [ ] QEMU guest agent works where enabled.
- [ ] `systemctl --failed` is clean or exceptions are documented.
- [ ] Ansible can reach the VM.
- [ ] Validated Linux security-hardening playbook completes successfully.
- [ ] Fresh SSH access succeeds after hardening.
- [ ] Weak UMAC-64 SSH MAC algorithms are absent.
- [ ] ICMP timestamp requests are blocked while normal ping remains functional.
- [ ] Hardening playbook is idempotent on a second run.
- [ ] Matching Greenbone findings are cleared or formally documented.
- [ ] Monitoring/logging commissioning is scheduled or complete.
- [ ] A post-apply OpenTofu plan is clean.

Only then proceed to PostgreSQL installation.
