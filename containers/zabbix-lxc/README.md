# Zabbix LXC

This project builds the first Proxmox LXC workload in the homelab using OpenTofu and Ansible.

## Target

- Proxmox node: `PROXMOX`
- CT ID: `201`
- Hostname: `zabbix-lxc-01`
- OS: Debian 13
- Container type: unprivileged LXC
- LXC nesting: enabled for Debian 13/systemd 257 compatibility
- CPU: 2 cores
- RAM: 4096 MB
- Swap: 1024 MB
- Root disk: 64 GB on `vm-ssd`
- Bridge: `vmbr0`
- Initial IPv4: DHCP
- DNS: `192.168.2.48`
- MAC: `02:5A:42:00:02:01`
- Start on Proxmox boot: yes

## Debian 13 nesting requirement

The Debian 13 template uses systemd 257. With nesting disabled, CT201 was created successfully but systemd entered a degraded state with failed standard mounts including `dev-mqueue.mount`, `run-lock.mount`, and `tmp.mount`.

The container remains unprivileged, but OpenTofu explicitly enables:

```hcl
features {
  nesting = true
}
```

This is part of the declared container authority and must not be enabled only as an untracked manual Proxmox change.

## Application target

The LXC will later be configured through Ansible with the already-proven roles for:

1. Linux baseline/security hardening
2. unattended upgrades
3. Alloy observability
4. PostgreSQL 17
5. TimescaleDB
6. Nginx/PHP
7. Zabbix Server 7.0 LTS
8. Zabbix Agent 2
9. Zabbix frontend IaC

No application services are installed by this OpenTofu root.

## State isolation

This directory is a dedicated OpenTofu root and therefore owns a separate state from the earlier VM101 build.

Do not run this configuration from the repository-level `tofu/` directory.

Run from:

```text
/home/james/projects/proxmox/containers/zabbix-lxc
```

The local state, plans and local variable files are excluded from Git.

## Control host

OpenTofu is run from `TestServer`, using:

```text
/home/james/projects/proxmox
```

Provider credentials are loaded from:

```text
/home/james/.config/homelab-iac/proxmox.env
```

The credential file must remain outside Git.

## Debian LXC template

The shared Debian template is intentionally not owned by this workload's OpenTofu state.

Required template:

```text
local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst
```

If it is not already cached, download it once on the Proxmox node as root:

```bash
pveam download local debian-13-standard_13.6-1_amd64.tar.zst
```

Keeping the template outside CT201 state means destroying the Zabbix LXC cannot accidentally delete a platform template used by other containers.

## Stage 1 — plan only

From `TestServer`:

```bash
cd /home/james/projects/proxmox

git fetch origin --prune
git switch feature/zabbix-lxc-foundation
git pull --ff-only

cd containers/zabbix-lxc

set -a
. /home/james/.config/homelab-iac/proxmox.env
set +a

tofu init
tofu fmt -check
tofu validate
tofu plan -out=zabbix-lxc.tfplan
```

Do not apply until the plan has been reviewed and the CT ID/MAC collision gates have passed.

## Safety gates before first apply

On `PROXMOX`, prove:

```bash
pct status 201
```

must report that CT 201 does not exist.

The MAC must not already occur in active Proxmox guest configuration:

```bash
grep -RFi '02:5A:42:00:02:01' /etc/pve 2>/dev/null
```

Expected result: no output.

Also prove the required template exists:

```bash
pvesm list local --content vztmpl |
  grep -F 'debian-13-standard_13.6-1_amd64.tar.zst'
```

## Apply policy

A reviewed saved plan is the only approved apply input:

```bash
tofu apply <reviewed-plan-file>
```

After apply or an infrastructure change, do not begin Zabbix installation until the LXC commissioning gates pass:

- CT201 exists and is running
- unprivileged mode is confirmed
- nesting configuration matches OpenTofu authority
- systemd reports healthy after reboot
- root filesystem is on `vm-ssd`
- DHCP address is identified
- SSH using the injected public key works
- Debian 13 identity is confirmed
- hostname is `zabbix-lxc-01`
- DNS and Internet package access work
- OpenTofu returns zero drift

## Provider

This project pins `bpg/proxmox` `0.111.1`, matching the existing Proxmox repository authority.
