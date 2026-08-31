# New Linux VM Observability Bootstrap Runbook

## 1. Purpose

This runbook defines the standard observability commissioning procedure for every new Debian-family Linux VM created on the Proxmox platform.

The preferred new-VM architecture is:

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
          |                   Prometheus
          |
          +--> loki.source.journal / loki.source.file
                  |
                  +--> loki.write
                          |
                          v
                         Loki

Prometheus + Loki
       |
       v
     Grafana
       |
       +--> dashboards
       +--> alerts
```

The objective is that a VM is not considered production-ready until both metrics and logs are visible centrally and the host participates in alerting.

---

## 2. Preferred standard versus legacy compatibility

### Preferred standard for new Proxmox VMs

Use one native Alloy service for both:

- Linux metrics via `prometheus.exporter.unix`;
- system logs via `loki.source.journal`;
- selected application logs via `loki.source.file` where required.

This avoids deploying a separate node_exporter service when Alloy is already present.

### Existing/legacy direct-scrape hosts

Some existing homelab hosts may already use:

```text
prometheus-node-exporter :9100
       |
       v
Prometheus direct scrape
```

That remains valid where already established. Use the separate Linux Monitoring in Grafana runbook for those hosts.

Do not collect the same host twice through both direct node_exporter scraping and Alloy remote write unless a temporary migration test is explicitly intended.

---

## 3. Scope

This runbook covers:

- host identity and operating-system baseline;
- central Prometheus/Loki preflight;
- Alloy installation dependency;
- Linux metrics commissioning;
- journal log commissioning;
- optional application log commissioning;
- Grafana validation;
- minimum alert coverage;
- duplicate collection checks;
- controlled end-to-end tests;
- acceptance, rollback, and handover;
- the eventual Ansible automation model.

It does not provision the VM itself. VM creation belongs to the OpenTofu/cloud-init layer.

---

## 4. Related runbooks

Use these procedures as component references:

```text
runbooks/alloy-install.md
runbooks/alloy-linux-monitoring.md
runbooks/prometheus-install.md
runbooks/loki-install.md
runbooks/linux-monitoring-grafana.md    # direct node_exporter compatibility path
```

Some related runbooks may be delivered through separate documentation PRs until the documentation set is merged into `main`.

---

## 5. Required commissioning values

Before starting, record:

```text
VM_HOSTNAME=
VM_IP=
VM_ROLE=
ENVIRONMENT=homelab
PROMETHEUS_HOST=
PROMETHEUS_PORT=9090
LOKI_HOST=
LOKI_PORT=3100
GRAFANA_URL=
```

Recommended `VM_ROLE` values include:

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

## 6. Confirm VM provisioning is complete

Before installing observability tooling:

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
- Debian-family OS is supported;
- time synchronisation is healthy;
- no unexpected failed services exist.

If identity or networking is wrong, fix the OpenTofu/cloud-init/Ansible source rather than compensating in monitoring configuration.

---

# Stage 1 - Central observability preflight

## 7. Confirm Prometheus

From the new VM:

```bash
curl -fsS http://<PROMETHEUS_HOST>:9090/-/ready
```

Expected: success.

Prometheus must be running with:

```text
--web.enable-remote-write-receiver
```

for the preferred Alloy metrics path.

---

## 8. Confirm Loki

```bash
curl -fsS http://<LOKI_HOST>:3100/ready
```

Expected:

```text
ready
```

If Prometheus or Loki is not reachable, stop here. Do not commission a telemetry agent against a broken destination.

---

# Stage 2 - Install Alloy

## 9. Install using the Alloy installation runbook

Follow the standard Alloy installation procedure.

Acceptance before continuing:

```bash
systemctl --no-pager --full status alloy
curl -fsS http://127.0.0.1:12345/-/ready
curl -fsS http://127.0.0.1:12345/-/healthy
```

Expected:

- `alloy.service` active;
- readiness passes;
- health passes.

Do not make Alloy run as root simply to obtain journal/application-log access. Use groups/ACLs appropriate to the required sources.

---

# Stage 3 - Build the combined Alloy pipeline

## 10. Baseline configuration model

The final configuration should logically contain:

```text
METRICS
prometheus.exporter.unix
        |
discovery.relabel
        |
prometheus.scrape
        |
prometheus.remote_write ---> Prometheus

LOGS
loki.source.journal
        |
loki.write -----------------> Loki
```

Optional application files add:

```text
local.file_match
        |
loki.source.file
        |
loki.write -----------------> Loki
```

---

## 11. Example combined configuration

The following is a commissioning baseline. Integrate it with existing Alloy configuration rather than blindly replacing unrelated pipelines.

```alloy
// -----------------------------------------------------------------------------
// Linux host metrics
// -----------------------------------------------------------------------------

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
    url = "http://<PROMETHEUS_HOST>:9090/api/v1/write"
  }
}

// -----------------------------------------------------------------------------
// Linux systemd journal
// -----------------------------------------------------------------------------

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
    url = "http://<LOKI_HOST>:3100/loki/api/v1/push"
  }
}
```

Use LAN-resolvable destinations from a systemd Alloy installation.

Do not assume Docker-only service names such as `prometheus` or `loki` will resolve on the VM.

---

# Stage 4 - Journal permissions

## 12. Confirm Alloy can read the journal

Check service identity:

```bash
id alloy
```

Test journal access as Alloy where practical:

```bash
sudo -u alloy journalctl -n 5 --no-pager
```

If access is denied, use the system's approved group/ACL model, commonly involving journal-readable groups.

After changing group membership, restart Alloy:

```bash
sudo systemctl restart alloy
```

Do not change Alloy to run as root solely for journal access.

---

# Stage 5 - Validate configuration

## 13. Preserve current config

```bash
sudo cp /etc/alloy/config.alloy \
  /etc/alloy/config.alloy.before-observability-bootstrap
```

After editing:

```bash
sudo alloy validate /etc/alloy/config.alloy
```

Expected: validation succeeds.

Review diff:

```bash
sudo diff -u \
  /etc/alloy/config.alloy.before-observability-bootstrap \
  /etc/alloy/config.alloy
```

Do not restart with invalid configuration.

---

# Stage 6 - Apply Alloy configuration

## 14. Restart and validate

```bash
sudo systemctl restart alloy
systemctl --no-pager --full status alloy
curl -fsS http://127.0.0.1:12345/-/ready
curl -fsS http://127.0.0.1:12345/-/healthy
journalctl -u alloy -n 100 --no-pager
```

Expected:

- service active;
- readiness healthy;
- no repeated remote-write failures;
- no repeated Loki push failures;
- no journal permission failures.

---

# Stage 7 - Metrics end-to-end test

## 15. Validate in Prometheus

Query:

```promql
node_uname_info{hostname="<VM_HOSTNAME>"}
```

Expected: one result.

Check:

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

Confirm labels:

```text
hostname=<VM_HOSTNAME>
role=<VM_ROLE>
environment=homelab
```

---

# Stage 8 - Logs end-to-end test

## 16. Generate unique journal event

```bash
TEST_ID="observability-$(hostname)-$(date +%s)"
logger -t homelab-observability-test "$TEST_ID"
echo "$TEST_ID"
```

In Grafana Explore using Loki, search for the exact test ID.

Example starting query:

```logql
{hostname="<VM_HOSTNAME>"} |= "<TEST_ID>"
```

Expected: the unique event appears with the correct host labels.

Do not accept `alloy.service active` as proof of log delivery.

---

# Stage 9 - Grafana dashboard acceptance

## 17. Linux host dashboard

The host should appear in the normal Linux-host dashboard selector.

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

In Grafana Explore, the following must work:

```promql
node_uname_info{hostname="<VM_HOSTNAME>"}
```

and:

```logql
{hostname="<VM_HOSTNAME>"}
```

This proves both metrics and logs are searchable using the same stable host identity.

---

# Stage 10 - Duplicate collection gate

## 18. Check node metrics cardinality

```promql
count by (hostname, instance, job) (
  node_uname_info{hostname="<VM_HOSTNAME>"}
)
```

Investigate if the host appears unexpectedly through multiple paths.

Possible duplicate sources:

- separate `prometheus-node-exporter` direct scrape;
- Alloy `prometheus.exporter.unix` remote write;
- multiple Alloy instances;
- stale/mislabelled targets.

For a new Proxmox VM, prefer the Alloy pipeline unless the infrastructure design explicitly chooses direct node_exporter scraping.

---

# Stage 11 - Alerting gate

## 19. Minimum operational coverage

Before production use, the VM should have a defined alert strategy for:

| Condition | Starting point |
|---|---|
| Metrics missing | 5 minutes |
| Root filesystem warning | > 85% |
| Root filesystem critical | > 95% |
| Memory high | > 90% for 10 minutes |
| CPU high | > 90% for 15 minutes |
| Critical application/service failure | service-specific |
| Log pipeline failure | Alloy/Loki monitoring |

For Alloy remote-written hosts, an absence rule can detect missing host metrics:

```promql
absent_over_time(
  node_uname_info{hostname="<VM_HOSTNAME>"}[5m]
)
```

The final alert should be tested in the homelab alerting system before being treated as reliable.

---

# Stage 12 - Optional application logs

## 20. Add only required files

Do not recursively ingest arbitrary directories.

For each required application log:

1. identify exact file path/glob;
2. confirm rotation behaviour;
3. give Alloy the minimum read permission;
4. add stable labels;
5. validate configuration;
6. restart Alloy;
7. generate/search a unique event;
8. monitor ingestion volume.

Application-specific parsing should live in a dedicated runbook/role extension rather than growing the base bootstrap indefinitely.

---

# Stage 13 - Optional direct node_exporter compatibility path

## 21. When to use a separate node_exporter

Use the direct node_exporter path when:

- migrating an existing host already scraped by Prometheus;
- a central Prometheus scrape model is deliberately preferred;
- Alloy remote write is not enabled;
- operational compatibility requires the existing `up{job="node"}` alert model.

Then the architecture becomes:

```text
Linux VM
   +--> prometheus-node-exporter :9100 --> Prometheus
   +--> Alloy --------------------------> Loki
```

Follow the separate Linux Monitoring in Grafana runbook.

Do not also enable `prometheus.exporter.unix` for the same host unless intentionally comparing paths.

---

# Stage 14 - Reboot persistence test

## 22. Reboot the VM

After initial commissioning and before production acceptance:

```bash
sudo reboot
```

After reconnecting:

```bash
systemctl is-active alloy
curl -fsS http://127.0.0.1:12345/-/ready
```

Then recheck:

```promql
node_uname_info{hostname="<VM_HOSTNAME>"}
```

and generate another unique journal event.

A configuration that only works until reboot is not accepted.

---

# Stage 15 - Acceptance gate

## 23. VM observability checklist

A new Linux VM is observability-ready only when all applicable items pass:

### Host

- [ ] Correct hostname.
- [ ] Correct IP/network.
- [ ] Time sync healthy.
- [ ] No unexpected failed systemd services.

### Alloy

- [ ] Alloy installed from approved source.
- [ ] Alloy enabled at boot.
- [ ] Alloy active.
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
- [ ] unique test journal event visible in Loki.
- [ ] expected log labels present.

### Grafana

- [ ] VM appears in Linux dashboard.
- [ ] core panels populate.
- [ ] metrics searchable in Explore.
- [ ] logs searchable in Explore.

### Alerting

- [ ] missing-metrics/host-loss strategy exists.
- [ ] filesystem alert coverage exists.
- [ ] resource alert coverage exists where appropriate.
- [ ] critical service-specific alerting is planned or active.

### Recovery/governance

- [ ] VM passes reboot persistence test.
- [ ] configuration source is in Git.
- [ ] no plaintext secrets entered Git.
- [ ] rollback configuration exists until commissioning closes.

---

# Rollback

## 24. Roll back observability changes

Restore the prior Alloy configuration:

```bash
sudo cp \
  /etc/alloy/config.alloy.before-observability-bootstrap \
  /etc/alloy/config.alloy
```

Validate:

```bash
sudo alloy validate /etc/alloy/config.alloy
```

Restart:

```bash
sudo systemctl restart alloy
```

Confirm any pre-existing Alloy pipeline remains healthy.

If Alloy was newly installed solely for this failed bootstrap and removal is required, use the Alloy installation runbook's uninstall/rollback procedure rather than deleting files ad hoc.

---

# Troubleshooting

## 25. Metrics work, logs do not

Check:

```bash
sudo -u alloy journalctl -n 5 --no-pager
journalctl -u alloy -n 200 --no-pager
curl -fsS http://<LOKI_HOST>:3100/ready
```

Likely areas:

- journal permissions;
- Loki URL;
- DNS/routing;
- Loki write component health.

---

## 26. Logs work, metrics do not

Check:

```bash
journalctl -u alloy -n 200 --no-pager
curl -fsS http://<PROMETHEUS_HOST>:9090/-/ready
```

Confirm Prometheus remote-write receiver is enabled.

Inspect Alloy components:

- exporter;
- relabel;
- scrape;
- remote write.

---

## 27. Both pipelines fail after reboot

```bash
systemctl status alloy
journalctl -u alloy -b --no-pager
```

Check:

- service enabled state;
- config syntax;
- DNS availability during boot;
- network-online timing;
- permissions/group membership;
- destination reachability.

---

## 28. `lookup prometheus` or `lookup loki` failure

If the config uses bare Docker service names from a remote VM, replace them with LAN-resolvable endpoints.

Correct pattern from a separate VM:

```text
http://<MONITORING_VM_IP>:9090/api/v1/write
http://<MONITORING_VM_IP>:3100/loki/api/v1/push
```

Docker service names are appropriate only inside the Docker networks that define them.

---

# Future Ansible implementation

## 29. Target role model

The preferred eventual Ansible design is one Alloy role with observability feature switches:

```yaml
alloy_enabled: true

alloy_linux_metrics_enabled: true
alloy_journal_logs_enabled: true

alloy_prometheus_remote_write_url: >-
  http://monitoring.example:9090/api/v1/write

alloy_loki_write_url: >-
  http://monitoring.example:3100/loki/api/v1/push

alloy_host_role: application
alloy_environment: homelab
```

The role should:

1. install Alloy;
2. configure permissions;
3. render metrics and log pipelines;
4. run `alloy validate`;
5. restart only when configuration changes;
6. check readiness/health;
7. fail deployment if Alloy is unhealthy.

A higher-level commissioning playbook can then perform central API checks and end-to-end tests.

---

## 30. Target IaC chain

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
 |      +--> Alloy
 |      +--> observability pipeline
 |
 +--> acceptance checks
        +--> Prometheus metrics visible
        +--> Loki test log visible
        +--> Grafana host visible
        +--> alert coverage
```

Observability should be part of VM creation, not a manual afterthought performed weeks later.

---

## 31. Completion record

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
