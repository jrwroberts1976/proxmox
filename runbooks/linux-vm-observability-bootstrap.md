# New Linux VM Observability Bootstrap Runbook

## 1. Purpose

This runbook defines the mandatory observability commissioning gate for new Debian-family Proxmox VMs.

A VM is not ready for PostgreSQL, TimescaleDB, Nginx or other application services until metrics and logs are visible centrally, duplicate collection has been excluded, dashboard-source data is proven, alerting is defined, and reboot persistence has been tested.

Preferred architecture:

```text
New Linux VM
   |
   +--> Grafana Alloy
          |
          +--> prometheus.exporter.unix
          |        |
          |        +--> prometheus.scrape
          |                 |
          |                 +--> prometheus.remote_write
          |                           |
          |                           v
          |                  ids-01 Prometheus
          |
          +--> loki.source.journal
                   |
                   +--> loki.write
                            |
                            v
                       ids-01 Loki

ids-01 Prometheus + Loki --> Grafana
```

---

## 2. Current monitoring authority

Verified 2026-09-01:

| Component | Authority | Endpoint |
|---|---|---|
| Prometheus | `ids-01` | `http://192.168.2.242:9090` |
| Prometheus remote write | `ids-01` | `http://192.168.2.242:9090/api/v1/write` |
| Loki | `ids-01` | `http://192.168.2.242:3100` |
| Loki push | `ids-01` | `http://192.168.2.242:3100/loki/api/v1/push` |
| Grafana | `ids-01` | `https://grafana.jrwroberts.co.uk/` |

Grafana's internal provisioned datasources are:

```text
http://prometheus:9090
http://loki:3100
```

Those Docker service names are valid inside the monitoring Docker network. A remote systemd Alloy service must use the LAN endpoints.

### Authority rule

The homelab contains more than one Prometheus deployment. Verify Grafana's datasource before selecting a Prometheus endpoint. Current new-VM authority is `ids-01`, not TestServer.

---

## 3. Related implementation

```text
runbooks/alloy-install.md
runbooks/alloy-linux-monitoring.md
runbooks/prometheus-install.md
runbooks/loki-install.md
runbooks/linux-monitoring-grafana.md   # legacy direct node_exporter only

ansible/roles/alloy/
ansible/playbooks/alloy.yml
```

---

# Stage 0 - VM baseline

Record:

```text
VM_HOSTNAME=
VM_IP=
VM_ROLE=
ENVIRONMENT=homelab
PROMETHEUS_HOST=192.168.2.242
LOKI_HOST=192.168.2.242
```

Check:

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

- correct host identity;
- expected network path;
- time sync healthy;
- no unexpected failed units.

---

# Stage 1 - Central platform preflight

From the VM:

```bash
curl -fsS http://192.168.2.242:9090/-/ready
curl -fsS http://192.168.2.242:3100/ready
```

Prometheus must also be running with:

```text
--web.enable-remote-write-receiver
```

The receiver was enabled on `ids-01` on 2026-09-01. Its controlled recreation returned to the verified scrape baseline:

```text
active_targets=26
healthy_targets=26
unhealthy_targets=0
```

If either central endpoint is unavailable, stop before deploying Alloy.

---

# Stage 2 - Ansible preflight

From the controller:

```bash
cd /home/james/projects/proxmox/ansible

ansible-playbook \
  -i inventories/vm101/hosts.yml \
  playbooks/alloy.yml \
  --syntax-check

ansible \
  -i inventories/vm101/hosts.yml \
  alloy_hosts \
  -m ansible.builtin.ping
```

First-install dry run:

```bash
ansible-playbook \
  -i inventories/vm101/hosts.yml \
  playbooks/alloy.yml \
  --check \
  --diff
```

### First-install check-mode rule

Repository/key changes are only simulated in check mode, so APT cannot see the new Alloy package in that same dry run. The role deliberately reports the intended package install and ends the host before package-dependent tasks.

Expected:

```text
failed=0
CHECK MODE: Grafana Alloy would be installed after the Grafana APT repository is applied.
```

Ansible `uri` checks may also be skipped in check mode. Keep the explicit central `curl` preflight above.

---

# Stage 3 - Deploy Alloy

Apply:

```bash
ansible-playbook \
  -i inventories/vm101/hosts.yml \
  playbooks/alloy.yml
```

The role must:

1. add the official Grafana APT repository;
2. install Alloy;
3. grant journal-readable group access;
4. render `/etc/default/alloy`;
5. render `/etc/alloy/config.alloy`;
6. run `alloy validate` before restart;
7. enable/start the service;
8. check readiness and health;
9. prove journal access as the `alloy` account.

Run the playbook again after a successful first apply. Expected second run:

```text
changed=0
failed=0
```

---

# Stage 4 - Local Alloy acceptance

```bash
alloy --version
systemctl is-enabled alloy
systemctl is-active alloy
ss -ltn | grep ':12345'
curl -fsS http://127.0.0.1:12345/-/ready
curl -fsS http://127.0.0.1:12345/-/healthy
id alloy
systemctl --failed --no-legend
```

Expected local listener:

```text
127.0.0.1:12345
```

Do not expose the Alloy UI to the LAN merely for convenience.

### Journal permission validation

Use:

```bash
runuser -u alloy -- journalctl -n 5 --no-pager
```

The current role deliberately avoids Ansible `become_user: alloy` for this validation because VM101 exposed an Ansible temporary-file ACL/chmod incompatibility during privilege switching. `runuser` verifies the same service-account access without that unrelated dependency.

---

# Stage 5 - Managed Alloy pipeline

Metrics path:

```text
prometheus.exporter.unix
 -> discovery.relabel
 -> prometheus.scrape
 -> prometheus.remote_write
 -> http://192.168.2.242:9090/api/v1/write
```

Logs path:

```text
loki.source.journal
 -> loki.write
 -> http://192.168.2.242:3100/loki/api/v1/push
```

Required stable labels:

```text
hostname=<HOSTNAME>
role=<ROLE>
environment=homelab
```

Do not deploy a separate node_exporter on the same new VM.

---

# Stage 6 - Metrics end-to-end proof

Query authoritative Prometheus:

```promql
node_uname_info{hostname="<HOSTNAME>"}
```

Expected: exactly one host series.

Core queries:

```promql
node_memory_MemTotal_bytes{hostname="<HOSTNAME>"}
node_boot_time_seconds{hostname="<HOSTNAME>"}
node_cpu_seconds_total{hostname="<HOSTNAME>"}
node_filesystem_size_bytes{hostname="<HOSTNAME>"}
```

### Important remote-write behaviour

An Alloy remote-written host does not become a normal Prometheus scrape target. Do not use `/api/v1/targets` alone to decide whether the host is monitored.

For VM101 the validated series labels are:

```text
hostname=app-platform-01
instance=app-platform-01
job=integrations/unix
role=application
environment=homelab
```

---

# Stage 7 - Duplicate metrics gate

```promql
count by (hostname, instance, job) (
  node_uname_info{hostname="<HOSTNAME>"}
)
```

Expected for a normal new VM: one authoritative path.

VM101 validated result:

```text
app-platform-01  app-platform-01  integrations/unix  1
```

Investigate direct node_exporter, multiple Alloy instances or stale labels if more than one path appears.

---

# Stage 8 - Logs end-to-end proof

Generate a unique event:

```bash
TEST_ID="observability-$(hostname)-$(date +%s)"
logger -t homelab-observability-test "$TEST_ID"
echo "$TEST_ID"
```

Search Loki:

```logql
{hostname="<HOSTNAME>"} |= "<TEST_ID>"
```

VM101 passed this test on 2026-09-01.

Observed VM101 Loki labels:

```text
environment=homelab
hostname=app-platform-01
job=loki.source.journal.system
role=application
service_name=loki.source.journal.system
source=journal
```

Do not hard-code dashboards/queries around the older assumption `job="systemd-journal"`; inspect actual labels from the running Alloy version.

An Ansible shell invocation containing the same unique ID may itself be journalled and returned by the Loki query. That does not automatically indicate duplicate log shipping.

---

# Stage 9 - Grafana data acceptance

Current provisioned dashboards on `ids-01` that contain Linux/node metrics include:

```text
/home/james/docker/data/monitoring/grafana/dashboards/homelab-noc2.json
/home/james/docker/data/monitoring/grafana/dashboards/homelab-noc.json
/home/james/docker/data/monitoring/grafana/dashboards/linux-os-monitoring.json
```

Before editing a dashboard, prove source data:

```promql
node_uname_info{hostname="<HOSTNAME>"}
```

```promql
100 * (
  1 - avg by (hostname) (
    rate(node_cpu_seconds_total{hostname="<HOSTNAME>",mode="idle"}[5m])
  )
)
```

```promql
node_memory_MemTotal_bytes{hostname="<HOSTNAME>"}
```

```promql
node_filesystem_size_bytes{hostname="<HOSTNAME>"}
```

VM101 passed all of these queries on 2026-09-01 and is present in the `hostname` label source.

Do not force dashboard variables to depend on `job="node"`; Alloy currently produces `job=integrations/unix` for VM101 metrics.

---

# Stage 10 - Alerting

A central scrape-style host-down rule such as:

```promql
up{job="node"} == 0
```

is not appropriate for a remote-written Alloy host.

Use an absence-based host signal, for example:

```promql
absent_over_time(
  node_uname_info{hostname="<HOSTNAME>"}[5m]
)
```

Minimum resource coverage should include:

| Condition | Starting point |
|---|---|
| Metrics missing | 5 minutes |
| Root filesystem warning | >85% |
| Root filesystem critical | >95% |
| Memory high | >90% for 10 minutes |
| CPU high | >90% for 15 minutes |
| Critical application/service failure | service-specific |

Test alert behaviour before treating it as operationally reliable.

---

# Stage 11 - Reboot persistence

```bash
sudo reboot
```

After reconnecting:

```bash
systemctl is-enabled alloy
systemctl is-active alloy
curl -fsS http://127.0.0.1:12345/-/ready
curl -fsS http://127.0.0.1:12345/-/healthy
```

Then:

1. re-query `node_uname_info` centrally;
2. generate another unique journal event;
3. prove it reaches Loki;
4. confirm no new failed units.

A configuration that only works until reboot does not pass commissioning.

---

# Acceptance gate

A new VM is observability-ready only when:

### Platform

- [x] Monitoring authority identified as `ids-01` unless deliberately changed.
- [x] Prometheus remote-write receiver enabled.
- [ ] Central endpoints reachable from the VM.

### Alloy

- [ ] Syntax/preflight passes.
- [ ] First-install check mode passes.
- [ ] Real deployment passes.
- [ ] Second deployment is idempotent.
- [ ] Alloy enabled and active.
- [ ] UI local-only.
- [ ] Readiness passes.
- [ ] Health passes.
- [ ] Journal access passes as `alloy`.

### Metrics

- [ ] `node_uname_info` visible.
- [ ] CPU/memory/filesystem metrics visible.
- [ ] Stable labels present.
- [ ] Duplicate path check passes.

### Logs

- [ ] Unique journal event visible in Loki.
- [ ] Actual stream labels recorded.

### Grafana

- [ ] Host appears in hostname data source.
- [ ] Core dashboard-source queries return data.
- [ ] Dashboard itself is usable for the host.

### Operations

- [ ] Host-loss/resource alert coverage exists.
- [ ] Reboot persistence passes.
- [ ] Configuration is in Git.
- [ ] No plaintext secrets are committed.

---

# VM101 commissioning record

Verified on 2026-09-01:

```text
VMID=101
VM_HOSTNAME=app-platform-01
VM_IP=192.168.2.253
VM_ROLE=application
ENVIRONMENT=homelab
PROMETHEUS_HOST=192.168.2.242
LOKI_HOST=192.168.2.242
ALLOY_VERSION=v1.19.2
```

Completed:

- [x] VM/cloud-init baseline.
- [x] Security hardening and hardening idempotence.
- [x] `ids-01` confirmed as Prometheus/Loki/Grafana authority.
- [x] Prometheus remote-write receiver enabled.
- [x] Prometheus recovered to 26/26 healthy scrape-target baseline after receiver change.
- [x] Alloy Ansible syntax check.
- [x] First-install check-mode handling.
- [x] Alloy installed and configured by Ansible.
- [x] Alloy v1.19.2 enabled/active.
- [x] UI bound to `127.0.0.1:12345`.
- [x] Readiness and health pass.
- [x] Journal access as `alloy` passes.
- [x] Second Ansible apply: `changed=0`, `failed=0`.
- [x] `node_uname_info` visible centrally as one series.
- [x] CPU, memory, boot-time and filesystem metrics visible.
- [x] Duplicate metrics path check passes.
- [x] Unique journal event visible in Loki.
- [x] Grafana dashboard-source PromQL queries return data.
- [x] Hostname label source includes `app-platform-01`.

Outstanding before observability closure:

- [ ] Confirm actual Grafana dashboard presentation/selector behaviour if required.
- [ ] Implement/validate alert coverage.
- [ ] Reboot VM101 and repeat metrics/log persistence proof.

Do not start PostgreSQL until the observability gate is closed.

---

# Rollback

Use Git/Ansible as the source of truth for Alloy rollback.

If central Prometheus remote-write support must be rolled back, remove only the receiver flag through the authoritative monitoring Compose source, validate Compose, recreate only Prometheus, and prove the previous target baseline returns.

Do not remove remote-write support while any commissioned Alloy host depends on it.

---

## Completion record

```text
VM hostname:
VM IP:
Role:
Environment:
Alloy version:
Prometheus destination:
Loki destination:
Alloy deploy: PASS / FAIL
Idempotence: PASS / FAIL
Metrics E2E: PASS / FAIL
Logs E2E: PASS / FAIL
Grafana data: PASS / FAIL
Duplicate check: PASS / FAIL
Alert coverage: PASS / FAIL
Reboot persistence: PASS / FAIL
Date:
Operator:
Notes:
```
