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

---

## 2026-08-29 — OpenTofu foundation and disposable VM proof

### Host readiness before IaC

Before creating the first VM, the Proxmox host was revalidated:

- `pve-manager` remained `9.2.11`.
- Standalone-node state was expected; no Corosync cluster configuration exists.
- `local` and `local-lvm` remained healthy.
- Intel VT-x remained available.
- Time synchronisation remained healthy.
- `openipmi.service` was identified as irrelevant on this desktop-class host because no IPMI/BMC interface exists; it was disabled and the failed-service state cleared.
- Pending `libpve-apiclient-perl` and `libpve-storage-perl` updates were applied.
- Post-maintenance failed-service count was zero.

The Kingston SATA SSD extended SMART test had already passed. It remains suitable for future VM/application storage, but it is not an acceptable sole backup target.

### IaC API identity

Created dedicated Proxmox service account:

```text
iac@pve
```

Custom least-privilege roles were created for VM, storage and node operations and scoped to `/vms`, `local`, `local-lvm` and node `PROXMOX` rather than granting Administrator at `/`.

API token:

```text
iac@pve!opentofu
```

The permanent token secret is stored outside Git. The one-time temporary token JSON was removed after conversion to the protected environment file.

### OpenTofu control node

TestServer was selected as the manual control node so the hypervisor remains clean and Jenkins is not required for recovery.

Installed:

```text
OpenTofu v1.12.6 linux_arm64
```

Repository branch:

```text
iac/bootstrap-opentofu
```

The repository now contains state/secret exclusions and pins:

```text
bpg/proxmox = 0.111.1
```

`.terraform.lock.hcl` is committed; runtime state and credentials are excluded.

### Provider authentication proof

The provider credential file on TestServer is:

```text
/home/james/.config/homelab-iac/proxmox.env
```

Mode is `0600`, owned by `james`.

Only variable names are documented; the token value is not recorded in Git.

The first provider attempt showed that sourcing the file without export was insufficient. The working pattern uses `set -a`, sources the file, then restores normal shell export behaviour inside a subshell.

API authentication from TestServer was proven against Proxmox VE `9.2.11`.

### Pinned Debian image

The first VM uses the official Debian 13 trixie genericcloud amd64 image build `20260712-2537` with a pinned SHA-512 checksum.

The image resource downloaded successfully to:

```text
local:import/debian-13-genericcloud-amd64-20260712-2537.qcow2
```

### First VM-create permission failure

The first apply downloaded the image but VM creation failed cleanly with:

```text
Permission check failed (/sdn/zones/localnetwork/vmbr0, SDN.Use)
```

OpenTofu state contained only the downloaded image and Proxmox confirmed VM 100 did not exist, so rollback was not required.

A narrow `PVESDNUser` ACL was added specifically on:

```text
/sdn/zones/localnetwork/vmbr0
```

No broad Administrator role was granted.

### Disposable VM creation

OpenTofu then planned exactly:

```text
Plan: 1 to add, 0 to change, 0 to destroy.
```

Created:

```text
VM ID: 100
Name: debian-iac-test-01
CPU: 2 cores
RAM: 2048 MiB
Disk: 24 GiB local-lvm
Bridge: vmbr0
IPv4: DHCP
Cloud-init user: james
On boot: false
```

Apply result:

```text
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
```

The VM was left stopped for inspection.

Proxmox API validation confirmed the expected CPU, memory, disk, cloud-init drive, network bridge, tags and `onboot=0` state.

A subsequent OpenTofu plan returned:

```text
No changes. Your infrastructure matches the configuration.
```

### First IaC-controlled boot

The repository was changed from `started=false` to `started=true`, committed and pushed before mutation.

The saved plan contained only one in-place lifecycle change:

```text
Plan: 0 to add, 1 to change, 0 to destroy.
```

Apply completed successfully and VM 100 reached `status=running`.

VM start emitted a non-fatal warning:

```text
WARN: iothread is only valid with virtio disk or virtio-scsi-single controller, ignoring
```

The VM uses `virtio-scsi-pci`, so `iothread=true` is currently ignored. This remains an OpenTofu follow-up; no manual GUI correction is planned.

### DHCP and guest validation

The ASUS DHCP lease table assigned:

```text
MAC: BC:24:11:71:7E:65
IPv4: 192.168.2.120
```

SSH using the cloud-init key succeeded as `james`.

Guest validation:

```text
Hostname: debian-iac-test-01
OS: Debian GNU/Linux 13 (trixie)
Kernel: Linux 6.12.95+deb13-cloud-amd64
Architecture: x86-64
Virtualisation: KVM
```

Cloud-init reached `done` with no fatal errors. It reported only recoverable deprecation warnings for the generated string `user` field.

System clock/NTP were healthy. The guest initially used `Etc/UTC`.

Memory and storage validation showed approximately 1.9 GiB usable RAM and the expected 24 GiB disk, with the root partition expanded to approximately 23.9 GiB.

### Ansible control proof

TestServer successfully reached the VM with Ansible over SSH.

A repository inventory was added at:

```text
ansible/inventories/lab.yml
```

The inventory pins Debian 13's Python interpreter to `/usr/bin/python3.13`.

Proofs completed:

```text
Ansible ping: SUCCESS / pong
Privilege escalation: id -u => 0
```

This proves the end-to-end control chain:

```text
Git -> OpenTofu -> Proxmox -> cloud-init -> DHCP -> SSH -> Ansible -> sudo/root
```

No production service was migrated during this proof.

---

## 2026-08-30 — Ansible baseline work started

### Baseline playbook scope

The first guest baseline playbook is being developed to:

- set the guest timezone to `Europe/London`;
- install `qemu-guest-agent`;
- install `prometheus-node-exporter`;
- enable/start both services.

Syntax validation passes.

The first `--check --diff` run correctly proposed the timezone change and package installation, but then failed when the service task attempted to find `qemu-guest-agent`. This is a check-mode sequencing effect: the package task is simulated, so the service does not really exist yet.

The service tasks were updated to skip when `ansible_check_mode` is true. Syntax validation passed again.

At the current checkpoint the corrected dry-run has started and has shown the intended timezone change:

```text
Etc/UTC -> Europe/London
```

The real Ansible baseline is now complete. After Alloy was added, the final real Ansible idempotence run returned `ok=13`, `changed=0`, `unreachable=0`, `failed=0`. Direct validation confirmed the QEMU guest-agent virtio channel present, `qemu-guest-agent` active, `prometheus-node-exporter` active/enabled, Alloy active, and timezone `Europe/London`.

### Monitoring and security checkpoint

VM 100 is now registered with central Prometheus under the existing `linux-hosts` job and has been proven `UP` using node-exporter metrics.

Alloy is installed and managed through Ansible. The VM systemd journal is forwarded to central Loki at `192.168.2.242:3100` with labels including `host="debian-iac-test-01"`, `job="systemd-journal"` and `role="proxmox-vm"`. A generated journal marker and real SSH login were both retrieved successfully from central Loki.

CrowdSec on TestServer now has a Git-tracked Loki acquisition rule for VM 100 pointing at central Loki. End-to-end SSH ingestion was proven with a real login. CrowdSec metrics showed 48 Loki lines read, one successful `sshd-success-logs` parse, and the private-source login correctly handled by the private-network whitelist.

### Current next actions

1. Prove the standard Grafana Linux alert baseline covers VM 100.
2. Add Debian security patching with automatic reboot disabled.
3. Add controlled patch/reboot automation and patch-status monitoring.
4. Correct the `iothread` / SCSI-controller warning through OpenTofu.
5. Decide the durable OpenTofu state/recovery model.
6. Select off-host backup storage and prove backup/restore.
7. Destroy VM 100 through OpenTofu and recreate it from Git.

### Debian patch-management baseline

VM 100 now has an Ansible-managed Debian patch-management baseline.

Implemented controls:

- `unattended-upgrades` installed, enabled and active;
- automatic installation restricted to Debian security repositories;
- `Unattended-Upgrade::Automatic-Reboot "false"` explicitly enforced;
- root-owned patch collector deployed through Ansible;
- systemd oneshot service and hourly timer deployed through Ansible;
- node-exporter textfile metrics written to `patch_status.prom`.

The collector exports seven metrics:

- `homelab_updates_available`
- `homelab_security_updates_available`
- `homelab_reboot_required`
- `homelab_unattended_upgrades_enabled`
- `homelab_unattended_upgrades_active`
- `homelab_patch_last_success_timestamp_seconds`
- `homelab_patch_check_timestamp_seconds`

All seven metrics were proven locally through node-exporter and centrally through Prometheus for `host="debian-iac-test-01"`.

At validation time the VM reported zero pending updates, zero security updates and no reboot requirement.

Live Grafana coverage was verified. The standard Linux availability, CPU, memory and root-filesystem rules use `job="linux-hosts"` and therefore cover VM 100.

Patch-specific live rules were also confirmed:

- `Patch collector stale`: collector age greater than 7200 seconds.
- `Security updates available`: `homelab_security_updates_available{job="linux-hosts"} > 0`.

The final Ansible idempotence run completed with `changed=0`, `unreachable=0`, `failed=0`.

Patch-status monitoring and the security-only/no-auto-reboot policy are complete. The controlled patch/reboot workflow is implemented in `ansible/playbooks/patch.yml`; the controlled workflow is now proven through an approved patch cycle and monitored reboot/recovery test.

### Controlled patch and reboot proof

The committed `ansible/playbooks/patch.yml` workflow was first exercised with `patch_apply=false` and `patch_reboot=false`. Package application and reboot were correctly skipped and all baseline services remained healthy.

An approved patch cycle was then run with `patch_apply=true` and `patch_reboot=false`. It completed with `failed=0` and `unreachable=0`, while the reboot path remained disabled.

VM 100 was subsequently rebooted deliberately and returned successfully.

Post-reboot validation proved:

- SSH connectivity restored;
- QEMU guest agent active;
- Prometheus node exporter active;
- Alloy active;
- patch-status timer active;
- Prometheus reported the VM `UP` under `linux-hosts`;
- all seven patch-status metrics were available;
- Loki returned 1421 VM journal entries during the validation window;
- CrowdSec continued consuming the VM Loki source with 3888 source hits and 18 successful SSH parser hits.

The controlled patch workflow and monitored reboot recovery proof are therefore complete.
