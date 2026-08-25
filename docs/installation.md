# Proxmox Host Installation and Validation Guide

This document records the installation procedure for the HP ProDesk 400 G4 DM homelab host and provides a repeatable bootstrap/validation checklist.

It intentionally covers the physical Proxmox host only. VM creation and application deployment will be managed through Infrastructure as Code after the host bootstrap is complete.

## 1. Hardware baseline

| Component | Value |
|---|---|
| Host | HP ProDesk 400 G4 DM |
| CPU | Intel Core i5-8500T @ 2.10 GHz |
| Cores / threads | 6 / 6 |
| Current RAM | 8 GB DDR4-2667 |
| Installed RAM module | Samsung `M471A1K43DB1-CTD` |
| Planned RAM target | 32 GB, 2 x 16 GB DDR4 SO-DIMM |
| Primary drive | WDC PC SN520 256 GB NVMe |
| NVMe model | `WDC PC SN520 SDAPNUW-256G-1006` |
| NIC | Integrated Gigabit Ethernet |
| Management IP | `192.168.2.70/24` |
| Gateway | `192.168.2.1` |
| Current DNS | `192.168.2.48` |
| Search domain | `jameshouse` |

## 2. Installation prerequisites

Before installation:

- Confirm there is no data on the target SSD that must be retained.
- Connect the ProDesk to the wired LAN.
- Temporarily connect a monitor and keyboard.
- Download the current supported Proxmox VE 9.x ISO for x86-64.
- Write the ISO to a USB device as a bootable image; do not simply copy the ISO file to the USB filesystem.
- Ensure reliable mains power during installation.
- Record the planned management address and confirm that it is not already in use.

The machine will run headlessly after bootstrap, but a local console is recommended for the initial installation and firmware work.

## 3. BIOS / UEFI prerequisites

The host has already been validated with:

- Intel VT-x enabled.
- Intel VT-d/IOMMU enabled.
- UEFI boot.

Current firmware baseline:

```text
HP Q23 Ver. 02.07.00
Release date: 2019-04-12
```

A controlled update to the latest supported HP Q23 firmware is planned. Use only firmware obtained for the exact HP ProDesk 400 G4 Desktop Mini platform.

After any BIOS update, re-check VT-x and VT-d because firmware updates can reset settings.

## 4. Booting the installer

1. Insert the bootable Proxmox USB device.
2. Power on the HP.
3. Press `Esc` repeatedly to open the HP Startup Menu.
4. Select `F9` for Boot Device Options.
5. Select the UEFI USB device.
6. Start the Proxmox VE graphical installer.

If the USB does not appear, verify that it was written as a bootable image and that USB boot is enabled in firmware.

## 5. Proxmox installation choices

Install Proxmox directly to the existing NVMe drive.

Use:

```text
Hostname:        PROXMOX
Management IP:   192.168.2.70/24
Gateway:         192.168.2.1
DNS:             192.168.2.48 initially
Timezone:        Europe/London
```

Use a strong root password and a valid administrative email address.

The original installation created the following disk layout:

```text
nvme0n1  238.5G  WDC PC SN520 SDAPNUW-256G-1006
├─ nvme0n1p1  1007K
├─ nvme0n1p2     1G  vfat
└─ nvme0n1p3  237.5G  LVM2_member
   ├─ pve-swap      7.6G
   ├─ pve-root     69.5G  ext4
   └─ pve-data    141.5G
```

## 6. First remote login

After installation and reboot, connect from another LAN computer:

```text
https://192.168.2.70:8006
```

A browser warning for the initial self-signed certificate is expected.

Login using the Linux PAM realm:

```text
User:  root
Realm: Linux PAM standard authentication
```

SSH should also be available on port 22.

## 7. Repository configuration

For this homelab host, the subscription-only repositories were disabled and `pve-no-subscription` was enabled.

In the Proxmox GUI:

1. Select the node.
2. Open **Updates -> Repositories**.
3. Disable the PVE Enterprise repository.
4. Disable the Ceph Enterprise repository.
5. Keep Debian Trixie and Debian security repositories enabled.
6. Add/enable the Proxmox VE no-subscription repository.

The resulting intent is:

- Debian Trixie: enabled.
- Debian security: enabled.
- `pve-no-subscription`: enabled.
- PVE Enterprise: disabled.
- Ceph Enterprise: disabled.

## 8. Initial update

Refresh package information and apply all available updates using the Proxmox GUI or the normal Debian/Proxmox package-management workflow.

After the first update, reboot the host and prove that it returns to service without a local monitor or keyboard.

Current validated software baseline:

```text
proxmox-ve:       9.2.0
pve-manager:      9.2.11
kernel:           7.0.14-14-pve
OS:               Debian GNU/Linux 13 (trixie)
```

## 9. Network configuration

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

An ASUS DHCP reservation has also been created for `192.168.2.70` using the physical NIC MAC address so that DHCP cannot allocate the management address to another client.

Verify link state:

```bash
ethtool nic0 | grep -E 'Speed:|Duplex:|Link detected:'
```

Expected baseline:

```text
Speed: 1000Mb/s
Duplex: Full
Link detected: yes
```

## 10. DNS and time baseline

Current resolver configuration:

```text
search jameshouse
nameserver 192.168.2.48
```

The target design will later provide two independent Pi-hole/Unbound resolvers outside Proxmox.

Verify time synchronisation:

```bash
timedatectl
chronyc tracking
chronyc sources -v
```

Expected result:

- `System clock synchronized: yes`
- NTP service active.
- Chrony has a valid selected source.
- RTC remains UTC (`RTC in local TZ: no`).

## 11. Hardware inventory

Use the following read-only inventory block after installation:

```bash
echo "===== PROXMOX ====="
pveversion -v

echo
echo "===== SYSTEM ====="
dmidecode -t system | grep -E 'Manufacturer:|Product Name:|Version:'

echo
echo "===== CPU ====="
lscpu | grep -E 'Model name|Socket|Core|Thread|Virtualization'

echo
echo "===== MEMORY ====="
dmidecode -t memory | grep -E 'Memory Device|Size:|Type:|Speed:|Manufacturer:|Part Number:' | grep -v 'No Module'

echo
echo "===== STORAGE ====="
lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL,SERIAL

echo
echo "===== SMART DEVICES ====="
smartctl --scan

echo
echo "===== NETWORK ====="
ip -br addr
ip route

echo
echo "===== PROXMOX NETWORK CONFIG ====="
cat /etc/network/interfaces
```

Do not commit serial numbers, machine UUIDs, credentials, or other unnecessary unique device identifiers to the public repository.

## 12. NVMe SMART validation

Check the NVMe with:

```bash
smartctl -a /dev/nvme0
```

Recorded baseline on 2026-08-25:

| SMART value | Baseline |
|---|---:|
| Overall health | PASSED |
| Temperature | 45 C |
| Available spare | 100% |
| Percentage used | 6% |
| Data read | 15.3 TB |
| Data written | 17.7 TB |
| Power-on hours | 4,955 |
| Power cycles | 818 |
| Unsafe shutdowns | 103 |
| Media/data-integrity errors | 0 |
| Error-log entries | 0 |

The value `103` unsafe shutdowns is treated as a historical baseline. Any increase should be investigated.

The existing 256 GB NVMe is acceptable for host bootstrap and initial testing. Capacity/endurance will be reviewed before storage-heavy services such as Loki and Prometheus are migrated.

## 13. Virtualisation validation

Validate VT-x:

```bash
lscpu | grep -E 'Virtualization'
```

Expected:

```text
Virtualization: VT-x
```

Validate VT-d/IOMMU:

```bash
dmesg | grep -Ei 'DMAR|IOMMU'
```

The current host has confirmed:

- DMAR tables detected.
- IRQ remapping enabled.
- IOMMU default domain type `Translated`.
- Devices assigned to IOMMU groups.
- `Intel(R) Virtualization Technology for Directed I/O` active.

This proves the host is ready for normal KVM virtualisation and has the platform foundation for future device passthrough.

## 14. Thermal baseline

The kernel already exposes hardware temperature data.

Read thermal zones:

```bash
for z in /sys/class/thermal/thermal_zone*; do
    [ -e "$z/temp" ] || continue
    echo "$(cat "$z/type" 2>/dev/null): $(awk '{printf "%.1f C\n",$1/1000}' "$z/temp")"
done
```

Recorded idle baseline:

```text
CPU package:       ~40 C
PCH / Cannon Lake: ~46 C
NVMe:              ~45 C
```

These values are healthy for the current idle host.

## 15. Service and port baseline

Check for failed units:

```bash
systemctl --failed
```

Baseline: zero failed units.

Inventory listening sockets:

```bash
ss -lntup
```

Known initial services include:

| Port | Service / purpose |
|---:|---|
| 22/tcp | SSH |
| 8006/tcp | Proxmox web/API proxy |
| 3128/tcp | Proxmox SPICE proxy |
| 85/tcp localhost | Proxmox internal API daemon |
| 25/tcp localhost | local mail service |
| 111/tcp+udp | rpcbind; review during hardening |
| 9100/tcp | Prometheus node_exporter |

Port 111 is not to be disabled blindly; its requirement will be reviewed during the security-hardening phase.

## 16. Prometheus node_exporter

Current package:

```text
prometheus-node-exporter 1.9.0-1+b4
```

It is enabled and listening on port 9100.

Validate:

```bash
systemctl status prometheus-node-exporter --no-pager
curl -s http://127.0.0.1:9100/metrics | head
```

Thermal metrics are already exported, including:

```text
node_hwmon_temp_celsius{chip="nvme_nvme0",...}
node_hwmon_temp_celsius{chip="platform_coretemp_0",...}
node_hwmon_temp_celsius{chip="thermal_thermal_zone0",...}
```

The next monitoring step is to add:

```text
192.168.2.70:9100
```

to the existing central Prometheus scrape configuration, then confirm the target is `UP` and expose it in Grafana.

## 17. Headless acceptance test

A headless reboot is mandatory before treating the host as ready.

Procedure:

1. Confirm the Proxmox GUI is reachable.
2. Reboot cleanly.
3. Do not use the local monitor/keyboard.
4. Wait for network recovery.
5. Confirm ping/SSH/web UI return.
6. Confirm Proxmox services are healthy.

**Current result: PASSED.**

## 18. Post-install gate

The physical host is considered bootstrapped when all of the following are true:

- [x] Proxmox installed.
- [x] Repositories configured.
- [x] Initial updates applied.
- [x] Headless reboot passed.
- [x] Static management IP configured.
- [x] DHCP reservation configured.
- [x] 1 Gbit/s full-duplex link verified.
- [x] NTP/time sync verified.
- [x] VT-x verified.
- [x] VT-d/IOMMU verified.
- [x] NVMe SMART baseline recorded.
- [x] Thermal baseline recorded.
- [x] Listening ports inventoried.
- [x] node_exporter endpoint validated.
- [ ] HP Q23 firmware review/update completed.
- [ ] Monitoring integrated with central Prometheus/Grafana.
- [ ] Host security baseline accepted.
- [ ] External backup destination selected and restore tested.

No production workload migration should begin until the remaining readiness gates are complete.

## 19. What is deliberately not installed manually

Do not manually build production VMs through the Proxmox GUI once the IaC foundation exists.

The planned model is:

- OpenTofu/Terraform for VM infrastructure.
- cloud-init for first-boot bootstrap.
- Ansible for OS configuration.
- Docker Compose for container applications.
- Jenkins for CI/CD automation after the manual workflow is proven.

The GUI remains appropriate for observation, troubleshooting, console access, and emergency recovery.

## 20. Related documentation

- `README.md` - platform overview and current hardware/software state.
- `docs/build-log.md` - chronological record of changes actually performed.
- `docs/project-plan.md` - full migration, IaC, Jenkins, DNS, backup and workload plan.
