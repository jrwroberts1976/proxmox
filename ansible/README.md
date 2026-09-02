# Ansible service foundation

This directory is the configuration-management layer for Proxmox guest workloads. OpenTofu/Terraform creates the VM; cloud-init bootstraps access; Ansible configures the operating system and services.

## Initial roles

| Role | Purpose | Initial target |
|---|---|---|
| `postgresql` | PostgreSQL packages, baseline configuration, roles and databases | PostgreSQL 17 on Debian 13 |
| `timescaledb` | Official TimescaleDB repository/package, preload library and selected database extensions | TimescaleDB on PostgreSQL 17 |
| `nginx` | Nginx package and reusable reverse-proxy/static sites | Debian 13 |
| `zabbix_server` | Zabbix server, frontend, Nginx integration and PostgreSQL schema bootstrap | Zabbix 7.0 LTS |
| `zabbix_agent` | Zabbix Agent 2 client configuration | Zabbix 7.0 LTS |

The roles are deliberately separate. A VM may be placed in several inventory groups, allowing PostgreSQL, TimescaleDB, Nginx and Zabbix to be composed without turning the repository into one monolithic playbook.

## Controller prerequisites

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

The managed PostgreSQL host needs psycopg. The PostgreSQL and TimescaleDB roles install `python3-psycopg2` for the `community.postgresql` modules.

The PostgreSQL role also installs Debian's `acl` package automatically. This provides `setfacl`, which Ansible needs when it connects as the normal SSH user and then uses `become_user: postgres` for PostgreSQL administration. `acl` is an IaC-managed dependency; do not add a manual package-install step to the build procedure.

## Inventory

`inventories/example/hosts.yml` is intentionally empty. Copy it for the real environment and add hosts only after the OpenTofu/cloud-init VM design is fixed.

VM101 uses the permanent inventory:

```text
inventories/vm101/hosts.yml
```

`app-platform-01` is composed through service groups including:

```text
alloy_hosts
unattended_upgrades
linux_security_hardening
postgresql_servers
timescaledb_servers
nginx_servers
zabbix_servers
```

Validate the VM101 inventory with:

```bash
ansible-inventory \
  -i inventories/vm101/hosts.yml \
  --graph \
  --ask-vault-pass
```

## Secrets

Passwords and tokens must never be committed in plaintext. Use Ansible Vault or another approved secret source.

VM101 Zabbix uses one encrypted database password for both PostgreSQL role creation and the Zabbix server connection:

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

The actual value belongs only in the encrypted vault file:

```text
inventories/vm101/group_vars/all/vault.yml
```

Non-secret references belong in:

```text
inventories/vm101/group_vars/all/main.yml
```

Never print or commit the decrypted password.

## Running the service stack

For VM101, run the service roles in dependency order:

```bash
cd ansible

ansible-playbook -i inventories/vm101/hosts.yml playbooks/postgresql.yml --ask-vault-pass
ansible-playbook -i inventories/vm101/hosts.yml playbooks/timescaledb.yml --ask-vault-pass
ansible-playbook -i inventories/vm101/hosts.yml playbooks/nginx.yml --ask-vault-pass
ansible-playbook -i inventories/vm101/hosts.yml playbooks/zabbix-server.yml --ask-vault-pass
```

The PostgreSQL playbook creates the declared `zabbix` database role/database before the Zabbix server role attempts schema bootstrap.

## Important design notes

- PostgreSQL defaults to `listen_addresses = 'localhost'`. Remote access must be explicitly enabled together with tightly-scoped `pg_hba.conf` rules.
- The PostgreSQL role manages `acl`; missing `setfacl` must not be worked around manually on a rebuilt guest.
- TimescaleDB uses its official package repository and does not run `timescaledb-tune` unless explicitly enabled. Tuning must be validated against the VM's assigned RAM/CPU first.
- Zabbix defaults to the 7.0 LTS branch. The server role expects its PostgreSQL user/database to exist and can import the initial standard PostgreSQL schema.
- The Zabbix-specific TimescaleDB schema conversion is a separate validation stage; package/preload installation alone does not prove Zabbix TimescaleDB integration.
- Zabbix Agent 2 is used for clients.
- No plaintext passwords or API credentials belong in Git.

## VM101 validation status - 2 September 2026

The standalone platform roles have been validated on `app-platform-01` through PostgreSQL, TimescaleDB and Nginx. When the `zabbix` PostgreSQL role/database was first declared, Ansible exposed a missing `acl` dependency during `become_user: postgres`. Adding `acl` to the PostgreSQL role package list fixed the problem and the rerun completed:

```text
app-platform-01 : ok=9 changed=3 unreachable=0 failed=0 skipped=1
```

This is now part of the automated role behavior and must remain in the full end-to-end rebuild path.

## Runbooks

Relevant procedures:

```text
../runbooks/postgresql-install.md
../runbooks/timescaledb-install.md
../runbooks/nginx-install.md
../runbooks/zabbix-server-install.md
```

After the standalone Zabbix server role is GREEN and idempotent, the next acceptance target is a full VM101 destroy/rebuild with the entire service chain applied automatically and followed by an idempotence and OpenTofu zero-drift gate.
