# Proxmox Homelab Platform

This repository tracks the build, configuration, migration, and operational runbooks for the Proxmox homelab platform.

**Project status:** host bootstrap is complete and hardware/storage preparation is active. No production workloads have been migrated. New infrastructure will be built Infrastructure-as-Code first.

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
| Secondary SSD current state | Not yet provisioned in Proxmox | Existing NTFS partition remains until deliberate wipe/provisioning step is completed |
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
- [ ] Wipe legacy NTFS filesystem from Kingston SSD
- [ ] Provision Kingston SSD as dedicated Proxmox VM/LXC storage
- [ ] Review/update HP BIOS firmware
- [ ] Add Proxmox target to central Prometheus/Grafana
- [ ] Host security baseline
- [ ] Backup destination and restore test
- [ ] IaC foundation
- [ ] Disposable IaC Debian VM proof
- [ ] Jenkins IaC integration
- [ ] Production workload migration

## Storage design

The current storage plan is to keep the 256 GB NVMe as the Proxmox system/local storage device and use the 480 GB Kingston SATA SSD as a separate VM/LXC storage tier.

```text
256 GB WDC NVMe
├── Proxmox OS
├── local
└── local-lvm

480 GB Kingston A400 SATA SSD
└── planned dedicated VM/LXC storage
```

The secondary SSD will not be used as the only backup location. Proxmox backups must ultimately be stored outside the host.

## Target architecture

The Proxmox host will become the main x86 compute platform. DNS remains independent on Raspberry Pi infrastructure, and IDS/security remains separate on `ids-01`.

Planned workloads include a Debian Docker VM, Home Assistant OS VM, and future test/lab VMs.

## Documentation

- [`docs/project-plan.md`](docs/project-plan.md) — full project plan, IaC model, Jenkins integration, migration gates, DNS resilience, backup/DR and acceptance criteria.
- [`docs/installation.md`](docs/installation.md) — physical host installation, repository setup, networking, validation commands, SMART/thermal/virtualisation baselines and post-install gates.
- [`docs/build-log.md`](docs/build-log.md) — chronological implementation record of changes performed on the live host.
- [`runbooks/linux-monitoring-grafana.md`](runbooks/linux-monitoring-grafana.md) — standard Linux host onboarding procedure for node_exporter, Prometheus, Grafana dashboards, alerting, acceptance testing and rollback.
- [`runbooks/alloy-install.md`](runbooks/alloy-install.md) — standard Grafana Alloy installation, Loki log shipping, validation, security, troubleshooting, rollback and future Ansible automation procedure.
