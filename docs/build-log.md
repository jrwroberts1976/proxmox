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
- ASUS DHCP reservation for `192.168.2.70`: **configured**

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
- Static management address protected by ASUS DHCP reservation

---

## 2026-08-26 — Secondary SSD installation and validation

### Physical installation

A second SSD was installed in the HP ProDesk and detected by Proxmox as:

```text
/dev/sda
KINGSTON SA400S37480G
480 GB raw capacity / 447.1 GiB visible capacity
SATA 3.2, 6.0 Gb/s
```

The Proxmox system disk remains the existing WDC PC SN520 NVMe (`/dev/nvme0n1`).

### Existing disk state

At detection, the Kingston contained one legacy NTFS partition:

```text
/dev/sda1  447.1G  ntfs  LABEL="New Volume"
```

Validation confirmed:

- `/dev/sda1` was not mounted.
- `/dev/sda` was not an LVM physical volume.
- Existing Proxmox volume group `pve` remained solely on `/dev/nvme0n1p3`.
- Existing Proxmox storage remained `local` and `local-lvm` only.

The legacy NTFS filesystem has not yet been recorded as wiped; destruction/provisioning is intentionally treated as a separate controlled step.

### Kingston SMART baseline

Device: `KINGSTON SA400S37480G`

- SMART overall health: **PASSED**
- Firmware: `SBFKB1C3`
- SATA negotiated speed: **6.0 Gb/s**
- SMART support: enabled
- Power-on hours at baseline: **11,386**
- Power cycles: **4,307**
- Temperature during initial validation: **28–30 C**
- Lifetime host writes: approximately **10,047 GiB**
- Lifetime reads: approximately **14,669 GiB**
- Program fail count: **0**
- Erase fail count: **0**
- SATA CRC error count: **0**
- Historical reported uncorrectable count: **1**
- Historical reallocated event count: **1**
- Historical unsafe shutdown count: **125**

The SMART life attribute is consistent with approximately 94% life remaining / 6% life consumed for this Phison-driven Kingston SSD.

### Extended SMART self-test

An extended offline SMART self-test was run against `/dev/sda` and completed successfully:

```text
Extended offline    Completed without error    00%
LBA_of_first_error: -
```

Post-test SMART overall health remained **PASSED**.

### Storage decision

Current target design:

```text
256 GB WDC NVMe
├── Proxmox OS
├── local
└── local-lvm

480 GB Kingston A400 SATA SSD
└── planned dedicated VM/LXC storage
```

The second SSD will not be treated as the sole backup location. Backup storage must remain external to the Proxmox host.

### Next actions

1. Deliberately wipe the legacy NTFS signature/partition from `/dev/sda` after final confirmation.
2. Provision the Kingston as dedicated Proxmox VM/LXC storage with clear storage/VG naming.
3. Record the resulting storage layout and validate it in `pvesm status`.
4. Review/update HP Q23 BIOS when the maintenance window allows.
5. Add Proxmox node exporter target to central Prometheus/Grafana.
6. Continue host security and backup/restore design before production migration.
