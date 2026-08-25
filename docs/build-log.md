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

### NVMe SMART baseline

- SMART overall health: **PASSED**
- Critical warning: `0x00`
- Temperature: **45 C**
- Available spare: **100%**
- Percentage used: **6%**
- Data read: **15.3 TB**
- Data written: **17.7 TB**
- Power-on hours: **4,955**
- Power cycles: **818**
- Unsafe shutdowns: **103**
- Media/data integrity errors: **0**
- Error log entries: **0**
- No warning or critical temperature time recorded

Assessment: drive health is currently good. The existing 256 GB NVMe is suitable for platform build and testing. Capacity/endurance should be reviewed before migrating storage-heavy services such as Loki and Prometheus. The historic unsafe-shutdown count should be treated as a baseline and monitored for any increase.

### BIOS / firmware baseline

- Vendor: HP
- BIOS: `Q23 Ver. 02.07.00`
- Release date: `2019-04-12`

The BIOS is substantially older than the current platform software and should be checked against HP's latest supported firmware before production migration. No firmware change has yet been made.

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

### DNS baseline

Current resolver configuration:

```text
search jameshouse
nameserver 192.168.2.48
```

The Proxmox host currently relies on one DNS server (`192.168.2.48`). The target architecture will use two independent Pi-hole/Unbound DNS servers. Host DNS configuration should be revisited once the resilient pair is in place.

### Acceptance tests completed

- Proxmox web administration reachable after installation
- Package update completed
- Reboot completed successfully
- Host returned to service without local monitor or keyboard
- Hardware and network inventory captured
- NVMe SMART health reviewed
- BIOS/firmware baseline captured
- DNS baseline captured

### Next actions

1. Confirm the router/DHCP reservation for `192.168.2.70` so it cannot be allocated to another client.
2. Check HP for a newer supported Q23 BIOS and plan a controlled firmware update if appropriate.
3. Establish host monitoring, including NVMe temperature/health and unsafe-shutdown counter.
4. Establish host security baseline and vulnerability scanning.
5. Decide external backup destination before production migration.
6. Build a disposable Debian VM and prove backup/restore.
7. Add the second independent DNS resolver before relying on the new platform for production services.
