# Proxmox Homelab Platform

This repository tracks the build, configuration, migration, and operational runbooks for the Proxmox homelab platform.

## Hardware

| Component | Current specification | Notes |
|---|---|---|
| Host | HP ProDesk 400 G4 DM | Desktop Mini form factor |
| CPU | Intel Core i5-8500T @ 2.10 GHz | 6 cores / 6 threads |
| Virtualisation | Intel VT-x + VT-d / IOMMU | Both validated as enabled and active |
| RAM | 8 GB DDR4-2667 | 1 × 8 GB Samsung `M471A1K43DB1-CTD`; second slot available |
| RAM target | 32 GB DDR4 | Planned 2 × 16 GB SO-DIMM upgrade |
| Primary storage | 256 GB WDC PC SN520 NVMe | Model `WDC PC SN520 SDAPNUW-256G-1006` |
| NVMe health | SMART PASSED | 6% used, 100% spare, 0 media/data integrity errors |
| NVMe baseline temperature | 45 C | Warning threshold 82 C; critical threshold 86 C |
| NVMe data written | 17.7 TB | Baseline captured 2026-08-25 |
| NVMe unsafe shutdowns | 103 | Historical baseline; monitor for increases |
| BIOS | HP Q23 Ver. 02.07.00 | Released 2019-04-12; firmware update review planned |
| NIC | Integrated Gigabit Ethernet | Proxmox interface `nic0` |
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
- [ ] Review/update HP BIOS firmware
- [ ] Host security baseline
- [ ] Monitoring integration
- [ ] Backup destination and restore test
- [ ] Test Debian VM
- [ ] Production workload migration

## Target architecture

The Proxmox host will become the main x86 compute platform. DNS remains independent on Raspberry Pi infrastructure, and IDS/security remains separate on `ids-01`.

Planned workloads include a Debian Docker VM, Home Assistant OS VM, and future test/lab VMs.

See `docs/build-log.md` for the chronological implementation record.
