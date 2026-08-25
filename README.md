# Proxmox Homelab Platform

This repository tracks the build, configuration, migration, and operational runbooks for the Proxmox homelab platform.

## Current host

- **Platform:** HP ProDesk 400 G4 DM
- **CPU:** Intel Core i5-8500T, 6 cores / 6 threads
- **Virtualisation:** Intel VT-x
- **RAM:** 8 GB DDR4-2667, Samsung M471A1K43DB1-CTD, one module installed
- **Primary storage:** 256 GB WDC PC SN520 NVMe (`WDC PC SN520 SDAPNUW-256G-1006`)
- **NVMe health:** SMART passed, 6% life used, 0 media/data integrity errors
- **NVMe temperature:** 45 C at baseline
- **BIOS:** HP Q23 Ver. 02.07.00, released 2019-04-12
- **Proxmox VE:** 9.2.0
- **pve-manager:** 9.2.11
- **Kernel:** 7.0.14-14-pve
- **Management bridge:** `vmbr0`
- **Management IP:** `192.168.2.70/24`
- **Gateway:** `192.168.2.1`
- **Current DNS resolver:** `192.168.2.48`
- **DNS search domain:** `jameshouse`

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
- [ ] Confirm management IP reservation
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
