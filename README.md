# Proxmox Homelab Platform

This repository tracks the build, configuration, migration, and operational runbooks for the Proxmox homelab platform.

## Current host

- **Platform:** HP ProDesk 400 G4 DM
- **CPU:** Intel Core i5-8500T, 6 cores / 6 threads
- **Virtualisation:** Intel VT-x
- **RAM:** 8 GB DDR4-2667, Samsung M471A1K43DB1-CTD, one module installed
- **Primary storage:** 256 GB WDC PC SN520 NVMe (`WDC PC SN520 SDAPNUW-256G-1006`)
- **Proxmox VE:** 9.2.0
- **pve-manager:** 9.2.11
- **Kernel:** 7.0.14-14-pve
- **Management bridge:** `vmbr0`
- **Management IP:** `192.168.2.70/24`
- **Gateway:** `192.168.2.1`

## Build status

- [x] Proxmox VE installed
- [x] Enterprise PVE repository disabled
- [x] Enterprise Ceph repository disabled
- [x] `pve-no-subscription` repository enabled
- [x] Initial package update completed
- [x] Headless reboot test passed
- [x] Hardware and network baseline captured
- [ ] NVMe SMART/health review
- [ ] BIOS / firmware inventory
- [ ] Host security baseline
- [ ] Monitoring integration
- [ ] Backup destination and restore test
- [ ] Test Debian VM
- [ ] Production workload migration

## Target architecture

The Proxmox host will become the main x86 compute platform. DNS remains independent on Raspberry Pi infrastructure, and IDS/security remains separate on `ids-01`.

Planned workloads include a Debian Docker VM, Home Assistant OS VM, and future test/lab VMs.

See `docs/build-log.md` for the chronological implementation record.
