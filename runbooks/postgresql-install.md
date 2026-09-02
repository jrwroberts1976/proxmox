# PostgreSQL Installation Runbook

## 1. Purpose

This runbook defines the controlled installation and validation procedure for PostgreSQL on a Debian VM created through the Proxmox IaC workflow.

The existing Ansible foundation is the implementation path:

```text
ansible/playbooks/postgresql.yml
ansible/roles/postgresql/
```

The current repository baseline targets PostgreSQL 17 on Debian 13.

The required platform sequence is:

```text
Linux VM IaC
  -> guest acceptance
  -> Linux security hardening
  -> Alloy observability acceptance
  -> PostgreSQL
  -> TimescaleDB
  -> Nginx
  -> Zabbix Server
```

PostgreSQL must not be used as a shortcut around an incomplete VM baseline. Security and observability are mandatory gates before database installation.

---

## 2. Preconditions

The following runbooks must already have passed for the target VM:

```text
runbooks/linux-vm-iac-deployment.md
runbooks/linux-vm-security-hardening.md
runbooks/linux-vm-observability-bootstrap.md
```

Required:

- Debian 13 VM exists from OpenTofu/Terraform;
- VM is reachable by Ansible;
- intended hostname/IP are correct;
- time synchronisation is healthy;
- no unexpected failed services exist;
- Linux security-hardening gate is closed;
- Alloy is enabled, active, ready and healthy;
- Linux `node_*` metrics are visible in authoritative Prometheus on `ids-01`;
- journal logs are visible in authoritative Loki on `ids-01`;
- duplicate host-metrics path check has passed;
- adequate free disk exists on the guest;
- secrets are stored outside plaintext Git.

For VM101, the observability baseline has already proved:

```text
Prometheus: 192.168.2.242:9090
Loki:       192.168.2.242:3100
hostname:   app-platform-01
role:       application
environment: homelab
```

Verify the target VM before proceeding:

```bash
cd ansible
ansible all -m ping --limit <DB_HOST>
ansible <DB_HOST> -m setup -a 'filter=ansible_distribution*'
ansible <DB_HOST> -m shell -a 'free -h && df -h && systemctl --failed'
ansible <DB_HOST> -b -m shell -a 'systemctl is-active alloy && curl -fsS http://127.0.0.1:12345/-/healthy'
```

Stop if the baseline has regressed.

---

## 3. Repository implementation

Current defaults include:

```yaml
postgresql_version: 17
postgresql_packages:
  - acl
  - "postgresql-{{ postgresql_version }}"
  - "postgresql-client-{{ postgresql_version }}"
  - postgresql-contrib
  - python3-psycopg2
postgresql_listen_addresses: localhost
postgresql_port: 5432
postgresql_databases: []
postgresql_users: []
postgresql_hba_rules: []
```

### Automated `acl` dependency

The PostgreSQL role installs Debian's `acl` package automatically. This is an IaC-managed dependency and is **not** a manual pre-installation step.

Why it is required:

- Ansible connects to VM101 as the normal SSH user (`james`).
- PostgreSQL administration tasks use `become_user: postgres`.
- Ansible must securely make temporary module files readable by the unprivileged `postgres` account.
- Debian's `acl` package provides `setfacl`, which Ansible uses for that privilege-escalation path.

Without `acl`, role/database creation can fail before PostgreSQL is touched with an error similar to:

```text
Failed to set permissions on the temporary files Ansible needs to create
chmod: invalid mode: 'A+user:postgres:rx:allow'
```

Do not work around this by manually installing `acl` on a freshly rebuilt guest. The PostgreSQL role must install it so the same dependency is present during unattended end-to-end rebuilds.

Optional validation:

```bash
command -v setfacl
dpkg -s acl | grep '^Status:'
```

Expected:

```text
/usr/bin/setfacl
Status: install ok installed
```

The default PostgreSQL listener remains deliberately local-only. Do not expose PostgreSQL remotely unless there is a documented consumer and tightly-scoped `pg_hba.conf` rule.

---

## 4. Inventory

Place the target VM in `postgresql_servers`.

VM101 uses the permanent inventory:

```text
ansible/inventories/vm101/hosts.yml
```

Validate inventory:

```bash
cd ansible
ansible-inventory -i inventories/vm101/hosts.yml --graph --ask-vault-pass
ansible -i inventories/vm101/hosts.yml postgresql_servers -m ping --ask-vault-pass
```

A host may also remain in Alloy, TimescaleDB, Nginx and Zabbix groups. Application-role membership must not remove observability management.

---

## 5. Variables and secrets

Define environment-specific values outside the role defaults.

For Zabbix on VM101, the non-secret variable structure is:

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

The actual `vault_zabbix_db_password` value belongs only in an encrypted Ansible Vault file. Never commit database passwords in plaintext inventory, defaults, playbooks, README files, shell history or CI logs.

VM101 keeps the encrypted secret under:

```text
ansible/inventories/vm101/group_vars/all/vault.yml
```

and non-secret references under:

```text
ansible/inventories/vm101/group_vars/all/main.yml
```

---

# Stage 0 - Version gate

## 6. Confirm package availability

Before the first deployment, confirm the intended PostgreSQL major version remains available for Debian 13 and is compatible with the TimescaleDB package that will be installed next.

The repository currently pins major version 17. Changing major PostgreSQL version is a design change, not a routine patch update.

---

# Stage 1 - Static validation

## 7. Install Ansible dependencies

From the controller:

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

## 8. Syntax check

```bash
ansible-playbook playbooks/postgresql.yml --syntax-check
```

Expected: success.

## 9. Check mode

```bash
ansible-playbook \
  -i inventories/vm101/hosts.yml \
  playbooks/postgresql.yml \
  --check --diff \
  --ask-vault-pass
```

Review all proposed changes. Package installation and database modules can have limitations in check mode; treat check mode as a preview, not proof of runtime success.

---

# Stage 2 - Install PostgreSQL

## 10. Apply the playbook

```bash
cd ansible
ansible-playbook \
  -i inventories/vm101/hosts.yml \
  playbooks/postgresql.yml \
  --ask-vault-pass
```

The role will:

- install `acl` automatically for Ansible's `become_user: postgres` path;
- install PostgreSQL server/client packages;
- install `postgresql-contrib` and Python PostgreSQL bindings;
- create the managed `conf.d` include directory;
- enforce the homelab baseline configuration;
- use SCRAM-SHA-256 password encryption;
- add managed HBA rules;
- enable/start PostgreSQL;
- create declared roles;
- create declared databases.

### VM101 validation record - 2 September 2026

The first VM101 run with a declared `zabbix` role/database exposed the missing `acl` dependency. After adding `acl` to the role-managed package list, the rerun completed successfully:

```text
PLAY RECAP
app-platform-01 : ok=9 changed=3 unreachable=0 failed=0 skipped=1
```

This proves the dependency must remain in IaC for future clean rebuilds.

---

# Stage 3 - Service validation

## 11. Validate service state

```bash
systemctl is-enabled postgresql
systemctl is-active postgresql
pg_lsclusters
```

Expected: PostgreSQL is enabled and active and the intended cluster is online.

## 12. Confirm version

```bash
psql --version
sudo -u postgres psql -Atqc 'SHOW server_version;'
```

Expected major version: `17` unless the repository baseline has deliberately changed.

## 13. Readiness check

```bash
pg_isready -h 127.0.0.1 -p 5432
```

Expected: `accepting connections`.

## 14. Validate managed configuration

```bash
sudo -u postgres psql -Atqc "SHOW listen_addresses;"
sudo -u postgres psql -Atqc "SHOW port;"
sudo -u postgres psql -Atqc "SHOW password_encryption;"
```

Default expectation:

```text
localhost
5432
scram-sha-256
```

---

# Stage 4 - Database and role validation

## 15. Validate declared objects

For the VM101 Zabbix build, verify existence and ownership without printing any secret:

```bash
sudo -u postgres psql -Atqc "SELECT rolname FROM pg_roles WHERE rolname='zabbix';"
sudo -u postgres psql -Atqc "SELECT datname || '|' || pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='zabbix';"
```

Expected:

```text
zabbix
zabbix|zabbix
```

Do not print application passwords during validation.

---

# Stage 5 - Remote access, only if required

PostgreSQL remains local-only by default. Do not change `listen_addresses` to `*` as a convenience measure.

If another VM genuinely requires access, use the smallest possible listener and `pg_hba.conf` scope, SCRAM-SHA-256 authentication and network/firewall restrictions.

---

# Stage 6 - Idempotence

Run the playbook again:

```bash
ansible-playbook \
  -i inventories/vm101/hosts.yml \
  playbooks/postgresql.yml \
  --ask-vault-pass
```

Expected acceptance target:

```text
changed=0
unreachable=0
failed=0
```

Investigate repeated changes before proceeding.

---

# Stage 7 - Observability regression check

PostgreSQL installation must not silently break the already accepted host telemetry.

```bash
systemctl is-active alloy
curl -fsS http://127.0.0.1:12345/-/healthy
systemctl --failed --no-legend
```

PostgreSQL-specific exporters/log parsing are separate enhancements and do not replace the host-level Alloy baseline.

---

# Stage 8 - Backup gate

A database VM is not production-ready until an off-host backup and restore method exists. Proxmox VM backup is a separate recovery layer and is not by itself a PostgreSQL-aware database backup strategy.

---

# Stage 9 - Rollback

If an Ansible configuration change breaks PostgreSQL:

1. revert the Git change;
2. rerun the playbook;
3. validate with `pg_isready` and service checks;
4. confirm Alloy/host observability remains healthy.

For a disposable test VM, prefer destroy/recreate through IaC rather than manually trying to return the guest to pristine state.

---

## Acceptance criteria

PostgreSQL installation is complete when:

- [ ] IaC guest gate passed.
- [ ] Security-hardening gate passed.
- [ ] Observability gate passed.
- [ ] Ansible syntax check passes.
- [ ] `acl` is installed automatically by the PostgreSQL role; no manual prerequisite is required.
- [ ] PostgreSQL service is enabled and active.
- [ ] Intended PostgreSQL major version is installed.
- [ ] `pg_isready` succeeds.
- [ ] listener, port and SCRAM configuration match Git.
- [ ] intended database roles exist.
- [ ] intended databases exist with the correct owners.
- [ ] no plaintext secrets are committed.
- [ ] second Ansible run is idempotent (`changed=0`).
- [ ] Alloy remains healthy after installation.

For the VM101 application platform, continue through TimescaleDB and Nginx, then proceed to `runbooks/zabbix-server-install.md`.
