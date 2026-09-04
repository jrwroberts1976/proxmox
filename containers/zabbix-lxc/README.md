# Zabbix LXC

This project is the first native Proxmox LXC application workload in the homelab. OpenTofu owns the container infrastructure; Ansible owns Debian and the application stack; Git is the configuration authority.

## Final validated state — 4 September 2026

CT201 is technically complete.

```text
Proxmox
└── CT201 — zabbix-lxc-01
    ├── Debian 13
    ├── PostgreSQL 17
    ├── TimescaleDB
    ├── Zabbix Server 7.0 LTS
    ├── Zabbix Agent 2
    ├── Nginx
    ├── PHP 8.4 FPM
    ├── Alloy
    └── unattended-upgrades
```

Application endpoint:

```text
http://192.168.2.184:8080/
```

Final acceptance evidence:

```text
CTID=201
hostname=zabbix-lxc-01
ipv4=192.168.2.184
unprivileged=YES
nesting=ENABLED
systemd=HEALTHY
failed_units=ZERO
postgresql_version=17
postgresql_cluster=ONLINE
postgresql_scope=LOCALHOST_ONLY
timescaledb_extension=ACTIVE
zabbix_timescaledb_schema=CONVERTED
vendor_hypertables=COMPLETE
zabbix_server=ACTIVE
zabbix_agent2=ACTIVE
zabbix_frontend=ACTIVE
nginx=ACTIVE
php_fpm=ACTIVE
alloy=HEALTHY
frontend_iac_idempotence=PASS
ansible_changed=0
ansible_failed=0
ansible_unreachable=0
tofu_exit_code=0
tofu_drift=ZERO
```

Pre-TimescaleDB-conversion rollback dump retained on CT201:

```text
/var/backups/zabbix/zabbix-pre-timescaledb-20260903-230800.dump
```

## Target identity

- Proxmox node: `PROXMOX`
- CT ID: `201`
- Hostname: `zabbix-lxc-01`
- IPv4: `192.168.2.184`
- OS: Debian 13
- Container type: unprivileged LXC
- LXC nesting: enabled
- CPU: 2 cores
- RAM: 4096 MB
- Swap: 1024 MB
- Root disk: 64 GB on `vm-ssd`
- Bridge: `vmbr0`
- DNS: `192.168.2.48`
- MAC: `02:5A:42:00:02:01`
- Start on Proxmox boot: yes

## Ownership model

```text
OpenTofu
  └── Proxmox CT201 infrastructure

Ansible
  └── Debian configuration and application stack

Git
  └── configuration authority and change history
```

TestServer is the IaC/control node. It runs OpenTofu and Ansible and connects to Proxmox and CT201.

Do not install Docker directly on the Proxmox host and do not manually mutate persistent CT201 configuration when the change belongs in OpenTofu or Ansible.

## OpenTofu root

Run CT201 infrastructure operations from:

```text
/home/james/projects/proxmox/containers/zabbix-lxc
```

This is a dedicated OpenTofu root with state isolated from the retired VM101 workload.

Provider credentials are loaded from:

```text
/home/james/.config/homelab-iac/proxmox.env
```

The project pins:

```text
bpg/proxmox = 0.111.1
```

## Debian 13 nesting requirement

The Debian 13 template uses systemd 257. With nesting disabled, CT201 was created but standard mounts entered failed state.

OpenTofu therefore owns:

```hcl
features {
  nesting = true
}
```

CT201 remains unprivileged. Nesting is a declared requirement and must not be removed merely to suppress drift.

## Completed deployment stages

| Stage | Scope | State |
|---|---|---|
| 1 | LXC infrastructure and commissioning | COMPLETE |
| 2 | Linux hardening and unattended upgrades | COMPLETE |
| 3 | Alloy observability | COMPLETE |
| 4 | PostgreSQL 17 | COMPLETE |
| 5 | TimescaleDB extension/preload | COMPLETE |
| 6A | Nginx baseline | COMPLETE |
| 6B | Zabbix Server, Agent 2, PHP frontend and standard schema | COMPLETE |
| 6C | Zabbix TimescaleDB conversion | COMPLETE |
| Locale correction | `en_GB` + `en_US` availability for PHP/Zabbix | COMPLETE |
| 7A | Vault-backed Admin credential bootstrap/rotation | COMPLETE |
| 7B | BH22 8QL frontend/Geomap IaC | COMPLETE |
| 8 | Dedicated Grafana API identity + SOPS token authority | COMPLETE |
| 9 | Grafana Zabbix plugin/datasource integration | COMPLETE |
| Final gate | Ansible idempotence + OpenTofu zero drift | PASS |

## Database architecture

The accepted database order is:

```text
PostgreSQL 17 database/user
  -> TimescaleDB extension
  -> standard Zabbix PostgreSQL schema
  -> packaged Zabbix TimescaleDB conversion
  -> vendor-declared hypertable verification
```

PostgreSQL remains bound to localhost only.

The TimescaleDB conversion role reads expected hypertables from the installed Zabbix vendor schema instead of hard-coding a release-specific list.

## Locale requirement

Zabbix requires `en_US.UTF-8` to be available to the PHP frontend even when the server uses UK English.

Ansible manages both:

```text
en_GB.UTF-8
en_US.UTF-8
```

The host default remains:

```text
LANG=en_GB.UTF-8
LANGUAGE=en_GB:en
```

## Admin/API credential authority

The Zabbix `Admin` credential is no longer the factory/default password.

Ansible Vault contains the unique API/frontend credential:

```text
ansible/inventories/zabbix-lxc/group_vars/all/vault.yml
```

The frontend-IaC role performs one-time bootstrap/recovery only when its completion marker is absent. After bootstrap it verifies the Vault-backed credential and does not reset the account again.

Managed state is stored in:

```text
/var/lib/homelab-zabbix-frontend-iac/
├── admin-bootstrap-status
└── admin-bootstrap-v1
```

Final evidence:

```text
admin-bootstrap-status: result=PASS mode=verify
admin-bootstrap-v1: PRESENT
marker mode: root:root 0600
Admin attempt_failed: 0
```

The dedicated state directory is intentional. Debian's Zabbix packages on CT201 do not provide `/var/lib/zabbix`, so automation must not assume that path exists.

## BH22 8QL Geomap

Frontend IaC is complete.

```text
Dashboard: Global view
Host:      Zabbix server
Location:  BH22 8QL, West Parley, Dorset, UK
Latitude:  50.79039
Longitude: -1.890218
Zoom:      15
```

Second-run frontend-IaC proof:

```text
zabbix-lxc-01 : ok=7 changed=0 unreachable=0 failed=0 skipped=3
```

## Grafana integration

CT201 now exposes a dedicated read-only API identity for Grafana rather than using the administrative credential.

Managed Zabbix objects:

```text
role:       Grafana API Read Only
user group: Grafana Read Only
user:       grafana-zabbix
token:      grafana-datasource
```

The token is captured once into SOPS-encrypted authority in the `docker-env` repository and is not regenerated on normal Ansible reruns.

Final functional evidence from the Grafana container on `ids-01`:

```text
grafana_to_zabbix=PASS
proxmox_group_visibility=PASS
```

This proves the Grafana datasource can read Zabbix and see the `Infrastructure/Proxmox` host group. It does not yet mean the Proxmox VE host itself is enrolled in Zabbix; that remains a separate monitoring-backlog item.

See [`../../docs/zabbix-grafana-integration.md`](../../docs/zabbix-grafana-integration.md).

## Final OpenTofu gate

Final command:

```bash
cd /home/james/projects/proxmox/containers/zabbix-lxc
set -a
. /home/james/.config/homelab-iac/proxmox.env
set +a
tofu plan -input=false -detailed-exitcode
```

Final result:

```text
No changes. Your infrastructure matches the configuration.
tofu_exit_code=0
tofu_drift=ZERO
```

## Acceptance gates

A completed CT201 change must preserve:

```text
systemd=running
failed_units=ZERO
postgresql=active
zabbix-server=active
zabbix-agent2=active
nginx=active
php8.4-fpm=active
alloy=active
frontend HTTP=healthy
database listener=LOCALHOST_ONLY
Ansible second pass changed=0
OpenTofu plan exit code=0
repository clean
```

Secrets must never be printed, committed in plaintext or left in temporary repository files.
