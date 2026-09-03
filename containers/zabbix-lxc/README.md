# Zabbix LXC

This project builds the first native Proxmox LXC application workload in the homelab using OpenTofu for infrastructure and Ansible for operating-system and application configuration.

## Current validated state — 3 September 2026

CT201 is live and healthy.

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

Validated application endpoint:

```text
http://192.168.2.184:8080/
```

Validated state:

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
ansible_idempotence=PASS
```

Pre-TimescaleDB-conversion rollback dump retained on CT201:

```text
/var/backups/zabbix/zabbix-pre-timescaledb-20260903-230800.dump
```

## Target identity

- Proxmox node: `PROXMOX`
- CT ID: `201`
- Hostname: `zabbix-lxc-01`
- IPv4: `192.168.2.184` (DHCP commissioning address)
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

The credential file remains outside Git.

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
| Locale correction | en_GB + en_US availability for PHP/Zabbix | COMPLETE |
| Frontend IaC / BH22 8QL Geomap | Admin/API credential prerequisite | DEFERRED |

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

The TimescaleDB conversion role reads the expected hypertables from the installed Zabbix vendor schema instead of hard-coding a release-specific list.

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

Do not fix missing Zabbix locales manually. Re-run the `zabbix_server` role and validate PHP locale availability.

## Frontend IaC target

The desired Geomap authority is already in Git:

```text
Dashboard: Global view
Host:      Zabbix server
Location:  BH22 8QL, West Parley, Dorset, UK
Latitude:  50.79039
Longitude: -1.890218
Zoom:      15
```

Application of that state is deferred until the Zabbix `Admin` API credential is recovered/rotated and stored securely in Ansible Vault.

Current diagnostic evidence on 3 September 2026:

```text
Admin user exists
failed API login attempts observed: 4
source: 192.168.2.220 (TestServer)
```

Do not continue guessing credentials. The next safe action is controlled Admin credential recovery/rotation, Vault storage, API login proof, then frontend-IaC application and a `changed=0` second pass.

## Acceptance gates

A completed CT201 change should preserve:

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
Ansible second pass changed=0
OpenTofu plan exit code=0
repository clean
```

Secrets must never be printed, committed or left in plaintext files in the repository.
