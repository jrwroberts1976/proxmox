# Proxmox Infrastructure as Code

## Purpose

This document records the working Infrastructure-as-Code model for the Proxmox homelab platform. It is the permanent operational reference for provisioning and configuring Proxmox virtual machines without relying on manual GUI construction.

The current proof is deliberately disposable. No production service has been migrated to Proxmox yet.

## Operating model

The proven control path is:

```text
Git
 |
 +--> OpenTofu on TestServer
 |      +--> Proxmox API
 |      +--> VM CPU, RAM, disk, NIC and lifecycle
 |      +--> cloud-init bootstrap
 |
 +--> SSH
 |
 +--> Ansible on TestServer
        +--> guest operating-system configuration
        +--> packages, services, monitoring and later Docker/application configuration
```

Jenkins may automate this chain later, but Jenkins must not become the only recovery path. The same workflow must remain manually executable from an authorised control node.

## Control node

Current manual IaC control node:

```text
Host: TestServer
OS: Debian 13 trixie
Architecture: arm64
Repository: /home/james/projects/proxmox
OpenTofu: 1.12.6 linux_arm64
Ansible: installed from the host package environment
```

The Proxmox hypervisor itself is intentionally kept free of OpenTofu and Ansible tooling.

## Proxmox provider

The repository pins the BPG Proxmox provider:

```text
source  = bpg/proxmox
version = 0.111.1
```

The provider lock file is committed to Git. Runtime provider downloads under `.terraform/` are not committed.

## Proxmox API identity

A dedicated service account is used rather than the Proxmox root account:

```text
iac@pve
```

The API token is:

```text
iac@pve!opentofu
```

The token uses `privsep=0`, so it inherits the already-restricted permissions of `iac@pve`; the account is not granted Administrator at `/`.

### Custom roles

`HomelabIaCVM`:

```text
VM.Allocate
VM.Audit
VM.Clone
VM.Config.CDROM
VM.Config.CPU
VM.Config.Cloudinit
VM.Config.Disk
VM.Config.HWType
VM.Config.Memory
VM.Config.Network
VM.Config.Options
VM.GuestAgent.Audit
VM.PowerMgmt
```

`HomelabIaCStorage`:

```text
Datastore.AllocateSpace
Datastore.AllocateTemplate
Datastore.Audit
```

`HomelabIaCNode`:

```text
Sys.AccessNetwork
Sys.Audit
Sys.Modify
```

### ACL scope

The account is scoped to the required VM, storage and node paths:

```text
/vms                         HomelabIaCVM
/storage/local               HomelabIaCStorage
/storage/local-lvm           HomelabIaCStorage
/nodes/PROXMOX               HomelabIaCNode
```

Proxmox VE 9 also required bridge-level SDN permission for VM creation on `vmbr0`. The first VM creation attempt failed cleanly with:

```text
Permission check failed (/sdn/zones/localnetwork/vmbr0, SDN.Use)
```

The fix was a narrow `PVESDNUser` ACL on:

```text
/sdn/zones/localnetwork/vmbr0
```

This supplies the required `SDN.Audit` / `SDN.Use` capability without broadening the account to Administrator.

## Credential handling

The API secret is never committed to Git.

Current TestServer credential file:

```text
/home/james/.config/homelab-iac/proxmox.env
```

Permissions:

```text
0600 james:james
```

Only the following variable names are documented:

```text
PROXMOX_VE_ENDPOINT
PROXMOX_VE_API_TOKEN
PROXMOX_VE_INSECURE
```

Do not print or commit the value of `PROXMOX_VE_API_TOKEN`.

OpenTofu operations use the Git-tracked `scripts/tofu-safe` wrapper.

The wrapper sets `umask 077`, loads and exports the existing Proxmox credential environment, and always runs OpenTofu against this repositorys `tofu/` directory.

```bash
scripts/tofu-safe plan
```

The earlier direct-shell workflow required `set -a`; omitting it caused the provider error `Missing Proxmox VE API Endpoint`.

## Repository secret/state exclusions

`.gitignore` excludes runtime state and local secret material, including:

```text
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
*.plan
*.tfvars
*.tfvars.json
.env
.env.*
secrets/
credentials/
*.key
*.pem
*.p12
*.pfx
ansible/.vault_pass
ansible/vault-password*
```

`.terraform.lock.hcl` is deliberately committed.

## OpenTofu state

The disposable proof currently uses local OpenTofu state on TestServer. State is excluded from Git.

This is acceptable for the current lab proof only. Before production migration, the project must define and document:

- the durable state-storage approach;
- backup/recovery of state;
- access control and encryption requirements;
- recovery/import procedure if the control node is lost.

Do not place OpenTofu state in the Git repository.

## Disposable VM proof

Current test VM:

```text
VM ID: 100
Name: debian-iac-test-01
Node: PROXMOX
CPU: 2 cores, x86-64-v2-AES
RAM: 2048 MiB
Disk: 24 GiB on local-lvm
NIC: virtio on vmbr0
IPv4: DHCP
Cloud-init user: james
On boot: false
Tags: iac, lab, disposable
```

Pinned Debian cloud image:

```text
Debian 13 trixie genericcloud amd64
Build: 20260712-2537
File: debian-13-genericcloud-amd64-20260712-2537.qcow2
SHA-512: 7ae53e9dbee282bfc16f289dec483dde3a8598769c38a267948310f7a2a52c662620198603bc52c142627efba379863d16079698a10b34102d55bcedd40e8d32
```

The image is stored by Proxmox as:

```text
local:import/debian-13-genericcloud-amd64-20260712-2537.qcow2
```

### Creation proof

The first successful creation produced:

```text
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
```

Post-create validation proved:

```text
status: stopped
vmid: 100
name: debian-iac-test-01
cpus: 2
memory: 2048 MiB
disk: 24 GiB
onboot: 0
bridge: vmbr0
cloud-init: local-lvm:vm-100-cloudinit
```

A subsequent OpenTofu plan returned:

```text
No changes. Your infrastructure matches the configuration.
```

This is the first zero-drift proof for the VM.

## First boot proof

The VM lifecycle was changed through Git/OpenTofu from:

```text
started = false
```

to:

```text
started = true
```

The saved plan contained only one in-place update and the apply completed with:

```text
Resources: 0 added, 1 changed, 0 destroyed.
```

The VM reached `status=running`.

DHCP assigned:

```text
MAC: BC:24:11:71:7E:65
IPv4: 192.168.2.120
```

The address is a lab DHCP lease, not yet a production IP-allocation policy.

## Guest validation

SSH using the cloud-init-installed public key succeeded as user `james`.

Guest identity was verified as:

```text
Hostname: debian-iac-test-01
OS: Debian GNU/Linux 13 (trixie)
Kernel: 6.12.95+deb13-cloud-amd64
Architecture: x86-64
Virtualisation: KVM
```

Cloud-init reached `done` with no fatal errors. It reported recoverable deprecation warnings for the generated string `user` field; this should be revisited before the workflow is treated as a long-term template.

Time validation proved:

```text
Time zone at first boot: Etc/UTC
System clock synchronized: yes
NTP service: active
```

The baseline Ansible design intentionally changes the guest timezone to `Europe/London`.

Storage/memory validation proved approximately 1.9 GiB usable RAM and a 24 GiB disk with the root partition expanded to approximately 23.9 GiB.

## Ansible control proof

Repository inventory:

```text
ansible/inventories/lab.yml
```

Current inventory group:

```text
proxmox_lab
  debian-iac-test-01
```

The inventory pins:

```text
ansible_host: 192.168.2.120
ansible_user: james
ansible_python_interpreter: /usr/bin/python3.13
```

This removes Ansible interpreter-discovery ambiguity for the Debian 13 proof VM.

The following controls have passed:

```text
Ansible ping: SUCCESS / pong
Privilege escalation: id -u => 0
```

This proves the complete control path:

```text
Git -> OpenTofu -> Proxmox -> cloud-init -> DHCP -> SSH -> Ansible -> sudo/root
```

## Baseline playbook

The first baseline playbook is being developed at:

```text
ansible/playbooks/baseline.yml
```

Intended scope:

- set guest timezone to `Europe/London`;
- install `qemu-guest-agent`;
- install `prometheus-node-exporter`;
- configure the Grafana APT repository;
- install and configure Grafana Alloy;
- forward the systemd journal to central Loki;
- enable/start QEMU guest agent;
- enable/start Prometheus node exporter;
- enable/start Alloy.

The first `--check --diff` run exposed a normal Ansible check-mode limitation: package installation is simulated, so the following service task cannot find a service that has not actually been installed. The service tasks were therefore changed to skip when `ansible_check_mode` is true.

The baseline is now fully proven. After the Alloy configuration was added, the final real Ansible idempotence run completed with `ok=13`, `changed=0`, `unreachable=0` and `failed=0`. Direct guest validation confirmed `qemu-guest-agent` active, the virtio guest-agent channel present, `prometheus-node-exporter` active/enabled, Alloy active, and timezone `Europe/London`. `qemu-guest-agent` is a static systemd service on this Debian image, so Ansible manages `state: started` without requiring `enabled: true`.

The standard Linux VM acceptance baseline now has Prometheus registration under `linux-hosts`, Alloy journal forwarding to central Loki, centralized CrowdSec SSH ingestion, standard Grafana Linux alert coverage, Debian security-only unattended upgrades with automatic reboot disabled, and patch-status monitoring proven end to end.

Patch status is collected hourly by an Ansible-managed systemd service/timer and exported through node-exporter's textfile collector. The metric contract includes pending updates, security updates, reboot-required state, unattended-upgrades enabled/active state, last successful unattended-upgrades timestamp, and collector timestamp. Prometheus receives these metrics under `job="linux-hosts"`.

Live Grafana rules cover the VM generically through the same job label. `Patch collector stale` triggers when collector age exceeds 7200 seconds, while `Security updates available` evaluates `homelab_security_updates_available{job="linux-hosts"} > 0`.

The remaining patch-management work is the controlled patch/reboot workflow itself.

## Resolved warning: SCSI iothread


VM start emitted:

```text
WARN: iothread is only valid with virtio disk or virtio-scsi-single controller, ignoring
```

The VM definition now uses `scsi_hardware = "virtio-scsi-single"` while the primary `scsi0` disk retains `iothread = true`.

The correction was applied in place with `reboot_after_update = false`. The VM boot ID remained unchanged, a fresh OpenTofu plan reported no changes, and the previous warning was no longer emitted.

## OpenTofu state and recovery model

Git is the authority for configuration. OpenTofu runtime state remains local on TestServer and is never committed to Git.

All OpenTofu operations use `scripts/tofu-safe`, which applies `umask 077`; state and saved plan files must remain owner-only.

Before any destructive IaC operation, the current state must have an encrypted, versioned off-host recovery copy. Recovery requires the Git configuration, separately recovered credentials and the correct state snapshot, followed by `scripts/tofu-safe init` and a reviewed `scripts/tofu-safe plan`.

If multiple control nodes or CI runners later need to make concurrent changes, migrate to a locking remote backend rather than sharing local state.

## Manual workflow

### Validate

```bash
scripts/tofu-safe fmt -check
scripts/tofu-safe validate
```

### Plan

```bash
rm -f /tmp/proxmox.tfplan
scripts/tofu-safe plan -out=/tmp/proxmox.tfplan
scripts/tofu-safe show -no-color /tmp/proxmox.tfplan
```

Review the complete plan before apply. Production changes must not rely only on the summary count.

### Apply saved plan

```bash
scripts/tofu-safe apply /tmp/proxmox.tfplan
```

### Ansible syntax check

```bash
ansible-playbook \
  -i ansible/inventories/lab.yml \
  ansible/playbooks/baseline.yml \
  --syntax-check
```

### Ansible check mode

```bash
ansible-playbook \
  -i ansible/inventories/lab.yml \
  ansible/playbooks/baseline.yml \
  --check \
  --diff
```

## Change-control rules

For this project:

1. Git is authoritative before infrastructure mutation.
2. Validate before plan.
3. Inspect plans before apply.
4. Use saved plans for controlled mutations where practical.
5. Keep API secrets and state out of Git.
6. Grant missing API permissions narrowly; do not solve provider errors by granting Administrator reflexively.
7. Keep the source environment running during migration.
8. Do not start production migration until off-host backup/recovery is proven.
9. After configuration changes, run a second plan/playbook to prove idempotence or zero drift.
10. Record material implementation evidence in `docs/build-log.md`.

## Current next actions

1. Select an off-host backup destination and complete backup/restore proof.
2. Destroy VM 100 through OpenTofu and rebuild it from Git as the disposable IaC acceptance test.
