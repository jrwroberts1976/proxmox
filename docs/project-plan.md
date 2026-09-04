# Proxmox Homelab Migration Project Plan

## 1. Purpose

Build the HP ProDesk 400 G4 DM into the main x86 virtualisation platform for the homelab, migrate suitable workloads onto it in controlled stages, and manage new infrastructure using Infrastructure as Code (IaC).

The project must improve capability without making DNS, security monitoring, or recovery dependent on the Proxmox host.

## 2. Project status

**Current state:** platform bootstrap complete and project paused until the Jenkins work is finished.

The Proxmox host is installed, patched, running headlessly, and has passed initial hardware, network, storage, virtualisation, and time-sync checks. No production workloads have been migrated.

## 3. Target platform

| Item | Target / current state |
|---|---|
| Host | HP ProDesk 400 G4 DM |
| CPU | Intel Core i5-8500T, 6 cores / 6 threads |
| RAM | 8 GB now; target 32 GB (2 x 16 GB DDR4 SO-DIMM) |
| Primary storage | 256 GB WDC PC SN520 NVMe initially |
| Hypervisor | Proxmox VE 9.2 |
| Management IP | `192.168.2.70/24` |
| Gateway | `192.168.2.1` |
| Operation | 24x7, headless |
| Repository | `jrwroberts1976/proxmox` |

## 4. Design principles

1. **Infrastructure as Code by default.** Production VMs should not be manually created in the Proxmox GUI.
2. **Git is the source of truth.** Reproducible configuration belongs in this repository.
3. **Jenkins automates, but does not become the only recovery path.** IaC must remain runnable manually.
4. **DNS stays independent of Proxmox.** Loss of the HP must not remove name resolution.
5. **Security stays independent.** `ids-01` remains the dedicated IDS/security host.
6. **Backups live outside the Proxmox host.** A VM backup on the same NVMe is not sufficient protection.
7. **Migration is service-by-service.** Old instances are retained until the replacement passes validation.
8. **Observability precedes production.** Monitoring and alerting are established before important workloads move.
9. **Rollback is required at every stage.** Every change must have a defined fallback.
10. **Secrets never enter Git in plaintext.** API tokens, passwords, `.env` files, and private keys must be excluded or stored using an approved secret mechanism.

## 5. Target architecture

```text
                         Internet
                            |
                       ASUS Router
                            |
                      ProCurve Switch
                            |
        +-------------------+-------------------+
        |                   |                   |
   HP ProDesk             ids-01              Pi 3
   Proxmox VE             Security          DNS server
        |               Suricata etc.     Pi-hole/Unbound
        |
        +-- Debian Docker VM
        |     +-- Grafana
        |     +-- Prometheus
        |     +-- Loki
        |     +-- Portainer
        |     +-- application stacks
        |
        +-- Home Assistant OS VM
        |
        +-- Lab/Test VMs

                         Cat6
                           |
                         Pi 4
                    Garden Room
                           |
                    +-- BirdNET-Go
                    +-- Pi-hole
                    +-- Unbound
                    +-- monitoring
```

## 6. IaC operating model

The intended build chain is:

```text
Git
 |
 +--> OpenTofu / Terraform
 |      +--> Proxmox VMs, CPU, RAM, disks, NICs, cloud-init
 |
 +--> cloud-init
 |      +--> first-boot identity, SSH keys, network/bootstrap
 |
 +--> Ansible
 |      +--> OS packages, users, hardening, Docker, exporters, services
 |
 +--> Docker Compose
 |      +--> application stacks
 |
 +--> Jenkins
        +--> validate, plan, test and deploy the above
```

### Proposed repository structure

```text
proxmox/
├── README.md
├── docs/
│   ├── installation.md
│   ├── project-plan.md
│   ├── build-log.md
│   ├── architecture.md
│   ├── backup-recovery.md
│   └── migration-runbook.md
├── tofu/                  # or terraform/ once provider choice is final
│   ├── providers.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── modules/
│   └── environments/
├── cloud-init/
├── ansible/
│   ├── inventories/
│   ├── playbooks/
│   └── roles/
├── docker/
│   └── stacks/
├── scripts/
└── runbooks/
```

## 7. Jenkins role

Jenkins remains useful after Proxmox is introduced. Its role changes from being a standalone delivery lab to becoming the automation/orchestration layer for the homelab platform.

Expected pipeline pattern:

```text
Git push / pull request
        |
        v
     Jenkins
        |
        +--> formatting / linting
        +--> OpenTofu/Terraform validate
        +--> OpenTofu/Terraform plan
        +--> Ansible syntax/lint checks
        +--> optional security checks
        +--> controlled apply/deploy
```

Jenkins must not be required to recover the platform. The same IaC must be executable from an administrator workstation if Jenkins is unavailable.

## 8. Project phases and gates

### Phase 0 - Existing environment protection

- [x] Keep current production services running.
- [x] Do not migrate workloads during host bootstrap.
- [ ] Confirm current application/data backups before migration starts.
- [ ] Capture current Docker workload inventory.

**Gate:** current homelab is healthy and migration can be performed without destroying the source environment.

### Phase 1 - Proxmox host bootstrap

- [x] Install Proxmox VE 9.2.
- [x] Disable PVE Enterprise repository.
- [x] Disable Ceph Enterprise repository.
- [x] Enable `pve-no-subscription`.
- [x] Apply initial package updates.
- [x] Reboot and prove headless recovery.
- [x] Configure static management address `192.168.2.70/24`.
- [x] Create ASUS DHCP reservation for `192.168.2.70`.
- [x] Verify 1 Gbit/s full-duplex Ethernet.
- [x] Verify NTP/time synchronisation.
- [x] Verify Intel VT-x.
- [x] Verify Intel VT-d/IOMMU and interrupt remapping.
- [x] Capture hardware/storage baseline.
- [x] Capture NVMe SMART baseline.
- [x] Capture thermal baseline.

**Gate:** PASSED.

### Phase 2 - Firmware and host readiness

- [ ] Verify latest supported HP Q23 BIOS for the exact ProDesk 400 G4 DM.
- [ ] Update BIOS using official HP firmware if appropriate.
- [ ] Re-verify VT-x after BIOS update.
- [ ] Re-verify VT-d/IOMMU after BIOS update.
- [ ] Re-verify headless boot after BIOS update.
- [ ] Recheck network configuration after firmware change.
- [ ] Recheck temperatures and SMART health.

**Gate:** host boots cleanly, virtualisation is still active, network is unchanged, and no firmware-related errors are present.

### Phase 3 - Monitoring integration

`prometheus-node-exporter` 1.9.0 is already installed and listening on port 9100.

- [x] Verify local node_exporter metrics.
- [x] Verify CPU/NVMe thermal metrics are exposed.
- [x] Add `192.168.2.70:9100` to the existing Prometheus configuration.
- [x] Confirm target is `UP`.
- [x] Add Proxmox host to the existing Grafana/Network Hosts view.
- [x] Prove standard CPU, RAM/load and root-filesystem metric visibility.
- [x] Prove standard host-up and disk-space alert coverage.
- [x] Forward the Proxmox systemd journal through Alloy to central Loki.
- [x] Provision Grafana Zabbix plugin `6.6.0` and a SOPS-backed read-only Zabbix datasource.
- [x] Prove Grafana can query Zabbix and read the `Infrastructure/Proxmox` host group.
- [ ] Onboard the Proxmox VE host itself into Zabbix using the approved Proxmox integration/template.
- [ ] Add dedicated disk-I/O/network panels where useful.
- [ ] Add CPU/package, PCH and NVMe temperature panels.
- [ ] Add high-temperature alerting.
- [ ] Add SMART/NVMe health reporting where practical.
- [ ] Track the historic NVMe unsafe-shutdown baseline of 103 for increases.
- [ ] Evaluate a Proxmox API exporter for VM/LXC/storage metrics only if it adds value beyond the established Prometheus/Zabbix paths.

**Gate:** basic Prometheus/Grafana host observability is passed. Zabbix datasource integration is passed. Proxmox-specific Zabbix onboarding and optional monitoring enhancements remain backlog work.

### Phase 4 - Host security baseline

- [x] Inventory listening ports.
- [x] Confirm zero failed systemd services at baseline.
- [ ] Review Proxmox firewall configuration and policy.
- [ ] Review SSH configuration and administrative access model.
- [ ] Review `rpcbind`/port 111 before deciding whether it can be disabled.
- [ ] Add Proxmox host to Greenbone scanning.
- [ ] Capture initial vulnerability scan.
- [ ] Remediate or document accepted findings.
- [ ] Confirm Proxmox management UI is not exposed externally.
- [ ] Document patch/update procedure.

**Gate:** host has an accepted vulnerability baseline and only required management exposure.

### Phase 5 - Backup and disaster-recovery design

No production VM should be created until a backup destination has been selected.

- [ ] Select backup target physically separate from the HP/NVMe.
- [ ] Decide whether to use Proxmox Backup Server or standard Proxmox backup jobs initially.
- [ ] Define retention policy.
- [ ] Define encryption requirements.
- [ ] Define backup schedule.
- [ ] Configure backup monitoring/alerts.
- [ ] Create disposable VM backup.
- [ ] Delete disposable VM.
- [ ] Restore disposable VM.
- [ ] Prove application/network function after restore.
- [ ] Document complete recovery runbook.

**Gate:** a VM has been successfully restored from an off-host backup.

### Phase 6 - IaC foundation

- [ ] Choose OpenTofu or Terraform as the primary declarative tool.
- [ ] Choose and pin the Proxmox provider version.
- [ ] Create a least-privilege Proxmox API user/token for IaC.
- [ ] Keep token material outside Git.
- [ ] Add `.gitignore` for state, secrets, local variables and credentials.
- [ ] Decide state-storage approach.
- [ ] Define naming convention for VMs.
- [ ] Define VM ID allocation approach.
- [ ] Define IP-address allocation approach.
- [ ] Create reusable VM module.
- [ ] Create cloud-init template workflow.
- [ ] Create Ansible inventory structure.
- [ ] Create base Linux role for packages, users, SSH, time, monitoring and hardening.
- [ ] Add formatting/linting/validation scripts.
- [ ] Document manual IaC workflow before Jenkins automation is added.

**Gate:** `plan` is reproducible and no credentials or state secrets are committed to Git.

### Phase 7 - Disposable IaC VM proof

The first VM must be disposable and created from code.

- [ ] Create Debian VM through IaC.
- [ ] Configure CPU/RAM/storage/network through IaC.
- [ ] Bootstrap with cloud-init.
- [ ] Configure with Ansible.
- [ ] Install node_exporter automatically.
- [ ] Add it to monitoring.
- [ ] Reboot and verify recovery.
- [ ] Back it up.
- [ ] Destroy it through IaC.
- [ ] Recreate it from Git.
- [ ] Confirm the rebuilt host is functionally equivalent.
- [ ] Restore a backup as a separate recovery proof.

**Gate:** disposable VM can be destroyed and rebuilt from repository state without manual GUI construction.

### Phase 8 - Jenkins integration

Start this only after the Jenkins delivery-lab work is complete and the manual IaC workflow is proven.

- [ ] Add IaC validation pipeline.
- [ ] Run formatting checks.
- [ ] Run OpenTofu/Terraform validation.
- [ ] Generate plans on pull requests/controlled builds.
- [ ] Run Ansible syntax/lint checks.
- [ ] Add security/static checks where useful.
- [ ] Require explicit approval for production apply/deploy operations.
- [ ] Protect API tokens/SSH keys as Jenkins credentials.
- [ ] Keep a documented manual deployment path.

**Gate:** Jenkins can automate the workflow without becoming a single point of recovery failure.

### Phase 9 - DNS resilience

DNS must remain outside Proxmox.

#### Pi 4 - Garden room

- BirdNET-Go
- Pi-hole
- Unbound
- monitoring/exporters
- wired Cat6 connection

#### Pi 3

- Pi-hole
- Unbound
- monitoring/exporters

Tasks:

- [ ] Build/validate Pi 4 DNS service alongside BirdNET-Go.
- [ ] Validate Pi 3 DNS service.
- [ ] Synchronise required DNS/blocking configuration.
- [ ] Ensure each resolver is operational independently.
- [ ] Advertise both DNS servers to clients.
- [ ] Shut down Pi 3 and prove DNS continues.
- [ ] Shut down Pi 4 and prove DNS continues.
- [ ] Configure both resolvers on Proxmox after the resilient pair is available.

**Gate:** either DNS appliance can fail without loss of name resolution.

### Phase 10 - Home automation

- [ ] Select Home Assistant OS as the preferred dedicated VM model unless requirements change.
- [ ] Define VM in IaC where supported/practical.
- [ ] Configure backups before adding important automations.
- [ ] Integrate Tapo devices.
- [ ] Define network/device discovery requirements.
- [ ] Add monitoring.
- [ ] Test restore.

**Gate:** Home Assistant configuration can be recovered and does not compromise core network resilience.

### Phase 11 - Docker platform build

- [ ] Define Debian Docker VM in IaC.
- [ ] Configure OS through cloud-init/Ansible.
- [ ] Install Docker and Compose using automated configuration.
- [ ] Define persistent-data layout.
- [ ] Define secrets handling.
- [ ] Define logging model.
- [ ] Define backup model.
- [ ] Install node_exporter/monitoring automatically.
- [ ] Store application Compose definitions in Git.
- [ ] Deploy one low-risk test application.

**Gate:** Docker platform is reproducible, monitored, backed up and recoverable.

### Phase 12 - Workload inventory and migration

Classify every existing service as:

- **MIGRATE** - belongs on Proxmox/Docker VM.
- **KEEP** - should stay on the current physical node.
- **REBUILD** - migrate by clean deployment rather than copying existing state.
- **RETIRE** - no longer required.

Suggested migration order:

1. Homepage/Dashy-style presentation services.
2. Dozzle and low-risk utilities.
3. WUD and similar tooling.
4. Other stateless/low-risk containers.
5. Uptime Kuma.
6. Grafana.
7. Loki.
8. Prometheus.

Prometheus and Loki move late because they are central to observability and storage-intensive.

Per-service migration procedure:

```text
Backup source
    |
Deploy destination from Git/IaC
    |
Restore/migrate required data
    |
Validate functionality
    |
Validate monitoring/logging
    |
Reboot/recovery test
    |
Observe for agreed period
    |
Accept migration
    |
Retire old instance later
```

**Gate:** no source instance is removed until the destination is proven and rollback is understood.

### Phase 13 - Capacity upgrades

RAM/storage upgrades can be made after installation without reinstalling Proxmox.

- [ ] Review actual RAM utilisation.
- [ ] Decide whether to move first to 16 GB or directly to 32 GB.
- [ ] Preferred final RAM target: 2 x 16 GB compatible DDR4 SO-DIMM.
- [ ] Review NVMe capacity before migrating Loki/Prometheus.
- [ ] Decide whether to add a 2.5-inch SATA SSD and/or replace the 256 GB NVMe.
- [ ] Keep backup storage separate from primary VM storage.
- [ ] Measure 24x7 power consumption at the wall.

**Gate:** capacity upgrades are justified by observed workload needs rather than assumption.

### Phase 14 - Final acceptance

- [ ] All selected production workloads managed through Git/IaC where practical.
- [ ] No plaintext secrets in repository history.
- [ ] Monitoring/alerting operational.
- [ ] Security scan accepted.
- [ ] External backups operational.
- [ ] Restore tests passed.
- [ ] DNS failover tests passed.
- [ ] Home Assistant backup/restore passed if deployed.
- [ ] Documentation matches live configuration.
- [ ] Old services retired only after acceptance.
- [ ] Final architecture diagram updated.
- [ ] Disaster-recovery runbook tested.

## 9. Change-control rules

For meaningful changes:

1. Define intended change and rollback.
2. Update code/configuration in Git.
3. Validate/plan before applying.
4. Apply to test/disposable infrastructure first where possible.
5. Record validation evidence.
6. Apply to production only after the relevant gate passes.
7. Update `docs/build-log.md` after implementation.

Manual emergency fixes are allowed when required for recovery, but they must be reconciled back into Git afterwards to eliminate configuration drift.

## 10. Definition of done

The project is complete when the HP ProDesk is a stable, monitored, secured and recoverable Proxmox platform; selected services have been migrated using reproducible IaC workflows; Jenkins can automate those workflows without being required for recovery; DNS remains independently resilient on the Pi estate; and documentation in this repository is sufficient to rebuild the environment from a clean Proxmox installation.
