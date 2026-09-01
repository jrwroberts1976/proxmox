# Add Linux Metrics Monitoring with Grafana Alloy

## 1. Purpose

This runbook defines the standard Linux metrics path for new Proxmox VMs that already have Grafana Alloy installed.

```text
Linux VM
   |
   +--> prometheus.exporter.unix
            |
            +--> discovery.relabel
            |        |
            |        +--> hostname=<stable name>
            |        +--> host=<stable name>
            |        +--> job=linux-hosts
            |        +--> role=<role>
            |        +--> environment=homelab
            |
            +--> prometheus.scrape
                     |
                     +--> prometheus.remote_write
                              |
                              v
                     ids-01 Prometheus
                              |
                              v
                           Grafana
```

For new VMs this replaces a separate node_exporter service. Existing direct-scrape hosts may remain on the legacy compatibility path documented in `linux-monitoring-grafana.md`.

---

## 2. Current authority and endpoints

Verified 2026-09-01:

```text
Prometheus authority: ids-01
Prometheus LAN IP:    192.168.2.242
Readiness:            http://192.168.2.242:9090/-/ready
Remote write:         http://192.168.2.242:9090/api/v1/write
Grafana:              https://grafana.jrwroberts.co.uk/
```

Prometheus on `ids-01` is running with:

```text
--web.enable-remote-write-receiver
```

Do not send a new VM to another reachable Prometheus instance without deliberately changing the monitoring architecture and documentation.

---

## 3. Established Grafana compatibility contract

The provisioned `Linux OS Monitoring` dashboard on `ids-01` was inspected on 2026-09-01.

Its host selector is:

```text
label_values(up{job="linux-hosts"}, host)
```

Its Linux panels use the same established label model:

```promql
up{job="linux-hosts",host=~"$host"}
node_uname_info{job="linux-hosts",host=~"$host"}
node_cpu_seconds_total{job="linux-hosts",host=~"$host"}
node_memory_MemTotal_bytes{job="linux-hosts",host=~"$host"}
node_filesystem_size_bytes{job="linux-hosts",host=~"$host"}
```

Therefore new Alloy-managed Linux hosts must provide both:

```text
job=linux-hosts
host=<stable hostname>
```

The `hostname` label remains the canonical host identity for new queries, logs and alerting. Keeping both `host` and `hostname` preserves compatibility without forcing a destructive rewrite of the existing Grafana dashboard.

Do not remove the compatibility labels until Grafana dashboards and alerts have been deliberately migrated to a new label contract.

---

## 4. Preconditions

- Alloy installed and healthy.
- `127.0.0.1:12345` readiness and health pass.
- VM can reach `192.168.2.242:9090`.
- host has stable `hostname`, `host`, `role`, and `environment` labels.
- metrics use `job=linux-hosts` for existing dashboard compatibility.
- no second node_exporter/Alloy path is exporting the same host metrics.

Check:

```bash
systemctl is-active alloy
curl -fsS http://127.0.0.1:12345/-/ready
curl -fsS http://127.0.0.1:12345/-/healthy
curl -fsS http://192.168.2.242:9090/-/ready
```

---

## 5. Standard Alloy pipeline

```alloy
prometheus.exporter.unix "linux" {
}

discovery.relabel "linux" {
  targets = prometheus.exporter.unix.linux.targets

  rule {
    target_label = "hostname"
    replacement  = "<HOSTNAME>"
  }

  rule {
    target_label = "host"
    replacement  = "<HOSTNAME>"
  }

  rule {
    target_label = "job"
    replacement  = "linux-hosts"
  }

  rule {
    target_label = "role"
    replacement  = "<HOST_ROLE>"
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
```

The authoritative implementation is rendered by:

```text
ansible/roles/alloy/templates/config.alloy.j2
```

Defaults controlling the compatibility labels are:

```yaml
alloy_linux_metrics_job: linux-hosts
alloy_linux_metrics_host_label: "{{ alloy_hostname }}"
```

Do not manually edit `/etc/alloy/config.alloy` on an Ansible-managed VM except for controlled troubleshooting; make permanent changes in Git.

---

## 6. Validation before restart

```bash
alloy validate /etc/alloy/config.alloy
```

The Ansible role performs validation before any managed restart.

After apply:

```bash
systemctl is-active alloy
curl -fsS http://127.0.0.1:12345/-/ready
curl -fsS http://127.0.0.1:12345/-/healthy
journalctl -u alloy -n 100 --no-pager
```

---

## 7. Prometheus acceptance

Do not use `/targets` as the acceptance test for an Alloy remote-written VM. Remote-written series are ingested by the receiver and do not create a normal central scrape target.

Canonical identity query:

```promql
node_uname_info{hostname="<HOSTNAME>"}
```

Dashboard-compatibility query:

```promql
node_uname_info{job="linux-hosts",host="<HOSTNAME>"}
```

Both should resolve to the same authoritative host series after the relabelled data has arrived.

Core checks:

```promql
node_memory_MemTotal_bytes{hostname="<HOSTNAME>"}
node_boot_time_seconds{hostname="<HOSTNAME>"}
node_cpu_seconds_total{hostname="<HOSTNAME>"}
node_filesystem_size_bytes{hostname="<HOSTNAME>"}
```

Expected labels:

```text
hostname=<HOSTNAME>
host=<HOSTNAME>
job=linux-hosts
role=<ROLE>
environment=homelab
```

### VM101 migration note

Before the dashboard-compatibility correction, VM101 was observed as:

```text
hostname=app-platform-01
instance=app-platform-01
job=integrations/unix
role=application
environment=homelab
```

That proved ingestion but did **not** satisfy the existing Linux dashboard selector because the dashboard requires `job="linux-hosts"` and `host`.

After applying the corrected Alloy role, the current series must be verified with the compatibility query above before the Grafana gate is closed.

---

## 8. Duplicate collection gate

Run:

```promql
count by (hostname, host, instance, job) (
  node_uname_info{hostname="<HOSTNAME>"}
)
```

Normal new-VM expectation: one current authoritative path.

During a label migration, the old label set may remain queryable briefly because Prometheus retains historical samples. Use an instant query and allow normal scrape/remote-write propagation before deciding that two active pipelines exist.

If multiple current paths appear, check for:

- direct `prometheus-node-exporter` scraping;
- multiple Alloy services;
- stale/mislabelled host identities;
- migration test pipelines left enabled.

---

## 9. Grafana acceptance

Current Linux/node dashboards provisioned on `ids-01` include:

```text
homelab-noc2.json
homelab-noc.json
linux-os-monitoring.json
```

For the established `linux-os-monitoring.json` dashboard, prove the host selector can resolve the VM:

```promql
up{job="linux-hosts",host="<HOSTNAME>"}
```

Then prove representative panel queries:

```promql
node_uname_info{job="linux-hosts",host="<HOSTNAME>"}
```

```promql
100 - (
  avg by(host) (
    rate(node_cpu_seconds_total{job="linux-hosts",host="<HOSTNAME>",mode="idle"}[5m])
  ) * 100
)
```

```promql
node_memory_MemTotal_bytes{job="linux-hosts",host="<HOSTNAME>"}
```

```promql
node_filesystem_size_bytes{job="linux-hosts",host="<HOSTNAME>"}
```

Acceptance requires the host to appear in the dashboard variable and the core panels to populate. Prometheus data existing under only `hostname`/`integrations/unix` is not sufficient for this particular dashboard.

---

## 10. Alerting for remote-written hosts

Because Alloy performs the local scrape, the remote-written `up` series can be used by existing dashboard logic while samples continue to arrive, but a central Prometheus scrape-target state does not exist for the VM.

For robust host-loss alerting, prefer absence detection against a stable series, for example:

```promql
absent_over_time(
  node_uname_info{hostname="<HOSTNAME>"}[5m]
)
```

Baseline resource coverage should include filesystem, memory and CPU thresholds appropriate to the workload.

---

## 11. Reboot persistence

After commissioning:

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

Then re-query both canonical and dashboard-compatible `node_uname_info` selectors centrally.

---

## Acceptance checklist

- [ ] Alloy service active/healthy.
- [ ] `ids-01:9090` reachable.
- [ ] Remote-write receiver enabled on authoritative Prometheus.
- [ ] `node_uname_info{hostname="<HOSTNAME>"}` returns one current host series.
- [ ] `job=linux-hosts` is present on Alloy node metrics.
- [ ] `host=<HOSTNAME>` is present on Alloy node metrics.
- [ ] CPU metrics visible.
- [ ] Memory metrics visible.
- [ ] Filesystem metrics visible.
- [ ] Duplicate path check passes.
- [ ] `linux-os-monitoring` host selector includes the VM.
- [ ] Dashboard core panels populate.
- [ ] Host-loss alert strategy uses a suitable remote-write signal.
- [ ] Reboot persistence passes.

---

## Completion record

```text
Host:
Role:
Environment:
Prometheus destination:
Alloy version:
Config validation: PASS / FAIL
Metrics E2E: PASS / FAIL
Dashboard label compatibility: PASS / FAIL
Duplicate path: PASS / FAIL
Grafana dashboard: PASS / FAIL
Alert coverage: PASS / FAIL
Reboot persistence: PASS / FAIL
Date:
Operator:
Notes:
```
