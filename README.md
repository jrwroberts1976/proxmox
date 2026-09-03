# Proxmox Homelab Platform

This repository tracks the build, configuration, migration, and operational runbooks for the Proxmox homelab platform.

**Project status:** host bootstrap and dedicated VM storage preparation are complete. The OpenTofu IaC foundation is now proven: Debian 13 template VM `9000` exists on `vm-ssd`, the earlier disposable VM proof is preserved separately, and application-platform VM `101` has been created from a reviewed saved OpenTofu plan and intentionally left stopped for guest commissioning. No production workloads have been migrated.

## Hardware

| Component | Current specification | Notes |
|---|---|---|
| Host | HP ProDesk 400 G4 DM | Desktop Mini form factor |
| CPU | Intel Core i5-8500T @ 2.10 GHz | 6 cores / 6 threads |
| Virtualisation | Intel VT-x + VT-d / IOMMU | Both validated as enabled and active |
| RAM | 8 GB DDR4-2667 | 1 × 8 GB Samsung `M471A1K43DB1-CTD`; second slot available |
| RAM target | 32 GB DDR4 | Planned 2 × 16 GB SO-DIMM upgrade |
| Primary storage | 256 GB WDC PC SN520 NVMe | Model `WDC PC SN520 SDAPNUW-256G-1006`; Proxmox system disk |
| NVMe health | SMART PASSED | 6% used, 100% spare, 0 media/data integrity errors |
| NVMe baseline temperature | 45 C | Warning threshold 82 C; critical threshold 86 C |
| NVMe data written | 17.7 TB | Baseline captured 2026-08-25 |
| NVMe unsafe shutdowns | 103 | Historical baseline; monitor for increases |
| Secondary storage | 480 GB Kingston A400 SATA SSD | `KINGSTON SA400S37480G`; detected as `/dev/sda` |
| Secondary SSD health | SMART PASSED | Extended offline self-test completed without error |
| Secondary SSD baseline temperature | 28–30 C | Healthy baseline during validation |
| Secondary SSD lifetime | 11,387 power-on hours | ~10 TB lifetime host writes; historical 125 unsafe shutdowns |
| Secondary SSD current state | Provisioned as Proxmox `vm-ssd` LVM-thin storage | VG `vg_vm_ssd`, thin pool `thinpool`; 424.56 GiB VM/LXC pool with ~22.36 GiB VG reserve |
| BIOS | HP Q23 Ver. 02.07.00 | Released 2019-04-12; firmware update deferred and still planned |
| NIC | Integrated Gigabit Ethernet | Proxmox interface `nic0`; 1 Gbit/s full duplex validated |
| Management bridge | `vmbr0` | Bridged to `nic0` |
| Management IP | `192.168.2.70/24` | Static and protected by ASUS DHCP reservation |
| Gateway | `192.168.2.1` | ASUS router |
| DNS | `192.168.2.48` | Current resolver; resilient second DNS planned |

## Software baseline

| Component | Version / configuration |
|---|---|
| Proxmox VE | 9.2.0 |
| pve-manager | 9.2.11 |
| Kernel | `7.0.14-14-pve` |
| Operating system | Debian GNU/Linux 13 (trixie) |
| Repository | `pve-no-subscription` enabled |
| Enterprise repositories | PVE and Ceph Enterprise disabled |
| node_exporter | 1.9.0-1+b4 on port 9100 |
| OpenTofu | 1.12.6 on `TestServer` |
| Proxmox provider | `bpg/proxmox` 0.111.1 pinned |
| Headless operation | Reboot and remote-management test passed |

## Build status

- [x] Proxmox VE installed
- [x] Enterprise PVE repository disabled
- [x] Enterprise Ceph repository disabled
- [x] `pve-no-subscription` repository enabled
- [x] Initial package update completed
- [x] Headless reboot test passed
- [x] Hardware and network baseline captured
- [x] NVMe SMART/health review
- [x] BIOS / firmware inventory
- [x] DNS baseline captured
- [x] Management IP reservation configured
- [x] Intel VT-x validated
- [x] Intel VT-d / IOMMU validated
- [x] Thermal baseline captured
- [x] node_exporter endpoint and thermal metrics validated
- [x] Kingston 480 GB SATA SSD physically installed and detected
- [x] Kingston SSD SMART baseline captured
- [x] Kingston SSD extended SMART self-test passed
- [x] Wipe legacy NTFS filesystem from Kingston SSD
- [x] Provision Kingston SSD as dedicated Proxmox VM/LXC storage (`vm-ssd`)
- [x] Linux VM/PostgreSQL/TimescaleDB/Nginx deployment runbooks prepared
- [x] OpenTofu IaC foundation established and provider pinned
- [x] Least-privilege `iac@pve` API model validated for node, VM, bridge and `vm-ssd`
- [x] Disposable Debian IaC VM proof preserved as isolated VM `100` state/worktree
- [x] Debian 13 genericcloud source downloaded and SHA-512 verified
- [x] Reusable Debian 13 cloud-init template VM `9000` created on `vm-ssd`
- [x] Application-platform VM `101` created through reviewed saved OpenTofu plan
- [x] VM `101` left stopped after creation and template `9000` revalidated intact
- [ ] Start and commission VM `101`
- [ ] Reserve/approve final VM `101` network identity
- [ ] Hand VM `101` to Ansible Linux baseline
- [ ] Apply validated Linux security hardening to VM `101` and revalidate SSH/ICMP controls
- [ ] Re-run matching Greenbone checks after VM `101` hardening
- [ ] Review/update HP BIOS firmware
- [ ] Add Proxmox target to central Prometheus/Grafana
- [ ] Host security baseline
- [ ] Backup destination and restore test
- [ ] Jenkins IaC integration
- [ ] Production workload migration

## Current IaC objects

| VMID | Name | Role | Storage | State |
|---:|---|---|---|---|
| 100 | `debian-iac-test-01` | Earlier disposable OpenTofu proof | `local-lvm` | Managed by isolated legacy state/worktree |
| 9000 | `debian-13-cloud-template` | Debian 13 reusable cloud-init template | `vm-ssd` | Template, stopped |
| 101 | `app-platform-01` | First application-platform VM | `vm-ssd` | Created by OpenTofu, intentionally stopped |

## Storage design

The current storage layout keeps the 256 GB NVMe as the Proxmox system/local storage device and uses the 480 GB Kingston SATA SSD as a separate LVM-thin VM/LXC storage tier.

```text
256 GB WDC NVMe
├── Proxmox OS
├── local
└── local-lvm

480 GB Kingston A400 SATA SSD (/dev/sda)
└── vg_vm_ssd
    ├── thinpool (~424.56 GiB)
    │   └── Proxmox storage ID: vm-ssd
    │       └── content: VM images + LXC root disks
    └── ~22.36 GiB VG free reserve
```

`vm-ssd` was provisioned and validated on 2026-08-31 and reported `active` in `pvesm status` with 0% data usage immediately after creation.

The secondary SSD is not used as the only backup location. Proxmox backups must ultimately be stored outside the host.

## Target architecture

The Proxmox host will become the main x86 compute platform. DNS remains independent on Raspberry Pi infrastructure, and IDS/security remains separate on `ids-01`.

`TestServer` is the Proxmox **IaC control node and automation runner**. OpenTofu and Ansible are executed from TestServer to create and configure Proxmox workloads. It is not currently an enforced bastion/jump host; that would require separate network access controls. See [`docs/control-node-architecture.md`](docs/control-node-architecture.md) for the management architecture, ownership boundaries, provisioning flow, CT201 example, and future bastion option.

Planned workloads include a Debian Docker VM, Home Assistant OS VM, and future test/lab VMs.

## Initial application-platform build sequence

The first IaC application-platform proof follows these controlled gates in order:

```text
Linux VM IaC deployment
        |
        v
Guest commissioning / cloud-init acceptance
        |
        v
Linux security hardening
        |
        v
Observability / baseline acceptance
        |
        v
PostgreSQL
        |
        v
TimescaleDB
        |
        v
Nginx
```

Security hardening is a required build gate, not an optional post-install activity. The validated Ansible role removes the two weak UMAC-64 SSH MAC algorithms and blocks IPv4 ICMP timestamp requests while preserving normal SSH and ping. PostgreSQL must not be installed until the hardening and security-validation gates pass.

Each component has its own validation, idempotence, acceptance and rollback gates. The first deployment remains disposable until backup/recovery and observability gates are passed.

## Documentation

- [`docs/control-node-architecture.md`](docs/control-node-architecture.md) — defines TestServer as the IaC control node/automation runner, distinguishes it from a bastion host, and documents the GitHub → TestServer → OpenTofu/Ansible → Proxmox/guest management flow.
- [`docs/project-plan.md`](docs/project-plan.md) — full project plan, IaC model, Jenkins integration, migration gates, DNS resilience, backup/DR and acceptance criteria.
- [`docs/installation.md`](docs/installation.md) — physical host installation, repository setup, networking, validation commands, SMART/thermal/virtualisation baselines and post-install gates.
- [`docs/build-log.md`](docs/build-log.md) — chronological implementation record of changes performed on the live host.
- [`docs/debian13-template-vm101-opentofu.md`](docs/debian13-template-vm101-opentofu.md) — exact Debian 13 template `9000` and OpenTofu VM `101` build, API permissions, state separation, saved-plan review/apply and validation procedure.
- [`runbooks/linux-vm-iac-deployment.md`](runbooks/linux-vm-iac-deployment.md) — deploy a Debian 13 Proxmox VM through OpenTofu/Terraform, cloud-init and the `vm-ssd` storage tier, then hand it to Ansible.
- [`runbooks/linux-vm-security-hardening.md`](runbooks/linux-vm-security-hardening.md) — mandatory VM build security gate using the validated Ansible SSH UMAC-64 and ICMP timestamp controls, including validation, idempotence, Greenbone closure and rollback.
- [`runbooks/postgresql-install.md`](runbooks/postgresql-install.md) — deploy and validate the repository PostgreSQL Ansible role, database/users, access controls, idempotence and rollback gates.
- [`runbooks/timescaledb-install.md`](runbooks/timescaledb-install.md) — deploy TimescaleDB on PostgreSQL, validate preload/extension/hypertables, and control tuning/upgrades.
- [`runbooks/nginx-install.md`](runbooks/nginx-install.md) — deploy Nginx sites/reverse proxies through Ansible with configuration testing, exposure/security and rollback gates.
- [`runbooks/linux-monitoring-grafana.md`](runbooks/linux-monitoring-grafana.md) — standard Linux host onboarding procedure for node_exporter, Prometheus, Grafana dashboards, alerting, acceptance testing and rollback.
- [`runbooks/alloy-install.md`](runbooks/alloy-install.md) — standard Grafana Alloy installation, Loki log shipping, validation, security, troubleshooting, rollback and future Ansible automation procedure.
- [`runbooks/alloy-linux-monitoring.md`](runbooks/alloy-linux-monitoring.md) — enable Linux host metrics with Alloy `prometheus.exporter.unix`, Prometheus remote write, Grafana validation and alerting.
- [`runbooks/prometheus-install.md`](runbooks/prometheus-install.md) — deploy the central Prometheus service, persistent TSDB, remote-write receiver, validation and Grafana integration.
- [`runbooks/loki-install.md`](runbooks/loki-install.md) — deploy the central Loki log store, persistent storage, Alloy ingestion path and Grafana integration.
- [`runbooks/linux-vm-observability-bootstrap.md`](runbooks/linux-vm-observability-bootstrap.md) — standard metrics + logs commissioning procedure for every new Linux VM.
- [`ansible/linux-security-hardening/README.md`](ansible/linux-security-hardening/README.md) — validated Ansible implementation for OpenSSH UMAC-64 removal and persistent ICMP timestamp-request blocking on Debian/Proxmox hosts.
