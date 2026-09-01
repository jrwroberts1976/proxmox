# New Linux VM Observability Bootstrap Runbook

## 1. Purpose

This runbook defines the standard observability commissioning procedure for new Debian-family Linux VMs created on the Proxmox platform.

The preferred architecture is one native Grafana Alloy service on each new VM, forwarding Linux metrics to the authoritative Prometheus instance and system/application logs to the authoritative Loki instance.

```text
New Linux VM
   |
   +--> Grafana Alloy
          |
          +--> prometheus.exporter.unix
          |       |
          |       +--> prometheus.scrape
          |               |
          |               +--> prometheus.remote_write
          |                       |
          |                       v
          |              ids-01 Prometheus
          |
          +--> loki.source.journal / loki.source.file
                  |
                  +--> loki.write
                          |
                          v
                     ids-01 Loki

ids-01 Prometheus + Loki
          |
          v
       Grafana
          |
          +--> dashboards
          +--> alerts
```

A VM is not considered observability-ready until both metrics and logs are visible centrally, duplicate collection has been excluded, and reboot persistence has been tested.

---

## 2. Current homelab monitoring authority

As verified on 2026-09-01, the authoritative monitoring stack is on `ids-01`.

| Component | Authority | LAN endpoint | Notes |
|---|---|---|---|
| Prometheus | `ids-01` | `http://192.168.2.242:9090` | Remote-write receiver enabled |
| Loki | `ids-01` | `http://192.168.2.242:3100` | Ready and reachable from VM101 |
| Grafana | `ids-01` | `https://grafana.jrwroberts.co.uk/` | Uses Docker-local Prometheus/Loki datasources |

Grafana's provisioned datasource URLs on `ids-01` are:

```text
http://prometheus:9090
http://loki:3100
```

Those Docker service names are valid only inside the `ids-01` monitoring Docker network. A separate VM must use the LAN-reachable `192.168.2.242` endpoints.

### Important authority rule

Do not assume that a host called `prometheus` or any reachable TCP/9090 service is the monitoring authority.

The homelab currently contains more than one Prometheus deployment. Before commissioning a VM, verify the authority by checking:

1. where Grafana is running;
2. Grafana's provisioned datasource configuration;
3. the Prometheus target/job inventory;
4. the Loki datasource and readiness endpoint.

For new Proxmox VMs, use `ids-01` unless the architecture is deliberately changed and this runbook is updated.

---

## 3. Preferred standard versus legacy compatibility

### Preferred standard for new Proxmox VMs

Use one native Alloy service for both:

- Linux metrics via `prometheus.exporter.unix`;
- system logs via `loki.source.journal`;
- selected application logs via `loki.source.file` where required.

Do not deploy a separate `prometheus-node-exporter` on a new VM when Alloy is already exporting the same node metrics.

### Existing/legacy direct-scrape hosts

Some existing homelab hosts use:

```text
prometheus-node-exporter :9100
       |
       v
Prometheus direct scrape
```

That remains valid for established hosts. Use `runbooks/linux-monitoring-grafana.md` for that compatibility path.

Do not collect the same host through both direct node_exporter scraping and Alloy remote write unless a temporary migration comparison is explicitly intended.

---

## 4. Scope

This runbook covers:

- VM identity and OS baseline;
- monitoring-authority verification;
- network/firewall preflight;
- Prometheus remote-write receiver preflight;
- Alloy installation and configuration;
- Linux metrics commissioning;
- journal log commissioning;
- optional application logs;
- Grafana validation;
- duplicate collection checks;
- alerting acceptance;
- reboot persistence;
- rollback and handover;
- the intended Ansible automation model.

VM creation itself belongs to OpenTofu/cloud-init.

---

## 5. Related runbooks

```text
runbooks/alloy-install.md
runbooks/alloy-linux-monitoring.md
runbooks/prometheus-install.md
runbooks/loki-install.md
runbooks/linux-monitoring-grafana.md
runbooks/linux-vm-security-hardening.md
runbooks/linux-vm-iac-deployment.md
```

---

## 6. Required commissioning values

For the current homelab authority:

```text
VM_HOSTNAME=
VM_IP=
VM_ROLE=
ENVIRONMENT=homelab
PROMETHEUS_HOST=192.168.2.242
PROMETHEUS_PORT=9090
LOKI_HOST=192.168.2.242
LOKI_PORT=3100
GRAFANA_URL=https://grafana.jrwroberts.co.uk/
```

Recommended `VM_ROLE` values:

```text
application
database
web
monitoring
security
dns
lab
```

Use stable, lowercase label values where practical.

---

# Stage 0 - Infrastructure gate

## 7. Confirm VM provisioning is complete

```bash
hostnamectl
ip -br addr
ip route
cat /etc/os-release
uname -a
timedatectl
systemctl --failed
```

Expected:

- intended hostname is set;
- intended management IP exists;
- default route is correct;
- supported Debian-family OS is installed;
- time synchronisation is healthy;
- no unexpected failed services exist.

If identity or networking is wrong, fix the OpenTofu/cloud-init/Ansible source rather than compensating in monitoring configuration.

Security hardening should be complete before application deployment. Observability should be commissioned before PostgreSQL, TimescaleDB, Nginx, or other application services are treated as production-ready.

---

# Stage 1 - Verify the monitoring authority

## 8. Confirm Grafana, Prometheus and Loki are on the intended host

On the candidate monitoring authority:

```bash
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}' |
  grep -E '^(prometheus|grafana|loki)[[:space:]]'
```

Inspect Grafana datasource provisioning:

```bash
grep -RniE 'name:|type:|url:|prometheus|loki' \
  /home/james/docker/data/monitoring/grafana/provisioning/datasources
```

For the current authority, the host must be `ids-01` / `192.168.2.242`.

Check Prometheus target health:

```bash
curl -fsS http://127.0.0.1:9090/api/v1/targets |
jq -r '
  "active=" + ((.data.activeTargets | length) | tostring),
  "healthy=" + ([.data.activeTargets[] | select(.health == "up")] | length | tostring),
  "unhealthy=" + ([.data.activeTargets[] | select(.health != "up")] | length | tostring)
'
```

The verified baseline at the time this runbook was updated was:

```text
active=26
healthy=26
unhealthy=0
```

Treat this as a commissioning reference, not a permanently fixed target count; intentionally added or removed scrape jobs can change it.

---

# Stage 2 - Central endpoint preflight

## 9. Test Prometheus from the new VM

```bash
curl -fsS --connect-timeout 5 \
  http://192.168.2.242:9090/-/ready
```

Expected:

```text
Prometheus Server is Ready.
```

## 10. Test Loki from the new VM

```bash
curl -fsS --connect-timeout 5 \
  http://192.168.2.242:3100/ready
```

Expected:

```text
ready
```

If either connection fails, stop here. Do not install/configure Alloy against an unreachable destination.

### Firewall diagnosis

If ping/SSH works but monitoring ports time out, inspect the destination host firewall and Docker forwarding path before changing the VM.

Useful checks:

```bash
sudo iptables -S FORWARD
sudo iptables -S DOCKER-USER
sudo nft list ruleset
```

Docker-published traffic may traverse `FORWARD` and `DOCKER-USER`, so an ordinary UFW `INPUT` allow rule may not be sufficient.

Do not open monitoring ports to the whole LAN merely to make commissioning pass. Prefer the narrowest source-specific rule required by the architecture.

---

# Stage 3 - Prometheus remote-write receiver gate

## 11. Confirm the receiver is enabled

On `ids-01`:

```bash
docker inspect prometheus \
  --format '{{range .Config.Cmd}}{{println .}}{{end}}'
```

Required flag:

```text
--web.enable-remote-write-receiver
```

The persistent authority is currently:

```text
/home/james/docker/stacks/monitoring/docker-compose.yml
```

The Prometheus command list must include:

```yaml
command:
  - "--config.file=/etc/prometheus/prometheus.yml"
  - "--storage.tsdb.path=/prometheus"
  - "--web.enable-lifecycle"
  - "--web.enable-remote-write-receiver"
```

Before changing the Compose source:

1. make a timestamped backup;
2. review the diff;
3. run `docker compose config -q`;
4. recreate only Prometheus;
5. wait for target discovery to settle;
6. prove the previous target-health baseline returns.

Example controlled apply:

```bash
cd /home/james/docker/stacks/monitoring

docker compose config -q

docker compose up \
  -d \
  --no-deps \
  --force-recreate \
  prometheus
```

After restart, do not treat `active_targets=0` immediately after startup as failure. Wait for service discovery and the first scrape cycle.

Verified on 2026-09-01, the `ids-01` instance returned to:

```text
active_targets=26
healthy_targets=26
unhealthy_targets=0
```

with the remote-write receiver enabled.

---

# Stage 4 - Install Alloy

## 12. Install using Ansible

For new Proxmox VMs, Alloy should be installed and configured through the Proxmox repository Ansible implementation rather than as an undocumented manual package install.

Use the standard Alloy installation procedure/role.

Acceptance before continuing:

```bash
systemctl --no-pager --full status alloy
curl -fsS http://127.0.0.1:12345/-/ready
curl -fsS http://127.0.0.1:12345/-/healthy
```

Expected:

- `alloy.service` enabled;
- `alloy.service` active;
- readiness passes;
- health passes.

Keep the Alloy HTTP/UI listener local to the VM unless a documented operational requirement needs remote access.

Do not run Alloy as root merely to obtain journal/application-log access. Use appropriate journal-readable groups or ACLs.

---

# Stage 5 - Build the combined Alloy pipeline

## 13. Baseline configuration model

```text
METRICS
prometheus.exporter.unix
        |
discovery.relabel
        |
prometheus.scrape
        |
prometheus.remote_write ---> 192.168.2.242:9090

LOGS
loki.source.journal
        |
loki.write -----------------> 192.168.2.242:3100
```

Optional application files:

```text
local.file_match
        |
loki.source.file
        |
loki.write -----------------> 192.168.2.242:3100
```

## 14. Example combined configuration

```alloy
prometheus.exporter.unix "linux" {
}

discovery.relabel "linux" {
  targets = prometheus.exporter.unix.linux.targets

  rule {
    target_label = "hostname"
    replacement  = "<VM_HOSTNAME>"
  }

  rule {
    target_label = "role"
    replacement  = "<VM_ROLE>"
  }

  rule {
    target_label = "environment"
    replacement  = "homelab"
  }
}

prometheus.scrape "linux" {
  scrape_interval = "15s"
  targets         = discovery.relabel.linux.output
  forward_to      = [prometheus.remote_write.homelab.receiver]
}

prometheus.remote_write "homelab" {
  endpoint {
    url = "http://192.168.2.242:9090/api/v1/write"
  }
}

loki.source.journal "system" {
  forward_to = [loki.write.homelab.receiver]

  labels = {
    hostname    = "<VM_HOSTNAME>",
    role        = "<VM_ROLE>",
    environment = "homelab",
    source      = "journal",
  }
}

loki.write "homelab" {
  endpoint {
    url = "http://192.168.2.242:3100/loki/api/v1/push"
  }
}
```

Do not use Docker-only names such as `prometheus` or `loki` from a separate systemd-based VM.

---

# Stage 6 - Journal permissions

## 15. Confirm Alloy can read the journal

```bash
id alloy
sudo -u alloy journalctl -n 5 --no-pager
```

If access is denied, use the approved group/ACL model. After changing group membership:

```bash
sudo systemctl restart alloy
```

Do not change the service to root solely for journal access.

---

# Stage 7 - Validate configuration

## 16. Validate before restart

Preserve the previous configuration where one exists:

```bash
sudo cp /etc/alloy/config.alloy \
  /etc/alloy/config.alloy.before-observability-bootstrap
```

Validate:

```bash
sudo alloy validate /etc/alloy/config.alloy
```

Review the intended diff before restart.

The Ansible role should perform validation before notifying/restarting Alloy.

---

# Stage 8 - Apply Alloy configuration

## 17. Restart and validate

```bash
sudo systemctl restart alloy
systemctl --no-pager --full status alloy
curl -fsS http://127.0.0.1:12345/-/ready
curl -fsS http://127.0.0.1:12345/-/healthy
journalctl -u alloy -n 100 --no-pager
```

Expected:

- service active;
- readiness/health healthy;
- no repeated remote-write failures;
- no repeated Loki push failures;
- no journal permission failures.

---

# Stage 9 - Metrics end-to-end test

## 18. Validate in Prometheus

```promql
node_uname_info{hostname="<VM_HOSTNAME>"}
```

Expected: one result.

Also check:

```promql
node_memory_MemTotal_bytes{hostname="<VM_HOSTNAME>"}
```

```promql
node_boot_time_seconds{hostname="<VM_HOSTNAME>"}
```

```promql
node_cpu_seconds_total{hostname="<VM_HOSTNAME>"}
```

```promql
node_filesystem_size_bytes{hostname="<VM_HOSTNAME>"}
```

Required labels:

```text
hostname=<VM_HOSTNAME>
role=<VM_ROLE>
environment=homelab
```

---

# Stage 10 - Logs end-to-end test

## 19. Generate a unique journal event

```bash
TEST_ID="observability-$(hostname)-$(date +%s)"
logger -t homelab-observability-test "$TEST_ID"
echo "$TEST_ID"
```

In Grafana Explore using Loki:

```logql
{hostname="<VM_HOSTNAME>"} |= "<TEST_ID>"
```

Expected: the exact event appears with the correct host labels.

`alloy.service active` by itself is not proof of successful log delivery.

---

# Stage 11 - Grafana dashboard acceptance

## 20. Linux host dashboard

Minimum visible data:

- hostname/OS/kernel;
- uptime;
- CPU;
- load;
- memory;
- swap where present;
- filesystem usage;
- disk I/O;
- network throughput;
- network errors/drops.

Temperature panels may legitimately be empty for VMs.

In Grafana Explore both must work:

```promql
node_uname_info{hostname="<VM_HOSTNAME>"}
```

```logql
{hostname="<VM_HOSTNAME>"}
```

---

# Stage 12 - Duplicate collection gate

## 21. Check node metrics cardinality

```promql
count by (hostname, instance, job) (
  node_uname_info{hostname="<VM_HOSTNAME>"}
)
```

Investigate unexpected multiple paths.

Possible duplicate sources:

- separate `prometheus-node-exporter` direct scrape;
- Alloy `prometheus.exporter.unix` remote write;
- multiple Alloy instances;
- stale/mislabelled targets;
- commissioning against the wrong Prometheus authority.

For a new Proxmox VM, prefer the Alloy pipeline.

---

# Stage 13 - Alerting gate

## 22. Minimum operational coverage

| Condition | Starting point |
|---|---|
| Metrics missing | 5 minutes |
| Root filesystem warning | > 85% |
| Root filesystem critical | > 95% |
| Memory high | > 90% for 10 minutes |
| CPU high | > 90% for 15 minutes |
| Critical application/service failure | service-specific |
| Log pipeline failure | Alloy/Loki monitoring |

Example missing-metrics rule:

```promql
absent_over_time(
  node_uname_info{hostname="<VM_HOSTNAME>"}[5m]
)
```

Alerting is not accepted until the configured notification path has been tested.

---

# Stage 14 - Optional application logs

## 23. Add only required files

Do not recursively ingest arbitrary application directories.

For each file source:

1. identify the exact path/glob;
2. confirm rotation behaviour;
3. give Alloy minimum read permission;
4. apply stable labels;
5. validate configuration;
6. restart through Ansible/handler;
7. generate/search a unique event;
8. monitor ingestion volume.

Application-specific parsing belongs in a dedicated role/runbook extension.

---

# Stage 15 - Reboot persistence

## 24. Reboot the VM

```bash
sudo reboot
```

After reconnecting:

```bash
systemctl is-active alloy
curl -fsS http://127.0.0.1:12345/-/ready
```

Recheck metrics and generate another unique journal event.

A configuration that works only until reboot is not accepted.

---

# Stage 16 - Acceptance gate

## 25. VM observability checklist

### Host

- [ ] Correct hostname.
- [ ] Correct/stable IP identity.
- [ ] Time sync healthy.
- [ ] No unexpected failed systemd services.

### Central platform

- [ ] Monitoring authority verified as intended.
- [ ] Prometheus reachable from VM.
- [ ] Loki reachable from VM.
- [ ] Prometheus remote-write receiver enabled.
- [ ] Existing Prometheus target-health baseline recovered after any central restart.

### Alloy

- [ ] Installed from approved source through Ansible.
- [ ] Enabled at boot.
- [ ] Active.
- [ ] `/-/ready` passes.
- [ ] `/-/healthy` passes.
- [ ] Configuration validation passes.

### Metrics

- [ ] `prometheus.exporter.unix` healthy.
- [ ] `prometheus.scrape` healthy.
- [ ] `prometheus.remote_write` healthy.
- [ ] `node_uname_info` visible centrally.
- [ ] CPU metrics visible.
- [ ] memory metrics visible.
- [ ] filesystem metrics visible.
- [ ] expected labels present.
- [ ] duplicate metric path check passes.

### Logs

- [ ] Alloy can read systemd journal.
- [ ] `loki.write` healthy.
- [ ] unique journal test event visible in Loki.
- [ ] expected log labels present.

### Grafana

- [ ] VM appears in the Linux dashboard.
- [ ] core panels populate.
- [ ] metrics searchable in Explore.
- [ ] logs searchable in Explore.

### Alerting

- [ ] missing-metrics/host-loss strategy exists.
- [ ] filesystem alert coverage exists.
- [ ] resource alert coverage exists where appropriate.
- [ ] critical service-specific alerting is planned or active.

### Recovery/governance

- [ ] reboot persistence test passes.
- [ ] configuration source is in Git.
- [ ] no plaintext secrets entered Git.
- [ ] rollback configuration exists until commissioning closes.

---

# VM101 commissioning record

## 26. `app-platform-01` status

Commissioning values verified on 2026-09-01:

```text
VMID=101
VM_HOSTNAME=app-platform-01
VM_IP=192.168.2.253
VM_ROLE=application
ENVIRONMENT=homelab
PROMETHEUS_HOST=192.168.2.242
LOKI_HOST=192.168.2.242
```

Completed gates:

- [x] VM running and QEMU guest agent healthy.
- [x] Debian 13 baseline commissioned.
- [x] Linux security-hardening controls applied and idempotence checked.
- [x] VM101 can reach `ids-01` by network.
- [x] VM101 -> `ids-01:9090` Prometheus readiness passes.
- [x] VM101 -> `ids-01:3100` Loki readiness passes.
- [x] `ids-01` confirmed as Grafana/Prometheus/Loki authority.
- [x] `ids-01` Prometheus remote-write receiver enabled.
- [x] Prometheus recovered to the verified 26/26 healthy-target baseline after controlled recreation.

Next gate:

```text
Build and apply the reusable Ansible Alloy role to VM101.
```

Do not start PostgreSQL, TimescaleDB, or Nginx commissioning until the VM101 observability acceptance gate is closed.

---

# Rollback

## 27. Alloy rollback

Restore the previous Alloy configuration where applicable:

```bash
sudo cp \
  /etc/alloy/config.alloy.before-observability-bootstrap \
  /etc/alloy/config.alloy

sudo alloy validate /etc/alloy/config.alloy
sudo systemctl restart alloy
```

If Alloy was newly installed solely for a failed bootstrap, use the Alloy installation runbook's uninstall/rollback process rather than deleting files ad hoc.

## 28. Prometheus receiver rollback

If remote-write support must be removed from the central Prometheus instance:

1. restore/edit the Compose authority;
2. remove only `--web.enable-remote-write-receiver`;
3. run `docker compose config -q`;
4. recreate only Prometheus;
5. wait for service discovery;
6. prove the previous scrape-target baseline returns.

Do not roll back the receiver while any Alloy-managed host depends on it.

---

# Troubleshooting

## 29. Metrics work, logs do not

```bash
sudo -u alloy journalctl -n 5 --no-pager
journalctl -u alloy -n 200 --no-pager
curl -fsS http://192.168.2.242:3100/ready
```

Check:

- journal permissions;
- Loki URL;
- routing/firewall;
- Loki component health.

## 30. Logs work, metrics do not

```bash
journalctl -u alloy -n 200 --no-pager
curl -fsS http://192.168.2.242:9090/-/ready
```

Confirm:

- `--web.enable-remote-write-receiver` is running on authoritative Prometheus;
- Alloy exporter/relabel/scrape/remote-write components are healthy;
- the VM is not sending to a non-authoritative Prometheus instance.

## 31. Both pipelines fail after reboot

```bash
systemctl status alloy
journalctl -u alloy -b --no-pager
```

Check:

- service enabled state;
- config syntax;
- network-online timing;
- permissions/group membership;
- destination reachability.

## 32. `lookup prometheus` or `lookup loki` failure

Do not use Docker service names from the VM.

Correct current homelab URLs:

```text
http://192.168.2.242:9090/api/v1/write
http://192.168.2.242:3100/loki/api/v1/push
```

## 33. Wrong Prometheus instance suspected

Compare candidate servers:

```bash
curl -fsS http://<candidate>:9090/api/v1/status/buildinfo
curl -fsS http://<candidate>:9090/api/v1/targets
```

Then verify which server is attached to Grafana through its datasource provisioning.

Do not choose the authority based only on which endpoint happens to respond.

---

# Ansible implementation

## 34. Target role model

```yaml
alloy_enabled: true
alloy_linux_metrics_enabled: true
alloy_journal_logs_enabled: true

alloy_prometheus_remote_write_url: >-
  http://192.168.2.242:9090/api/v1/write

alloy_loki_write_url: >-
  http://192.168.2.242:3100/loki/api/v1/push

alloy_host_role: application
alloy_environment: homelab
```

The role should:

1. install Alloy from the approved Grafana repository;
2. configure the unprivileged `alloy` service identity;
3. grant the minimum journal-read access;
4. render metrics and log pipelines;
5. bind the local Alloy UI to loopback unless otherwise required;
6. run `alloy validate` before restart;
7. restart only when configuration changes;
8. check readiness/health;
9. fail deployment if Alloy is unhealthy;
10. remain idempotent on a second Ansible run.

A higher-level commissioning playbook should perform the central Prometheus/Loki API checks and end-to-end acceptance tests.

---

## 35. Target IaC chain

```text
Git
 |
 +--> OpenTofu
 |      +--> create VM
 |
 +--> cloud-init
 |      +--> bootstrap identity/network/SSH
 |
 +--> Ansible
 |      +--> OS baseline
 |      +--> security hardening
 |      +--> Alloy
 |      +--> observability pipeline
 |
 +--> acceptance checks
        +--> Prometheus metrics visible
        +--> Loki test log visible
        +--> Grafana host visible
        +--> alert coverage
        +--> reboot persistence
```

Observability is part of VM commissioning, not an optional manual task performed after applications are deployed.

---

## 36. Completion record

```text
VM hostname:
VM IP:
Role:
Environment:
OS:
Alloy version:
Prometheus destination:
Loki destination:
Alloy validation: PASS / FAIL
Alloy health: PASS / FAIL
Metrics end-to-end: PASS / FAIL
Logs end-to-end: PASS / FAIL
Grafana dashboard: PASS / FAIL
Duplicate metric check: PASS / FAIL
Alert coverage: PASS / FAIL
Reboot persistence: PASS / FAIL
Date:
Operator:
Notes:
```
