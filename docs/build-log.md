# Proxmox Build Log

## 2026-08-25 — Initial platform build

### Host

- HP ProDesk 400 G4 DM
- Intel Core i5-8500T @ 2.10 GHz
- 6 cores / 6 threads
- Intel VT-x detected
- 8 GB DDR4 RAM
- Samsung `M471A1K43DB1-CTD`, 2667 MT/s
- One memory module detected; second memory device reports no installed size
- 256 GB WDC PC SN520 NVMe (`WDC PC SN520 SDAPNUW-256G-1006`)

### Proxmox

- `proxmox-ve: 9.2.0`
- `pve-manager: 9.2.11`
- Running kernel: `7.0.14-14-pve`
- Initial update completed successfully
- Host rebooted and returned to service headlessly

### Repository configuration

- Disabled PVE Enterprise repository
- Disabled Ceph Enterprise repository
- Enabled `pve-no-subscription`
- Debian Trixie and Debian security repositories remain enabled

### Storage layout

Current NVMe layout:

```text
nvme0n1  238.5G  WDC PC SN520 SDAPNUW-256G-1006
├─ nvme0n1p1  1007K
├─ nvme0n1p2     1G  vfat
└─ nvme0n1p3  237.5G  LVM2_member
   ├─ pve-swap      7.6G
   ├─ pve-root     69.5G  ext4
   └─ pve-data    141.5G
```

SMART tooling detects the drive as `/dev/nvme0`.

### Networking

- Physical interface: `nic0`
- Proxmox bridge: `vmbr0`
- Static management address: `192.168.2.70/24`
- Default gateway: `192.168.2.1`

Current `/etc/network/interfaces`:

```text
auto lo
iface lo inet loopback

iface nic0 inet manual

auto vmbr0
iface vmbr0 inet static
        address 192.168.2.70/24
        gateway 192.168.2.1
        bridge-ports nic0
        bridge-stp off
        bridge-fd 0
```

### Acceptance tests completed

- Proxmox web administration reachable after installation
- Package update completed
- Reboot completed successfully
- Host returned to service without local monitor or keyboard
- Hardware and network inventory captured

### Next actions

1. Check full NVMe SMART / health data.
2. Capture BIOS and firmware versions.
3. Confirm DNS configuration and management IP reservation.
4. Establish host monitoring.
5. Establish security baseline and vulnerability scanning.
6. Decide external backup destination before production migration.
7. Build a disposable Debian VM and prove backup/restore.
