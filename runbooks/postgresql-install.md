# PostgreSQL Installation Runbook

## 1. Purpose

This runbook defines the controlled installation and validation procedure for PostgreSQL on a Debian VM created through the Proxmox IaC workflow.

The existing Ansible foundation is the implementation path:

```text
ansible/playbooks/postgresql.yml
ansible/roles/postgresql/
```

The current repository baseline targets PostgreSQL 17 on Debian 13.

This is runbook 2 in the platform sequence:

```text
Linux VM IaC -> PostgreSQL -> TimescaleDB -> Nginx
```

---

## 2. Preconditions

The Linux VM deployment runbook must already have passed.

Required:

- Debian 13 VM exists from OpenTofu/Terraform;
- VM is reachable by Ansible;
- intended hostname/IP are correct;
- time synchronisation is healthy;
- adequate free disk exists on the guest;
- no unexpected failed services exist;
- secrets are stored outside plaintext Git.

Verify:

```bash
cd ansible
ansible all -m ping --limit <DB_HOST>
ansible <DB_HOST> -m setup -a 'filter=ansible_distribution*'
ansible <DB_HOST> -m shell -a 'free -h && df -h && systemctl --failed'
```

---

## 3. Repository implementation

Current defaults:

```yaml
postgresql_version: 17
postgresql_listen_addresses: localhost
postgresql_port: 5432
postgresql_databases: []
postgresql_users: []
postgresql_hba_rules: []
```

The default is deliberately local-only. Do not expose PostgreSQL remotely unless there is a documented consumer and tightly-scoped `pg_hba.conf` rule.

---

## 4. Inventory

Place the target VM in `postgresql_servers`.

Example:

```yaml
all:
  children:
    postgresql_servers:
      hosts:
        db-01:
          ansible_host: <DB_IP>
```

Validate inventory:

```bash
cd ansible
ansible-inventory --graph
ansible postgresql_servers -m ping
```

---

## 5. Variables and secrets

Define environment-specific values outside the role defaults.

Example:

```yaml
postgresql_version: 17
postgresql_listen_addresses: localhost
postgresql_port: 5432

postgresql_databases:
  - name: homelab
    owner: homelab_app

postgresql_users:
  - name: homelab_app
    password: "{{ vault_homelab_db_password }}"
    role_attr_flags: LOGIN
```

Store `vault_homelab_db_password` only in an encrypted Ansible Vault or another approved secret source.

Never commit database passwords in inventory, defaults, playbooks, README files, shell history, or CI logs.

---

# Stage 0 - Version gate

## 6. Confirm package availability

Before the first deployment, confirm the intended PostgreSQL major version remains available for Debian 13 and is compatible with the TimescaleDB package that will be installed next.

The repository currently pins major version 17. Changing major PostgreSQL version is a design change, not a routine patch update.

Do not change the major version during an existing database deployment without a documented upgrade/migration plan.

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
ansible-playbook playbooks/postgresql.yml \
  --check --diff \
  --limit <DB_HOST>
```

Review all proposed changes. No unrelated service should be modified.

Note: package installation and database modules can have limitations in check mode. Treat check mode as a preview, not as proof of runtime success.

---

# Stage 2 - Install PostgreSQL

## 10. Apply the playbook

```bash
cd ansible
ansible-playbook playbooks/postgresql.yml \
  --limit <DB_HOST>
```

The role will:

- install PostgreSQL server/client packages;
- install `postgresql-contrib` and Python PostgreSQL bindings;
- create the managed `conf.d` include directory;
- enforce the homelab baseline configuration;
- use SCRAM-SHA-256 password encryption;
- add managed HBA rules;
- enable/start PostgreSQL;
- create declared roles;
- create declared databases.

---

# Stage 3 - Service validation

## 11. Validate service state

On the database VM:

```bash
systemctl --no-pager --full status postgresql
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

Expected:

```text
accepting connections
```

## 14. Validate managed configuration

```bash
sudo -u postgres psql -Atqc "SHOW listen_addresses;"
sudo -u postgres psql -Atqc "SHOW port;"
sudo -u postgres psql -Atqc "SHOW password_encryption;"
```

For the default build expect:

```text
localhost
5432
scram-sha-256
```

---

# Stage 4 - Database and role validation

## 15. List databases

```bash
sudo -u postgres psql -c '\l'
```

## 16. List roles

```bash
sudo -u postgres psql -c '\du'
```

Confirm only the intended application users/databases have been created.

Do not print application passwords during validation.

---

# Stage 5 - Remote access, only if required

## 17. Keep local-only by default

Do not change `listen_addresses` to `*` as a convenience measure.

If another VM genuinely needs database access:

1. set `postgresql_listen_addresses` to the required interface/address;
2. add the smallest possible CIDR in `postgresql_hba_rules`;
3. use `scram-sha-256` authentication;
4. restrict the network path with host/Proxmox firewall rules;
5. validate only the intended client can connect.

Example rule shape:

```text
host    <database>    <user>    <client-ip>/32    scram-sha-256
```

After changing access rules, rerun the Ansible playbook rather than editing PostgreSQL files manually.

---

# Stage 6 - Idempotence

## 18. Run the playbook again

```bash
ansible-playbook playbooks/postgresql.yml \
  --limit <DB_HOST>
```

Expected: no unexpected changes on the second run.

Investigate repeated changes before proceeding to TimescaleDB.

---

# Stage 7 - Basic functional test

## 19. Test a disposable database operation

For a fresh lab build only:

```bash
sudo -u postgres createdb runbook_test
sudo -u postgres psql runbook_test -c 'CREATE TABLE healthcheck(id integer primary key, created_at timestamptz default now());'
sudo -u postgres psql runbook_test -c 'INSERT INTO healthcheck(id) VALUES (1);'
sudo -u postgres psql runbook_test -c 'SELECT * FROM healthcheck;'
sudo -u postgres dropdb runbook_test
```

Expected: create, insert, select and drop all succeed.

---

# Stage 8 - Backup gate

## 20. Before storing important data

A database VM is not production-ready until an off-host backup and restore method exists.

At minimum the eventual database backup design must cover:

- database logical backups or an approved PostgreSQL-aware backup approach;
- Proxmox VM backup as a separate recovery layer;
- off-host storage;
- retention;
- restore testing;
- monitoring of backup failures.

Do not treat an on-host VM snapshot as a database backup strategy.

---

# Stage 9 - Rollback

## 21. Configuration rollback

If an Ansible configuration change breaks PostgreSQL:

1. do not manually improvise changes unless needed for immediate recovery;
2. revert the Git change;
3. rerun the playbook;
4. validate with `pg_isready` and the service checks above.

## 22. Fresh disposable install removal

For a disposable test VM, prefer destroying/recreating the entire guest through IaC rather than purging PostgreSQL packages and trying to return the machine to a pristine state.

Never delete `/var/lib/postgresql` or destroy the VM if it contains data that has not been backed up and restore-tested.

---

## 23. Acceptance criteria

PostgreSQL installation is complete when:

- [ ] Ansible syntax check passes.
- [ ] Playbook applies successfully.
- [ ] PostgreSQL service is enabled and active.
- [ ] Intended major version is installed.
- [ ] `pg_isready` succeeds.
- [ ] `listen_addresses`, port and SCRAM configuration match Git.
- [ ] Intended database roles exist.
- [ ] Intended databases exist.
- [ ] No plaintext secrets are committed.
- [ ] A second Ansible run is idempotent.
- [ ] Basic create/read/drop functional test passes on the disposable build.

Then proceed to `runbooks/timescaledb-install.md`.
