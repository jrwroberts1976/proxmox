# Debian 13 Cloud Template and VM 101 OpenTofu Build

## 1. Purpose

This document records the exact controlled workflow used to create the reusable Debian 13 cloud-init template on Proxmox and then provision the first application-platform VM with OpenTofu.

The resulting objects are:

| Object | Value |
|---|---|
| Proxmox node | `PROXMOX` |
| Management IP | `192.168.2.70` |
| Debian template VM ID | `9000` |
| Debian template name | `debian-13-cloud-template` |
| Application VM ID | `101` |
| Application VM name | `app-platform-01` |
| Storage | `vm-ssd` |
| Bridge | `vmbr0` |
| vCPU | 2 |
| RAM | 4096 MB |
| Boot disk | 64 GB |
| Guest network | DHCP during initial commissioning |
| DNS | `192.168.2.48` |
| OpenTofu provider | `bpg/proxmox` `0.111.1` |

The VM is intentionally created in a stopped state. Guest boot, network acceptance and Ansible hand-off are separate controlled stages.

---

## 2. Design decisions

The build follows these rules:

1. Git is the source of truth for VM configuration.
2. OpenTofu manages the Proxmox VM lifecycle.
3. The Proxmox host is an API target, not the OpenTofu workstation.
4. OpenTofu runs from `TestServer`.
5. The reusable Debian 13 template is VM `9000`.
6. VM `101` is a full clone of template `9000`.
7. VM and cloud-init disks are placed on `vm-ssd`.
8. API credentials remain outside Git.
9. OpenTofu state and plan files remain outside Git.
10. A saved plan is reviewed before apply.
11. The exact reviewed plan is applied rather than generating a replacement plan immediately before deployment.
12. No corrective Proxmox GUI changes are made after deployment; persistent changes are made in HCL.

---

## 3. Platform prerequisites

The following platform state was validated before the build:

```text
Proxmox VE:    9.2
pve-manager:   9.2.11
Kernel:        7.0.14-14-pve
Node:          PROXMOX
Bridge:        vmbr0
Storage:       vm-ssd
Storage type:  LVM-thin
```

`vm-ssd` is backed by the Kingston A400 480 GB SATA SSD and is registered as:

```text
lvmthin: vm-ssd
        thinpool thinpool
        vgname vg_vm_ssd
        content images,rootdir
```

Pre-flight checks:

```bash
pveversion
pvesm status
qm list
free -h
ip -br link show vmbr0
```

Required:

- `vm-ssd` is active;
- `vmbr0` is up;
- template ID `9000` is unused before template creation;
- target VM ID `101` is unused before OpenTofu apply;
- sufficient host memory and storage are available.

---

# Part A - Create the Debian 13 cloud template

## 4. Select the official Debian image

The template uses the Debian 13 trixie generic cloud image:

```text
https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
```

The image must be checksum-verified using Debian's published `SHA512SUMS` before import.

Example:

```bash
IMAGE_NAME="debian-13-genericcloud-amd64.qcow2"
IMAGE_DIR="/var/lib/vz/template/iso"
IMAGE_PATH="$IMAGE_DIR/$IMAGE_NAME"
IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/$IMAGE_NAME"
SUM_URL="https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"

mkdir -p "$IMAGE_DIR"

EXPECTED_SHA="$(
  curl -fsSL "$SUM_URL" |
  awk -v file="$IMAGE_NAME" '
    {
      name=$2
      sub(/^\*/, "", name)
      if (name == file) {
        print $1
        exit
      }
    }
  '
)"

curl --fail --location "$IMAGE_URL" --output "${IMAGE_PATH}.download"

echo "$EXPECTED_SHA  ${IMAGE_PATH}.download" | sha512sum -c -
mv "${IMAGE_PATH}.download" "$IMAGE_PATH"
```

For the build performed on 2026-09-01, the image was published on 2026-08-31 and the downloaded file passed the Debian SHA-512 check.

## 5. Create template VM 9000

Create the empty VM definition:

```bash
qm create 9000 \
  --name debian-13-cloud-template \
  --description "Debian 13 trixie genericcloud template - IaC source" \
  --ostype l26 \
  --bios seabios \
  --cpu x86-64-v2-AES \
  --sockets 1 \
  --cores 2 \
  --memory 2048 \
  --balloon 0 \
  --scsihw virtio-scsi-single \
  --net0 "virtio,bridge=vmbr0,firewall=0" \
  --serial0 socket \
  --agent enabled=1 \
  --onboot 0
```

Import the verified Debian cloud disk to `vm-ssd`:

```bash
qm importdisk \
  9000 \
  /var/lib/vz/template/iso/debian-13-genericcloud-amd64.qcow2 \
  vm-ssd \
  --format raw
```

After import, identify the resulting `unused0` volume:

```bash
qm config 9000
```

For this build the volume became:

```text
vm-ssd:vm-9000-disk-0
```

Attach it as the system disk:

```bash
qm set 9000 \
  --scsi0 vm-ssd:vm-9000-disk-0,aio=io_uring,backup=1,cache=none,discard=on,iothread=1,ssd=1
```

Add the cloud-init drive:

```bash
qm set 9000 --ide2 vm-ssd:cloudinit
```

Set boot and initial network configuration:

```bash
qm set 9000 \
  --boot order=scsi0 \
  --ipconfig0 ip=dhcp
```

Convert VM 9000 to a Proxmox template:

```bash
qm template 9000
```

## 6. Validate the template

```bash
qm status 9000
qm config 9000
pvesm list vm-ssd --vmid 9000
```

Expected core properties:

```text
status: stopped
name: debian-13-cloud-template
template: 1
scsi0: vm-ssd:base-9000-disk-0,...
ide2: vm-ssd:vm-9000-cloudinit,media=cdrom
ipconfig0: ip=dhcp
agent: enabled=1
```

The successful build produced:

```text
vm-ssd:base-9000-disk-0
vm-ssd:vm-9000-cloudinit
```

The template must remain stopped and unchanged after VM cloning.

---

# Part B - Proxmox API identity for OpenTofu

## 7. Existing service account

The established service account is:

```text
iac@pve
```

The provider token ID is:

```text
opentofu
```

The token secret is not stored in this repository and must never be committed or printed in routine diagnostics.

The account uses split least-privilege roles:

```text
HomelabIaCNode
HomelabIaCStorage
HomelabIaCVM
```

Existing ACL model:

```text
/nodes/PROXMOX                HomelabIaCNode
/sdn/zones/localnetwork/vmbr0 PVESDNUser
/storage/local                HomelabIaCStorage
/storage/local-lvm            HomelabIaCStorage
/storage/vm-ssd               HomelabIaCStorage
/vms                          HomelabIaCVM
```

The `vm-ssd` ACL was added with:

```bash
pveum acl modify /storage/vm-ssd \
  -user iac@pve \
  -role HomelabIaCStorage \
  -propagate 1
```

Validate without exposing the token secret:

```bash
pveum user list
pveum user token list iac@pve
pveum acl list
pveum role list
```

---

# Part C - OpenTofu execution environment

## 8. Execution host

OpenTofu runs on `TestServer`, not on the Proxmox host.

Current tool version used for the build:

```text
OpenTofu v1.12.6
linux_arm64
```

The provider is pinned to:

```hcl
terraform {
  required_version = ">= 1.12.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "= 0.111.1"
    }
  }
}
```

Provider credentials are loaded from the local protected file:

```text
/home/james/.config/homelab-iac/proxmox.env
```

The file is mode `600` and is not tracked in Git.

Expected environment variable names are:

```text
PROXMOX_VE_ENDPOINT
PROXMOX_VE_API_TOKEN
```

Do not document or commit the token value.

---

# Part D - Separate the legacy VM 100 proof state

## 9. Preserve the earlier disposable proof

VM `100` (`debian-iac-test-01`) was created during the earlier OpenTofu proof and has its own state.

That legacy state was isolated in a separate worktree:

```text
/home/james/projects/proxmox-legacy-vm100
```

The new VM101 branch was created from current `origin/main`:

```text
iac/app-platform-vm101
```

This prevents VM100 state from becoming authoritative for VM101.

The old state was copied to a protected local recovery location before the new workspace was cleaned.

Do not copy VM100 `terraform.tfstate` into the VM101 workspace.

---

# Part E - VM 101 OpenTofu configuration

## 10. Current repository layout

The VM101 build uses the simple validated layout:

```text
tofu/
├── .terraform.lock.hcl
├── main.tf
├── outputs.tf
├── providers.tf
├── variables.tf
└── versions.tf
```

Runtime material is excluded by `.gitignore`:

```text
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
*.plan
*.tfvars
*.tfvars.json
.env
.env.*
secrets/
credentials/
*.key
*.pem
```

## 11. VM 101 specification

The committed VM definition declares:

```text
VM ID:             101
Name:              app-platform-01
Source template:   9000
Clone type:        full
Node:              PROXMOX
Storage:           vm-ssd
Bridge:            vmbr0
CPU:               2 x x86-64-v2-AES
RAM:               4096 MB
Boot disk:         64 GB scsi0
SCSI controller:   virtio-scsi-single
Discard/TRIM:      enabled
SSD flag:          enabled
Cloud-init disk:   vm-ssd
IPv4:              DHCP
DNS:               192.168.2.48
Cloud-init user:   james
SSH authentication: public key
QEMU guest agent:  enabled
Start after create: false
Start on boot:      false
```

The key resource pattern is:

```hcl
resource "proxmox_virtual_environment_vm" "app_platform" {
  name      = var.vm_name
  node_name = var.node_name
  vm_id     = var.vm_id

  started = false
  on_boot = false

  clone {
    vm_id        = var.template_vm_id
    datastore_id = var.datastore_id
    full         = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = var.cpu_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.disk_size_gb
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  initialization {
    datastore_id = var.datastore_id

    dns {
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = var.ipv4_address
      }
    }

    user_account {
      username = "james"
      keys     = [trimspace(file(var.ssh_public_key_file))]
    }
  }

  network_device {
    bridge = var.bridge
    model  = "virtio"
  }
}
```

The complete source is in `tofu/main.tf` and `tofu/variables.tf`.

---

# Part F - Validate, plan and apply

## 12. Initialise and validate

On `TestServer`:

```bash
cd /home/james/projects/proxmox/tofu

tofu fmt
tofu init -backend=false
tofu validate
```

Expected validation result:

```text
Success! The configuration is valid.
```

## 13. Load credentials safely

```bash
set -a
. /home/james/.config/homelab-iac/proxmox.env
set +a
```

Do not run `env`, `set`, or other commands that would expose the API token into copied logs.

## 14. Confirm target-side gates

On `PROXMOX`:

```bash
qm status 101
qm config 9000
pvesm status
```

Before the initial build:

- `qm status 101` must report that VM 101 does not exist;
- VM 9000 must report `template: 1`;
- `vm-ssd` must be active.

## 15. Generate the saved plan

On `TestServer`:

```bash
cd /home/james/projects/proxmox/tofu

tofu plan \
  -no-color \
  -detailed-exitcode \
  -out=vm101.tfplan
```

For a new VM, `-detailed-exitcode` returns `2` because changes are expected.

The reviewed plan for this build was:

```text
resource=proxmox_virtual_environment_vm.app_platform actions=create
create_count=1
update_count=0
delete_count=0

vm_id=101
name=app-platform-01
node=PROXMOX
started=False
on_boot=False
clone_source=9000
clone_datastore=vm-ssd
clone_full=True
cpu_cores=2
cpu_type=x86-64-v2-AES
memory_mb=4096
disk_interface=scsi0
disk_datastore=vm-ssd
disk_size_gb=64
cloudinit_datastore=vm-ssd
ipv4=dhcp
dns=192.168.2.48

Plan: 1 to add, 0 to change, 0 to destroy.
```

Any update, replacement or destroy action at this stage is a stop condition.

## 16. Commit the reviewed source before apply

The VM101 foundation was committed and pushed before deployment:

```text
Commit: a735953142465ab03cb2f98cb3ac9d152fd3ab1d
Message: Add OpenTofu app platform VM foundation
Branch: iac/app-platform-vm101
```

Routine process:

```bash
git status
git add .gitignore tofu/
git diff --cached --name-status
tofu fmt -check
tofu validate
git commit -m "Add OpenTofu app platform VM foundation"
git push -u origin iac/app-platform-vm101
```

Before commit, explicitly confirm no state, plan, credential, private-key or environment file is staged.

## 17. Apply the reviewed saved plan

Apply the saved plan itself:

```bash
cd /home/james/projects/proxmox/tofu

tofu apply -no-color vm101.tfplan
```

Do not replace this with an immediate unreviewed `tofu apply` when the approval process was based on a saved plan.

After a successful apply, protect local state permissions:

```bash
chmod 600 terraform.tfstate
```

State is local operational material and must not be committed.

---

# Part G - Post-apply validation

## 18. Verify VM 101

On `PROXMOX`:

```bash
qm status 101
qm config 101
pvesm list vm-ssd --vmid 101
```

The deployment performed on 2026-09-01 completed with:

```text
vm101_opentofu_apply=PASS
vm101_stopped_gate=PASS
vm101_creation=PASS
```

The VM was intentionally left stopped after creation.

## 19. Verify template 9000 remains intact

The source template was revalidated after VM101 creation:

```text
status: stopped
name: debian-13-cloud-template
scsi0: vm-ssd:base-9000-disk-0,aio=io_uring,backup=1,cache=none,discard=on,iothread=1,size=3G,ssd=1
template: 1
```

This confirms the source remains a stopped Proxmox template after cloning.

---

# Part H - Next commissioning stages

## 20. Start and accept the guest

VM101 creation is complete, but guest commissioning is not yet complete.

Next controlled stages are:

1. Review current host RAM before starting the 4 GB VM.
2. Start VM101 through OpenTofu rather than an undocumented GUI change.
3. Wait for cloud-init to complete.
4. Determine the DHCP address.
5. Validate SSH public-key access.
6. Validate Debian 13 identity, routing and DNS.
7. Validate QEMU guest agent operation.
8. Decide and reserve the permanent guest IP.
9. Update the OpenTofu network definition if moving from DHCP to static configuration.
10. Run a post-apply OpenTofu plan and require no unintended drift.
11. Hand the VM to Ansible.
12. Apply the Linux baseline.
13. Install PostgreSQL.
14. Install TimescaleDB.
15. Install Nginx.
16. Commission metrics, logs and alerting before production acceptance.

The next service runbook after Linux acceptance is `runbooks/postgresql-install.md`.

---

## 21. Rebuild summary

The reproducible high-level build is:

```text
Provision vm-ssd
      |
      v
Download + SHA512 verify Debian 13 genericcloud image
      |
      v
Create VM 9000 shell
      |
      v
Import cloud image to vm-ssd
      |
      v
Attach scsi0 + cloud-init disk
      |
      v
Convert VM 9000 to template
      |
      v
Validate iac@pve permissions for vm-ssd/vmbr0/VMs
      |
      v
Create clean OpenTofu branch/state boundary
      |
      v
Define VM 101 in HCL
      |
      v
fmt -> init -> validate
      |
      v
plan to saved plan file
      |
      v
review: 1 add / 0 change / 0 destroy
      |
      v
commit + push exact HCL
      |
      v
apply reviewed saved plan
      |
      v
validate VM101 stopped + template9000 intact
      |
      v
Guest commissioning / Ansible
```

This workflow is deliberately suitable for later translation to Terraform because the configuration uses standard HCL and the same `bpg/proxmox` provider model.
