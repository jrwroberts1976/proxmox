# Zabbix Server Installation Runbook

## Purpose

This runbook defines the controlled IaC build and validation path for the Debian 13 Zabbix Server platform.

Authoritative components:

```text
OpenTofu:  tofu/
Ansible:   ansible/playbooks/zabbix-server.yml
Role:      ansible/roles/zabbix_server/
Inventory: ansible/inventories/vm101/hosts.yml
```

Current target identity:

```text
VMID:      101
Hostname:  zabbix-server-01
IP:        192.168.2.253
MAC:       BC:24:11:08:A2:33
Template:  9001 debian-13-cloud-template-qga
OS:        Debian 13 trixie
vCPU:      2
RAM:       4096 MB
Disk:      64 GB
Storage:   vm-ssd
```

The accepted build order is:

```text
OpenTofu VM create/recreate
  -> QEMU Guest Agent identity gate
  -> QGA-verified SSH host-key trust
  -> SSH identity gate
  -> Linux security hardening
  -> unattended-upgrades
  -> Alloy
  -> PostgreSQL
  -> TimescaleDB
  -> Nginx
  -> Zabbix Server + Agent 2 + frontend
  -> live service/database/frontend validation
  -> second Ansible pass requiring changed=0
  -> final OpenTofu zero-drift gate
```

No manual package installation, database creation, schema import, Nginx edit, Zabbix edit, SSH trust bypass or plaintext secret entry is part of the accepted build.

---

## Current validated state - 2 September 2026

The clean-build path has now proved:

```text
OpenTofu clean VM creation:            PASS
VM name:                               zabbix-server-01
QEMU Guest Agent:                      PASS
Guest IP discovery:                    PASS (192.168.2.253)
QGA ED25519 host-key fingerprint:      PASS
Network ED25519 fingerprint match:     PASS
Strict SSH with intended key only:     PASS
Linux security hardening first pass:   PASS
Unattended-upgrades first pass:        PASS
```

Validated Ansible recaps:

```text
Linux security hardening:
app-platform-01 : ok=15 changed=5 unreachable=0 failed=0

Unattended upgrades:
app-platform-01 : ok=8 changed=1 unreachable=0 failed=0
```

`app-platform-01` in these recaps is currently the Ansible inventory alias. The actual guest hostname is `zabbix-server-01`. Inventory naming should be aligned with the guest hostname before final closure.

The remaining first-pass sequence is:

```text
Alloy
PostgreSQL
TimescaleDB
Nginx
Zabbix Server
```

followed by live validation, a complete `changed=0` second pass and final OpenTofu zero drift.

---

## Security findings that must remain automated

### 1. SSH host key must be verified through QGA

A freshly created VM generates a new SSH host key. Do not use `StrictHostKeyChecking=no` or permanently rely on `accept-new`.

The accepted trust sequence is:

```text
QGA reads /etc/ssh/ssh_host_ed25519_key.pub
  -> calculate trusted SHA256 fingerprint
  -> ssh-keyscan retrieves network ED25519 key
  -> reduce results to unique fingerprints
  -> require exactly one unique network fingerprint
  -> require exact QGA/network fingerprint match
  -> write verified key to temporary known_hosts
  -> use StrictHostKeyChecking=yes
```

`ssh-keyscan` may return duplicate lines for the same ED25519 key. The gate must count **unique fingerprints**, not raw output lines.

### 2. Controller must use the intended SSH identity only

A direct strict SSH test proved the controller key and guest `authorized_keys` fingerprint match. To prevent an SSH agent offering unrelated identities first, automation must include:

```text
-o IdentitiesOnly=yes
```

Ansible SSH settings must include the same requirement together with the verified temporary `known_hosts` file and `StrictHostKeyChecking=yes`.

### 3. Cloud-init account state

The cloud-init-created `james` account reports password state `L`, while password authentication is disabled. Public-key authentication is valid and has been directly proved. Do not add or expose a password simply to clear the `L` state.

The required account checks are:

```text
james account exists
james is in sudo
/home/james mode 0700
/home/james/.ssh mode 0700
authorized_keys mode 0600
controller and authorized_keys fingerprints match
sshd PubkeyAuthentication yes
```

---

## Secrets

The Zabbix database password is stored only in encrypted Ansible Vault data:

```text
ansible/inventories/vm101/group_vars/all/vault.yml
```

Non-secret references are in:

```text
ansible/inventories/vm101/group_vars/all/main.yml
```

The controller uses an external Vault password file:

```text
/home/james/.config/homelab-iac/ansible-vault-password
```

Required properties:

```text
owner: james
mode:  0600
```

Validate decryption without printing the secret:

```bash
ansible-vault view \
  --vault-password-file /home/james/.config/homelab-iac/ansible-vault-password \
  ansible/inventories/vm101/group_vars/all/vault.yml \
  >/dev/null
```

Never commit the Vault password file or decrypted secret.

---

## PostgreSQL prerequisite

The PostgreSQL role must create the Zabbix login/database before the Zabbix role imports the schema:

```yaml
postgresql_users:
  - name: zabbix
    password: "{{ vault_zabbix_db_password }}"
    role_attr_flags: LOGIN

postgresql_databases:
  - name: zabbix
    owner: zabbix

zabbix_server_db_password: "{{ vault_zabbix_db_password }}"
```

The PostgreSQL role also installs Debian package `acl` automatically. `setfacl` is required when Ansible connects as `james` and uses `become_user: postgres`.

Do not add a manual `apt install acl` step.

---

## Zabbix server role behavior

The `zabbix_server` role currently manages:

```text
Zabbix 7.0 LTS repository
zabbix-server-pgsql
zabbix-frontend-php
zabbix-nginx-conf
zabbix-sql-scripts
zabbix-agent2
postgresql-client
PostgreSQL connection settings
initial schema import when absent
/etc/zabbix/web/zabbix.conf.php
Nginx listener on 8080
zabbix-server service
zabbix-agent2 service
nginx service
php8.4-fpm service
```

The frontend configuration task is secret-bearing and must remain protected with `no_log: true`.

The role must not re-import the schema when it already exists.

---

## First-pass Ansible sequence

Use the permanent VM inventory and external Vault password file.

```bash
cd /home/james/projects/proxmox/ansible

export ANSIBLE_HOST_KEY_CHECKING=True
export ANSIBLE_SSH_COMMON_ARGS="-o IdentitiesOnly=yes -o UserKnownHostsFile=<verified-known-hosts> -o StrictHostKeyChecking=yes"
export ANSIBLE_ROLES_PATH="/home/james/projects/proxmox/ansible/roles:/home/james/projects/proxmox/ansible/linux-security-hardening/roles"
```

Run in this order:

```text
linux-security-hardening/playbook.yml
playbooks/unattended-upgrades.yml
playbooks/alloy.yml
playbooks/postgresql.yml
playbooks/timescaledb.yml
playbooks/nginx.yml
playbooks/zabbix-server.yml
```

Every first-pass recap must contain:

```text
unreachable=0
failed=0
```

A non-zero `changed` count is expected on the first build.

---

## Live validation

### Services

Required active services:

```text
postgresql
alloy
nginx
php8.4-fpm
zabbix-server
zabbix-agent2
```

### PostgreSQL

Required baseline:

```text
PostgreSQL major version: 17
listen_addresses: localhost
Zabbix database: present
Zabbix owner: zabbix
```

### TimescaleDB

Required foundational validation:

```text
TimescaleDB package installed
shared_preload_libraries contains timescaledb
TimescaleDB extension is available
```

This does **not** prove that the Zabbix database has been converted to TimescaleDB hypertables. Zabbix-specific TimescaleDB conversion remains a separate step until explicitly automated and validated.

### Zabbix schema

Required:

```text
public.users exists
public table count is at least 200
```

### Listeners

Required:

```text
8080   Zabbix frontend via Nginx
10051  Zabbix Server
10050  Zabbix Agent 2
```

### Frontend

Required external result:

```text
HTTP 200 from http://192.168.2.253:8080/
```

The frontend must not redirect to `setup.php`; the Ansible-managed `/etc/zabbix/web/zabbix.conf.php` must already provide database configuration.

---

## Idempotence gate

Run the entire seven-stage Ansible chain again in the same order.

Every stage must end with:

```text
changed=0
unreachable=0
failed=0
```

Any `changed>0` result in the second pass is an E2E failure until understood.

---

## Final OpenTofu gate

After application commissioning:

```bash
tofu plan -input=false -detailed-exitcode
```

Required exit code:

```text
0
```

No persistent Proxmox GUI correction is accepted as closure. Any intended persistent VM change belongs in OpenTofu.

---

## Clean-create safety model

The one-button target workflow must distinguish two states:

```text
CLEAN CREATE
OpenTofu state empty + VM101 absent
  -> skip backup/destroy
  -> require exactly one create

MANAGED REBUILD
OpenTofu state contains exactly app_platform + VM101 exists
  -> backup/state gates
  -> controlled destroy
  -> exactly one recreate
```

Any inconsistent ownership state must fail closed.

A clean-create workflow must never destroy an existing unmanaged VM101.

---

## Acceptance checklist

Zabbix Server is complete only when all are true:

- [ ] OpenTofu controls exactly the intended VM.
- [ ] Debian 13 guest hostname is correct.
- [ ] QEMU Guest Agent is healthy.
- [ ] guest IP is obtained and validated.
- [ ] QGA and network ED25519 fingerprints match.
- [ ] SSH uses `StrictHostKeyChecking=yes`.
- [ ] SSH/Ansible use `IdentitiesOnly=yes`.
- [ ] Vault password remains external and mode 0600.
- [ ] security hardening succeeds.
- [ ] unattended-upgrades succeeds.
- [ ] Alloy succeeds and telemetry remains available.
- [ ] PostgreSQL 17 succeeds.
- [ ] `acl` is installed automatically by the PostgreSQL role.
- [ ] TimescaleDB package/preload validation succeeds.
- [ ] Nginx configuration succeeds.
- [ ] Zabbix Server 7.0 succeeds.
- [ ] Zabbix Agent 2 succeeds.
- [ ] standard PostgreSQL Zabbix schema exists.
- [ ] frontend returns HTTP 200 without setup wizard redirect.
- [ ] all required listeners exist.
- [ ] complete second Ansible pass is `changed=0`.
- [ ] final OpenTofu plan has zero drift.

Only then is the one-button Zabbix Server build GREEN.
