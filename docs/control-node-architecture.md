# TestServer IaC Control-Node Architecture

## Purpose

`TestServer` is the management and Infrastructure-as-Code control node for the Proxmox homelab.

It is the system from which Proxmox virtual machines and LXC containers are provisioned and then configured. Its current role is best described as an **IaC control node**, **automation host**, or **management server**.

It is **not currently a bastion host**.

A bastion or jump host is an enforced administrative gateway through which operators must connect before they can reach protected systems. The current homelab does not enforce that network boundary: workloads such as CT201 can still be reached directly from permitted LAN systems. TestServer may be evolved into a bastion later, but that is separate from its present IaC role.

## Responsibilities

TestServer currently provides the following management functions:

- local working copy of the `jrwroberts1976/proxmox` repository;
- Git branch and change-control workflow;
- OpenTofu execution for Proxmox infrastructure provisioning;
- Ansible execution for guest operating-system and application configuration;
- SSH management access to the Proxmox node and managed guests;
- validation, idempotence and drift checks;
- local OpenTofu state handling and protected state backups where applicable.

The intended ownership boundary is:

| Layer | Authority |
|---|---|
| Desired configuration and history | GitHub repository |
| VM/LXC lifecycle and Proxmox configuration | OpenTofu |
| Guest OS and application configuration | Ansible |
| Compute, storage and virtual networking | Proxmox VE |
| Automation execution | TestServer |

## Current topology

```text
                         GitHub
             jrwroberts1976/proxmox
                           |
                 git fetch / pull / push
                           |
                           v
                      TestServer
               IaC / automation control node
              OpenTofu + Ansible + Git + SSH
                    /               \
                   /                 \
          Proxmox API / SSH        Direct SSH
                 /                     \
                v                       v
             PROXMOX  ----------------> guests
          192.168.2.70                 |
                |                      +-- VMs
                |                      +-- LXCs
                |
                +-- vmbr0
                +-- local / local-lvm
                +-- vm-ssd
```

TestServer is therefore the **place from which infrastructure is created and configured**, while Proxmox remains the compute platform on which the workloads actually run.

## Provisioning workflow

A normal managed build should follow this direction:

```text
Git change
   |
   v
OpenTofu plan on TestServer
   |
   v
review / safety gates
   |
   v
OpenTofu apply
   |
   v
Proxmox creates or changes VM/LXC
   |
   v
commissioning checks
   |
   v
Ansible inventory
   |
   v
Ansible configuration
   |
   v
idempotence + health + OpenTofu zero-drift proof
```

Manual configuration on the Proxmox host or inside a guest should be treated as an exception. If an out-of-band change is required for recovery or because an API operation needs elevated Proxmox privileges, the desired state should still be represented in IaC and reconciled back to zero drift.

## CT201 example

The first LXC workload validates this pattern:

```text
CTID:      201
Hostname:  zabbix-lxc-01
IPv4:      192.168.2.184 (DHCP commissioning address)
Type:      unprivileged Debian 13 LXC
Storage:   vm-ssd
```

The control flow is:

```text
TestServer
  |
  +-- OpenTofu --> Proxmox --> creates/manages CT201
  |
  +-- Ansible ----------------> configures CT201
  |
  +-- SSH --------------------> validates/recover CT201
```

OpenTofu owns the container-level configuration. Ansible owns the Debian userspace and application configuration.

The Debian 13 LXC build also demonstrated the recovery rule: where a Proxmox setting needed `root@pam`-equivalent privileges that the normal API token could not exercise, TestServer used its controlled root SSH path to Proxmox for the one privileged operation, while the setting remained declared in OpenTofu and was subsequently proven at zero drift.

## Why this is not a bastion today

TestServer does not currently provide an enforced network choke point. Direct guest SSH remains possible where LAN policy allows it.

A true bastion design would instead look more like:

```text
Administrator
     |
     v
 TestServer / Bastion
     |
     +--> PROXMOX
     +--> VM/LXC management addresses

Direct administrator --> guest SSH blocked by network policy
```

That would require deliberate network controls, firewall rules and administrative access policy. Merely running Ansible and OpenTofu from TestServer does not make it a bastion.

## Security principles

- Keep Proxmox itself focused on the hypervisor role; do not install general automation tooling or Docker workloads directly on the host without a specific reason.
- Prefer least-privilege Proxmox API credentials for OpenTofu.
- Use the existing controlled root SSH path only for operations that genuinely require Proxmox root privileges or for recovery.
- Do not place private keys, API tokens, passwords, OpenTofu state, or unencrypted secrets in Git.
- Require reviewed OpenTofu plans for infrastructure changes.
- Require Ansible idempotence for guest configuration.
- Require OpenTofu zero drift after infrastructure changes or privileged recovery actions.
- Keep workload-specific inventory separate from retired or historical workload identities.

## Future bastion option

TestServer can later become both the IaC control node and a formal bastion/jump host if there is a clear security requirement.

That should be a separate project with explicit acceptance criteria, for example:

1. restrict VM/LXC administrative SSH so it is reachable only from approved management systems;
2. use `ProxyJump`/SSH jump-host configuration for interactive administration;
3. keep OpenTofu and Ansible automation working through the management path;
4. add logging and monitoring of administrative sessions;
5. define emergency access and recovery procedures;
6. prove that service traffic remains independent from management traffic.

Until those controls exist, documentation should refer to TestServer as the **IaC control node**, not as a bastion.

## Design summary

```text
GitHub     = source control / desired-state history
TestServer = IaC control node and automation runner
OpenTofu   = Proxmox infrastructure lifecycle
Ansible    = guest configuration lifecycle
Proxmox    = compute/storage/network virtualisation platform
VMs/LXCs   = application and service workloads
```

This separation is intentional and is the default architecture for future Proxmox VM and LXC builds in this repository.
