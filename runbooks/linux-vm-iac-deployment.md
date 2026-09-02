# Linux VM IaC Deployment Runbook

## Purpose

This runbook defines the controlled deployment of Debian 13 guests on Proxmox using OpenTofu, cloud-init and Ansible.

The normal chain is:

```text
OpenTofu
  -> cloud-init
  -> QEMU Guest Agent
  -> verified SSH trust
  -> Linux security hardening
  -> unattended-upgrades
  -> Alloy
  -> application roles
  -> idempotence
  -> OpenTofu zero drift
```

Git/OpenTofu/Ansible are the source of truth. Manual Proxmox GUI corrections are not an accepted persistent build step.

---

## Current platform baseline

```text
Proxmox node:       PROXMOX
Management IP:      192.168.2.70
Bridge:             vmbr0
VM storage:         vm-ssd
Template VMID:      9001
Template:           debian-13-cloud-template-qga
Template OS:        Debian 13
QEMU guest agent:   included/validated
```

Current VM101 build target:

```text
VMID:       101
Hostname:   zabbix-server-01
IP:         192.168.2.253
MAC:        BC:24:11:08:A2:33
vCPU:       2
RAM:        4096 MB
Disk:       64 GB
Storage:    vm-ssd
NIC:        VirtIO
```

VM101 currently receives its address by DHCP using the stable MAC identity.

---

## Design rules

1. Git is the source of truth.
2. OpenTofu owns VM lifecycle and persistent VM properties.
3. cloud-init owns first-boot user/key/network bootstrap.
4. Ansible owns operating-system and application configuration.
5. Use template 9001 for Debian 13 guest-agent-enabled builds.
6. Use `vm-ssd` unless a documented exception exists.
7. Never commit provider tokens, private SSH keys, plaintext passwords or Vault password files.
8. Review saved OpenTofu plans before apply.
9. Fail closed on ownership inconsistencies or unrelated drift.
10. Never disable SSH host-key checking to bypass a rebuild identity change.
11. Security hardening precedes application deployment.
12. A complete second Ansible pass must prove idempotence.
13. Final OpenTofu plan must show zero drift.

---

## Build modes

Automation must explicitly distinguish clean creation from a managed rebuild.

### Clean create

```text
OpenTofu state empty
AND target VM absent from Proxmox
```

Required behavior:

```text
skip existing-VM backup/destroy
require exactly one OpenTofu create
```

### Managed rebuild

```text
OpenTofu state contains exactly the expected VM resource
AND target VM exists in Proxmox
```

Required behavior:

```text
state backup
VM backup where required
controlled destroy plan
exact destroy
exact create
```

### Inconsistent state

Examples:

```text
OpenTofu state empty but VM exists
OpenTofu state populated but VM absent
unexpected resource in state
```

Required behavior: **FAIL**. Do not adopt, destroy or overwrite automatically.

---

## OpenTofu preflight

Load provider credentials from the protected external environment file:

```text
/home/james/.config/homelab-iac/proxmox.env
```

Then:

```bash
cd /home/james/projects/proxmox/tofu

tofu init -input=false -lockfile=readonly
tofu fmt -check
tofu validate
tofu plan -input=false -detailed-exitcode
```

Plan gates must prove that only the intended resource action is present.

For clean creation:

```text
exactly one create
zero unrelated changes
```

For a controlled hostname transition, only the intended resource name field may change. Any additional property change must fail the preflight gate.

---

## Template gate

Before touching the target VM, validate template 9001.

Required template checks:

```text
template exists
full clone can be created on vm-ssd
QEMU Guest Agent responds inside smoke clone
smoke clone is removed after the test
```

Do not continue if the template cannot provide a working guest agent.

---

## Guest-agent acceptance

After creation:

```bash
qm status <VMID>
qm agent <VMID> ping
```

Use QGA to obtain guest identity and network information rather than guessing when the guest is ready.

Required:

```text
VM running
expected MAC
QGA responds
guest reports expected IP
hostname matches intended identity
Debian VERSION_CODENAME=trixie
```

---

## Verified SSH trust

A rebuilt guest has a new SSH host key. Stale controller `known_hosts` data must never be silently trusted or worked around by disabling checking.

Accepted sequence:

```text
1. Through trusted Proxmox/QGA, run:
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub

2. Obtain the ED25519 network key with ssh-keyscan.

3. Convert network results to unique SHA256 fingerprints.

4. Require exactly one unique fingerprint.

5. Require exact equality with the QGA fingerprint.

6. Write the verified network key to a temporary known_hosts file.

7. Use StrictHostKeyChecking=yes.
```

`ssh-keyscan` can emit duplicate lines for the same key. Count unique fingerprints, not raw lines.

Controller SSH must also use:

```text
-o IdentitiesOnly=yes
```

This prevents an SSH agent offering unrelated identities before the intended private key.

Recommended SSH options:

```text
-i /home/james/.ssh/id_ed25519
-o IdentitiesOnly=yes
-o BatchMode=yes
-o UserKnownHostsFile=<verified-temporary-file>
-o StrictHostKeyChecking=yes
```

The same options must be propagated to Ansible through `ANSIBLE_SSH_COMMON_ARGS`.

---

## cloud-init user acceptance

The Debian cloud-init user is `james`.

Required checks:

```text
account exists
sudo membership present
/home/james mode 0700
/home/james/.ssh mode 0700
authorized_keys mode 0600
controller public-key fingerprint equals authorized_keys fingerprint
sshd PubkeyAuthentication yes
```

Password authentication is disabled. A password-state value of `L` is not by itself evidence that public-key authentication is broken; direct key authentication has been proved with the correct controller identity.

---

## Ansible hand-off

Permanent inventory:

```text
ansible/inventories/vm101/hosts.yml
```

Vault password file:

```text
/home/james/.config/homelab-iac/ansible-vault-password
```

Required mode:

```text
0600
```

Example controller environment:

```bash
export ANSIBLE_HOST_KEY_CHECKING=True
export ANSIBLE_SSH_COMMON_ARGS="-o IdentitiesOnly=yes -o UserKnownHostsFile=<verified-known-hosts> -o StrictHostKeyChecking=yes"
export ANSIBLE_ROLES_PATH="/home/james/projects/proxmox/ansible/roles:/home/james/projects/proxmox/ansible/linux-security-hardening/roles"
```

Do not use `--ask-vault-pass` in an unattended build. Use the protected external Vault password file.

---

## Standard VM101 service order

```text
linux-security-hardening/playbook.yml
playbooks/unattended-upgrades.yml
playbooks/alloy.yml
playbooks/postgresql.yml
playbooks/timescaledb.yml
playbooks/nginx.yml
playbooks/zabbix-server.yml
```

Every first-pass stage must have:

```text
unreachable=0
failed=0
```

Every second-pass stage must have:

```text
changed=0
unreachable=0
failed=0
```

---

## Current validation record - 2 September 2026

A clean VM was created successfully from template 9001 with:

```text
hostname=zabbix-server-01
VMID=101
IP=192.168.2.253
```

Validated gates:

```text
OpenTofu create:                         PASS
QEMU Guest Agent:                       PASS
IP discovery:                           PASS
QGA/network ED25519 exact match:        PASS
Strict SSH with verified known_hosts:   PASS
IdentitiesOnly=yes authentication:      PASS
Linux security hardening:               PASS
Unattended-upgrades:                    PASS
```

First-pass recaps:

```text
security hardening:
app-platform-01 : ok=15 changed=5 unreachable=0 failed=0

unattended upgrades:
app-platform-01 : ok=8 changed=1 unreachable=0 failed=0
```

The inventory alias still shows `app-platform-01`; final cleanup should align the inventory name with `zabbix-server-01` without changing the proven host/IP identity.

---

## Application validation

After base commissioning, use the service-specific runbooks:

```text
runbooks/alloy-install.md
runbooks/postgresql-install.md
runbooks/timescaledb-install.md
runbooks/nginx-install.md
runbooks/zabbix-server-install.md
```

Do not claim Zabbix TimescaleDB hypertables are configured merely because the TimescaleDB package and preload are present. Zabbix-specific TimescaleDB conversion must be separately automated and validated.

---

## Final drift gate

After all roles and live validation:

```bash
tofu plan -input=false -detailed-exitcode
```

Required result:

```text
exit code 0
```

Any result showing VM changes means the build is not closed.

---

## Acceptance checklist

A Linux VM IaC build is GREEN only when:

- [ ] OpenTofu ownership state is consistent.
- [ ] plan contains only intended resource actions.
- [ ] template 9001 QGA smoke gate passes.
- [ ] guest is created on `vm-ssd`.
- [ ] expected VMID/MAC/hostname are present.
- [ ] QEMU Guest Agent passes.
- [ ] guest IP is validated.
- [ ] QGA/network ED25519 fingerprints match.
- [ ] temporary verified `known_hosts` is used.
- [ ] `StrictHostKeyChecking=yes` is used.
- [ ] `IdentitiesOnly=yes` is used.
- [ ] cloud-init SSH key matches the controller key.
- [ ] security hardening succeeds.
- [ ] unattended-upgrades succeeds.
- [ ] Alloy succeeds.
- [ ] required application roles succeed.
- [ ] full second Ansible run is `changed=0`.
- [ ] final OpenTofu plan is zero drift.
