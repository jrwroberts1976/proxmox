# Zabbix Server Installation Runbook

## Purpose

This runbook defines the controlled IaC deployment, validation and recovery path for the current Zabbix 7.0 LTS platform on Proxmox CT201.

Current target:

```text
Control node: TestServer
Proxmox:     PROXMOX / 192.168.2.70
CTID:        201
Hostname:    zabbix-lxc-01
IPv4:        192.168.2.184
OS:          Debian 13
Frontend:    http://192.168.2.184:8080/
```

Authority:

```text
OpenTofu: containers/zabbix-lxc/
Ansible:  ansible/
Git:      jrwroberts1976/proxmox
```

The retired VM101 workload is historical only and is not the current deployment target.

## Accepted build order

```text
OpenTofu CT201
  -> commissioning and zero-drift proof
  -> Linux security hardening
  -> unattended-upgrades
  -> Alloy
  -> PostgreSQL 17
  -> TimescaleDB extension/preload
  -> Nginx baseline
  -> Zabbix Server 7.0 + Agent 2 + PHP frontend
  -> standard Zabbix PostgreSQL schema
  -> Zabbix vendor TimescaleDB conversion
  -> locale validation
  -> frontend/API IaC
  -> final service/idempotence/drift proof
```

Do not manually create the database, import the schema, change persistent Nginx/PHP/Zabbix configuration, or bypass Ansible/Vault controls.

## Final validated state — 4 September 2026

Completed:

```text
Stage 1   LXC infrastructure                    PASS
Stage 2   hardening + unattended upgrades       PASS
Stage 3   Alloy                                 PASS
Stage 4   PostgreSQL 17                         PASS
Stage 5   TimescaleDB extension/preload         PASS
Stage 6A  Nginx baseline                        PASS
Stage 6B  Zabbix app + standard schema          PASS
Stage 6C  TimescaleDB conversion                PASS
Locale    en_GB + en_US for PHP/Zabbix          PASS
Stage 7A  Vault-backed Admin credential          PASS
Stage 7B  BH22 8QL frontend/Geomap IaC           PASS
Final     Ansible idempotence + OpenTofu drift   PASS
```

Final Stage 6C evidence:

```text
zabbix_server=ACTIVE
zabbix_frontend=ACTIVE
postgresql_version=17
timescaledb_extension=ACTIVE
zabbix_timescaledb_schema=CONVERTED
vendor_hypertables=COMPLETE
database_port_scope=LOCALHOST_ONLY
alloy=HEALTHY
systemd=HEALTHY
failed_units=ZERO
ansible_idempotence=PASS
```

Rollback dump:

```text
/var/backups/zabbix/zabbix-pre-timescaledb-20260903-230800.dump
```

## Secrets

CT201 secret values are stored in encrypted Ansible Vault data:

```text
ansible/inventories/zabbix-lxc/group_vars/all/vault.yml
```

Non-secret references live beside it in `main.yml`.

All CT201 plays load the encrypted `group_vars/all/vault.yml`, therefore commands currently require a Vault secret source such as:

```bash
ansible-playbook \
  -i ansible/inventories/zabbix-lxc/hosts.yml \
  ansible/playbooks/zabbix-server.yml \
  --ask-vault-pass
```

Never display decrypted values or commit a Vault password.

## PostgreSQL

Required state:

```text
major version:     17
cluster:           online
database:          zabbix
owner:             zabbix
encoding:          UTF8
listen_addresses:  localhost
password storage:  SCRAM-SHA-256
```

The database/user are Ansible-owned. The Zabbix role must not create them manually.

## TimescaleDB

The accepted order is important:

1. install/preload TimescaleDB;
2. enable the extension in the `zabbix` database;
3. import the normal Zabbix PostgreSQL schema;
4. stop Zabbix server/frontend services;
5. run the packaged Zabbix TimescaleDB schema;
6. restart services;
7. verify every vendor-declared hypertable;
8. require the Zabbix database marker `db_extension=timescaledb`.

The conversion is owned by:

```text
ansible/roles/zabbix_timescaledb/
ansible/playbooks/zabbix-timescaledb.yml
```

The role discovers expected hypertables from:

```text
/usr/share/zabbix-sql-scripts/postgresql/timescaledb/schema.sql
```

Do not hard-code a release-specific hypertable list when the vendor script is available.

## Nginx and PHP

Before Zabbix frontend installation the generic Nginx baseline intentionally has no listener.

After Zabbix installation the expected application listeners are:

```text
8080   Zabbix frontend via Nginx
10050  Zabbix Agent 2
10051  Zabbix Server
```

PostgreSQL must not gain an external `:5432` listener.

Required services:

```text
nginx
php8.4-fpm
zabbix-server
zabbix-agent2
postgresql
alloy
```

## Locale requirement and recovery

### Symptom

The frontend may report:

```text
Locale for language "en_US" is not found on the web server.
Unable to translate Zabbix interface.
```

### Cause

The initial CT201 role generated only `en_GB.UTF-8`. Zabbix also expects `en_US.UTF-8` to be available to PHP.

### IaC authority

The `zabbix_server` role now manages both:

```text
en_GB.UTF-8
en_US.UTF-8
```

while preserving the UK system default:

```text
LANG=en_GB.UTF-8
LANGUAGE=en_GB:en
```

### Apply

From TestServer:

```bash
cd /home/james/projects/proxmox/ansible
export ANSIBLE_CONFIG=/home/james/projects/proxmox/ansible/ansible.cfg

ansible-playbook \
  -i inventories/zabbix-lxc/hosts.yml \
  playbooks/zabbix-server.yml \
  --limit zabbix-lxc-01 \
  --ask-vault-pass
```

### Validate

```bash
ssh -n root@192.168.2.184 '
set -e
locale -a | grep -qx "en_GB.utf8"
locale -a | grep -qx "en_US.utf8"
grep -qx "LANG=en_GB.UTF-8" /etc/default/locale
grep -qx "LANGUAGE=en_GB:en" /etc/default/locale
php -r '"'"'exit(setlocale(LC_ALL, "en_US.UTF-8") === false ? 1 : 0);'"'"'
systemctl is-active php8.4-fpm
systemctl is-active nginx
systemctl is-active zabbix-server
'
```

Re-run the Ansible play and require:

```text
changed=0
unreachable=0
failed=0
```

Do not treat a manual `locale-gen` command as durable closure.

## Frontend IaC and Geomap

Desired authority:

```text
Dashboard: Global view
Host:      Zabbix server
Location:  BH22 8QL, West Parley, Dorset, UK
Latitude:  50.79039
Longitude: -1.890218
Zoom:      15
```

Owned by:

```text
ansible/roles/zabbix_frontend_iac/
ansible/playbooks/zabbix-frontend-iac.yml
```

### Admin credential bootstrap

The factory/default `Admin` credential is not retained as BAU authority.

A unique credential is stored only in encrypted CT201 Ansible Vault:

```text
ansible/inventories/zabbix-lxc/group_vars/all/vault.yml
```

The frontend-IaC role performs a one-time controlled bootstrap when its marker is absent:

```text
documented recovery hash
  -> clear failed-login state
  -> API login using temporary recovery credential
  -> rotate Admin to Vault credential
  -> verify Vault credential
  -> write bootstrap marker
```

Subsequent runs skip recovery/rotation and verify the Vault-backed credential only.

The role owns its state directory:

```text
/var/lib/homelab-zabbix-frontend-iac/
├── admin-bootstrap-status
└── admin-bootstrap-v1
```

Do not assume `/var/lib/zabbix` exists. The Debian/Zabbix install on CT201 does not provide that directory.

Validated evidence:

```text
admin-bootstrap-status: result=PASS mode=verify
admin-bootstrap-v1: PRESENT
marker permissions: root:root 0600
Admin attempt_failed: 0
```

### Geomap application

The same frontend-IaC play applies the host inventory/location and Global view Geomap state.

First successful application:

```text
zabbix-lxc-01 : ok=10 changed=5 unreachable=0 failed=0
```

Second-run idempotence proof:

```text
zabbix-lxc-01 : ok=7 changed=0 unreachable=0 failed=0 skipped=3
```

The Geomap authority is therefore considered closed.

## Final acceptance

A production-equivalent CT201 configuration change is accepted only when applicable gates pass:

```text
systemd=running
failed_units=ZERO
postgresql=active
zabbix-server=active
zabbix-agent2=active
nginx=active
php8.4-fpm=active
alloy=active
frontend HTTP healthy
database listener remains localhost-only
Ansible second pass changed=0
OpenTofu detailed plan exit code=0
Git working tree clean
```

Final closure evidence:

```text
frontend_iac_changed=0
frontend_iac_failed=0
frontend_iac_unreachable=0
tofu_exit_code=0
tofu_drift=ZERO
```

## Safety rules

- Keep CT201 unprivileged.
- Keep nesting declared in OpenTofu.
- Do not reuse retired VM101 credentials, IP or MAC.
- Do not expose PostgreSQL beyond localhost without a separately reviewed requirement.
- Do not print/decrypt secrets into logs.
- Do not recreate PostgreSQL or CT201 to recover an application credential.
- Do not run the TimescaleDB conversion blindly after it is already complete.
- Use `ssh -n` inside stdin/heredoc-fed scripts.
- Prefer Ansible fixes over manual guest mutation.
