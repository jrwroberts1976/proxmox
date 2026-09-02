# Zabbix Server Installation Runbook

## 1. Purpose

This runbook defines the controlled IaC deployment and validation procedure for Zabbix Server on the Debian 13 application platform VM.

Implementation:

```text
ansible/playbooks/zabbix-server.yml
ansible/roles/zabbix_server/
```

Current baseline:

```text
Zabbix:      7.0 LTS
Database:    PostgreSQL 17
DB host:     localhost
DB port:     5432
Frontend:    Nginx + PHP-FPM
HTTP port:   8080
Agent:       Zabbix Agent 2
```

For VM101:

```text
hostname: app-platform-01
IP:       192.168.2.253
VMID:     101
```

The required sequence is:

```text
Linux VM IaC
  -> Linux security hardening
  -> unattended-upgrades
  -> Alloy observability
  -> PostgreSQL
  -> TimescaleDB
  -> Nginx
  -> Zabbix Server
```

Zabbix is the final application-platform service gate before the complete end-to-end rebuild is accepted.

---

## 2. Preconditions

Before running the Zabbix server role, all of the following must be GREEN:

- VM101 exists from OpenTofu and guest acceptance has passed;
- SSH host identity has been independently verified;
- Linux security hardening has passed;
- unattended-upgrades has passed and is idempotent;
- Alloy is enabled, active and exporting telemetry;
- PostgreSQL 17 is enabled, active and accepting local connections;
- TimescaleDB packages and preload configuration are installed;
- Nginx is enabled, active and has valid configuration;
- VM101 is present in the permanent `zabbix_servers` inventory group;
- the Zabbix PostgreSQL role and database exist;
- the Zabbix DB password is supplied only through encrypted Ansible Vault data.

The PostgreSQL role manages Debian's `acl` package automatically. There is no manual `acl` installation step. `acl` provides `setfacl`, which Ansible requires when switching from the SSH user to `become_user: postgres` for PostgreSQL administration.

---

## 3. Permanent inventory

VM101 uses:

```text
ansible/inventories/vm101/hosts.yml
```

The host must be a member of:

```text
alloy_hosts
unattended_upgrades
linux_security_hardening
postgresql_servers
timescaledb_servers
nginx_servers
zabbix_servers
```

Validate:

```bash
cd /home/james/projects/proxmox/ansible
ansible-inventory \
  -i inventories/vm101/hosts.yml \
  --graph \
  --ask-vault-pass
```

Expected: `app-platform-01` appears under every required group.

---

## 4. Secrets

The Zabbix database password must never appear in plaintext Git, shell history, terminal output or CI logs.

VM101 uses a non-secret variable reference:

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

Encrypted secret location:

```text
ansible/inventories/vm101/group_vars/all/vault.yml
```

Non-secret references:

```text
ansible/inventories/vm101/group_vars/all/main.yml
```

Validate only the vault header, never its encrypted body or decrypted value:

```bash
head -1 inventories/vm101/group_vars/all/vault.yml
```

Expected:

```text
$ANSIBLE_VAULT;1.1;AES256
```

---

# Stage 0 - PostgreSQL prerequisite gate

## 5. Apply PostgreSQL declarations

The Zabbix role expects the `zabbix` PostgreSQL user/database to exist before schema bootstrap.

```bash
cd /home/james/projects/proxmox/ansible

ansible-playbook \
  -i inventories/vm101/hosts.yml \
  playbooks/postgresql.yml \
  --ask-vault-pass
```

The PostgreSQL role installs `acl` automatically before any `become_user: postgres` database-management tasks.

### VM101 validation record - 2 September 2026

After the `acl` dependency was added to the PostgreSQL role, the Zabbix database prerequisite run completed successfully:

```text
app-platform-01 : ok=9 changed=3 unreachable=0 failed=0 skipped=1
```

The earlier failure caused by missing `setfacl` is therefore fixed in IaC and must not be converted into a manual build step.

---

## 6. Verify Zabbix database objects

Do not display the password.

```bash
ssh james@192.168.2.253 '
  sudo -u postgres psql -Atqc "SELECT rolname FROM pg_roles WHERE rolname='"'"'zabbix'"'"';"
  sudo -u postgres psql -Atqc "SELECT datname || '"'"'|'"'"' || pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='"'"'zabbix'"'"';"
'
```

Expected:

```text
zabbix
zabbix|zabbix
```

Stop if either object is absent or the database owner is not `zabbix`.

---

# Stage 1 - Static validation

## 7. Syntax check

```bash
cd /home/james/projects/proxmox/ansible

ansible-playbook \
  -i inventories/vm101/hosts.yml \
  playbooks/zabbix-server.yml \
  --syntax-check \
  --ask-vault-pass
```

Expected: syntax check succeeds.

---

## 8. Role behavior

The Zabbix server role currently:

1. verifies Debian 13+ and requires `zabbix_server_db_password`;
2. installs the official Zabbix 7.0 repository package;
3. installs:
   - `zabbix-server-pgsql`;
   - `zabbix-frontend-php`;
   - `zabbix-nginx-conf`;
   - `zabbix-sql-scripts`;
   - `zabbix-agent2`;
   - `postgresql-client`;
4. configures the PostgreSQL connection in `/etc/zabbix/zabbix_server.conf`;
5. checks whether the initial Zabbix schema already exists;
6. imports `/usr/share/zabbix-sql-scripts/postgresql/server.sql.gz` only when the schema is absent;
7. configures the packaged Zabbix Nginx listener on port `8080`;
8. enables and starts Zabbix Server, Zabbix Agent 2, Nginx and PHP-FPM;
9. reloads Nginx only when frontend configuration changes.

The schema-existence check is the idempotence gate for initial database bootstrap.

---

# Stage 2 - First Zabbix deployment

## 9. Apply the playbook

```bash
cd /home/james/projects/proxmox/ansible

ansible-playbook \
  -i inventories/vm101/hosts.yml \
  playbooks/zabbix-server.yml \
  --ask-vault-pass
```

Do not use `--diff` for secret-bearing Zabbix configuration unless the relevant tasks are confirmed safe. Database-password tasks use `no_log` and must remain protected.

Required recap:

```text
unreachable=0
failed=0
```

---

# Stage 3 - Service validation

## 10. Validate service state

```bash
ssh james@192.168.2.253 '
  echo "===== ZABBIX SERVER ====="
  sudo systemctl is-enabled zabbix-server
  sudo systemctl is-active zabbix-server

  echo
  echo "===== ZABBIX AGENT 2 ====="
  sudo systemctl is-enabled zabbix-agent2
  sudo systemctl is-active zabbix-agent2

  echo
  echo "===== NGINX ====="
  sudo systemctl is-enabled nginx
  sudo systemctl is-active nginx

  echo
  echo "===== PHP-FPM ====="
  sudo systemctl is-enabled php8.4-fpm
  sudo systemctl is-active php8.4-fpm
'
```

Expected: every service is `enabled` and `active`.

---

## 11. Validate processes and listeners

```bash
ssh james@192.168.2.253 '
  echo "===== LISTENERS ====="
  sudo ss -ltnp | grep -E ":(8080|10051|10050) " || true
'
```

Expected baseline:

- TCP 8080: Zabbix frontend via Nginx;
- TCP 10051: Zabbix server trapper/listener where enabled by the packaged configuration;
- TCP 10050: Zabbix Agent 2.

Investigate any missing expected listener before continuing.

---

## 12. Validate Zabbix server database connection

```bash
ssh james@192.168.2.253 '
  sudo journalctl -u zabbix-server -n 80 --no-pager
'
```

Required outcome: no authentication, missing-schema, connection-refused or fatal startup errors.

Do not expose `DBPassword` while troubleshooting.

---

# Stage 4 - Schema validation

## 13. Confirm schema exists

```bash
ssh james@192.168.2.253 '
  sudo -u postgres psql -d zabbix -Atqc "SELECT to_regclass('"'"'public.users'"'"') IS NOT NULL;"
'
```

Expected:

```text
t
```

The initial standard PostgreSQL schema is imported automatically only when absent.

### TimescaleDB note

The current Zabbix role bootstraps the standard PostgreSQL schema. Zabbix-specific TimescaleDB schema conversion is a separate validation stage and must not be assumed complete merely because the TimescaleDB package is installed and preloaded.

---

# Stage 5 - Frontend validation

## 14. Validate Nginx configuration

```bash
ssh james@192.168.2.253 '
  sudo nginx -t
  curl -fsSI http://127.0.0.1:8080/ | head
'
```

Required:

- `nginx -t` succeeds;
- the frontend returns an HTTP response;
- no unexpected listener is exposed.

External/LAN exposure should be deliberate and documented; do not broaden database access as part of frontend setup.

---

# Stage 6 - Idempotence

## 15. Run Zabbix playbook again

```bash
cd /home/james/projects/proxmox/ansible

ansible-playbook \
  -i inventories/vm101/hosts.yml \
  playbooks/zabbix-server.yml \
  --ask-vault-pass
```

Target:

```text
changed=0
unreachable=0
failed=0
```

A second run must not re-import the database schema or repeatedly restart services without a configuration change.

---

# Stage 7 - Observability regression gate

## 16. Ensure existing telemetry still works

```bash
ssh james@192.168.2.253 '
  systemctl is-active alloy
  curl -fsS http://127.0.0.1:12345/-/healthy
  systemctl --failed --no-legend
'
```

Then centrally verify VM101 metrics and journal logs remain visible in Prometheus/Loki.

---

# Stage 8 - End-to-end rebuild acceptance

After the standalone Zabbix role is GREEN and idempotent, integrate it into the VM101 end-to-end rebuild.

The unattended rebuild sequence must prove:

```text
OpenTofu destroy/recreate
  -> QGA identity/SSH trust gate
  -> base guest acceptance
  -> Linux security hardening
  -> unattended-upgrades
  -> Alloy
  -> PostgreSQL (including automatic acl dependency)
  -> TimescaleDB
  -> Nginx
  -> Zabbix Server
  -> service validation
  -> second Ansible/idempotence pass
  -> OpenTofu zero drift
```

No manual `apt install acl`, database creation, schema import, Nginx edit or Zabbix configuration edit is permitted in the accepted E2E path.

---

## Acceptance criteria

Zabbix Server is GREEN when:

- [ ] permanent VM101 inventory includes `zabbix_servers`;
- [ ] encrypted vault is used and no plaintext DB password is committed;
- [ ] PostgreSQL `zabbix` role exists;
- [ ] PostgreSQL `zabbix` database exists and is owned by `zabbix`;
- [ ] PostgreSQL role installs `acl` automatically;
- [ ] Zabbix 7.0 packages install successfully;
- [ ] initial Zabbix schema exists;
- [ ] Zabbix Server is enabled and active;
- [ ] Zabbix Agent 2 is enabled and active;
- [ ] Nginx and PHP-FPM are enabled and active;
- [ ] `nginx -t` succeeds;
- [ ] Zabbix frontend responds on the intended listener;
- [ ] no Zabbix database startup errors are present;
- [ ] second Zabbix Ansible run is `changed=0`;
- [ ] Alloy/Prometheus/Loki telemetry remains healthy;
- [ ] full destroy/rebuild can complete without manual package or service intervention.
