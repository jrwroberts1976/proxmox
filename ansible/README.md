# Ansible service foundation

This directory is the configuration-management layer for Proxmox guest workloads. OpenTofu/Terraform will create the VM; cloud-init will bootstrap access; Ansible will configure the operating system and services.

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

## Inventory

`inventories/example/hosts.yml` is intentionally empty. Copy it for the real environment and add hosts only after the OpenTofu/cloud-init VM design is fixed.

Example shape:

```yaml
all:
  children:
    postgresql_servers:
      hosts:
        db-01:
          ansible_host: 192.0.2.10
    timescaledb_servers:
      hosts:
        db-01:
    zabbix_agents:
      hosts:
        db-01:
```

`192.0.2.0/24` is documentation-only address space; do not copy that address into the homelab.

## Secrets

Passwords and tokens must never be committed in plaintext. Use Ansible Vault or another approved secret source.

Example variable structure:

```yaml
postgresql_users:
  - name: zabbix
    password: "{{ vault_zabbix_db_password }}"

postgresql_databases:
  - name: zabbix
    owner: zabbix

zabbix_server_db_password: "{{ vault_zabbix_db_password }}"
```

Keep `vault_zabbix_db_password` in an encrypted vault file that is appropriate for the target environment.

## Running the playbooks

Start with syntax/check mode against a disposable VM:

```bash
cd ansible
ansible-playbook playbooks/postgresql.yml --syntax-check
ansible-playbook playbooks/postgresql.yml --check --diff
```

Then run the required service playbook only after the disposable VM gate passes:

```bash
ansible-playbook playbooks/postgresql.yml
ansible-playbook playbooks/timescaledb.yml
ansible-playbook playbooks/nginx.yml
ansible-playbook playbooks/zabbix-server.yml
ansible-playbook playbooks/zabbix-agent.yml
```

## Important design notes

- PostgreSQL defaults to `listen_addresses = 'localhost'`. Remote access must be explicitly enabled together with tightly-scoped `pg_hba.conf` rules.
- TimescaleDB uses its official package repository and does not run `timescaledb-tune` unless explicitly enabled. Tuning must be validated against the VM's assigned RAM/CPU first.
- Zabbix defaults to the 7.0 LTS branch. The server role expects its PostgreSQL user/database to exist and can import the initial standard PostgreSQL schema.
- The Zabbix-specific TimescaleDB schema is **not yet automated** in this first foundation. That will be added only after the Zabbix + TimescaleDB combination is tested on a disposable VM.
- Zabbix Agent 2 is used for clients.
- No real IP addresses, usernames, passwords or API credentials are included in this foundation.

## Next validation work

1. Run `ansible-lint` and syntax checks in CI.
2. Provision one disposable Debian 13 VM through OpenTofu/cloud-init.
3. Validate PostgreSQL 17 idempotence with a second Ansible run.
4. Validate TimescaleDB install, preload and `CREATE EXTENSION timescaledb`.
5. Validate a simple Nginx reverse-proxy site.
6. Build the Zabbix PostgreSQL database and validate first server startup.
7. Add and validate the Zabbix TimescaleDB schema conversion/import step.
8. Add Molecule or an equivalent role-test strategy where practical.
