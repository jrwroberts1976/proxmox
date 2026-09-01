# Add Linux Metrics Monitoring with Grafana Alloy

## 1. Purpose

This runbook defines the standard Linux metrics path for new Proxmox VMs that already have Grafana Alloy installed.

```text
Linux VM
   |
   +--> prometheus.exporter.unix
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

For new VMs, this replaces a separate node_exporter service. Existing direct-scrape hosts may remain on the legacy compatibility path documented in `linux-monitoring-grafana.md`.

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

## 3. Preconditions

- Alloy installed and healthy.
- `127.0.0.1:12345` readiness and health pass.
- VM can reach `192.168.2.242:9090`.
- host has stable `hostname`, `role`, and `environment` labels.
- no second node_exporter/Alloy path is exporting the same host metrics.

Check:

```bash
systemctl is-active alloy
curl -fsS http://127.0.0.1:12345/-/ready
curl -fsS http://127.0.0.1:12345/-/healthy
curl -fsS http://192.168.2.242:9090/-/ready
```

---

## 4. Standard Alloy pipeline

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

Do not manually edit `/etc/alloy/config.alloy` on an Ansible-managed VM except for controlled troubleshooting; make permanent changes in Git.

---

## 5. Validation before restart

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

## 6. Prometheus acceptance

Do not use `/targets` as the acceptance test for an Alloy remote-written VM. Remote-written series are ingested by the receiver and do not create a normal central scrape target.

Use metric queries instead:

```promql
node_uname_info{hostname="<HOSTNAME>"}
```

Expected: exactly one host series.

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
role=<ROLE>
environment=homelab
```

VM101 validated values:

```text
hostname=app-platform-01
instance=app-platform-01
job=integrations/unix
role=application
environment=homelab
```

The `job` value above is the observed runtime result for the deployed Alloy integration. Do not assume a new Alloy host will have `job="node"`.

---

## 7. Duplicate collection gate

Run:

```promql
count by (hostname, instance, job) (
  node_uname_info{hostname="<HOSTNAME>"}
)
```

Normal new-VM expectation: one authoritative path.

For VM101 the validated result was:

```text
app-platform-01  app-platform-01  integrations/unix  1
```

If multiple paths appear, check for:

- direct `prometheus-node-exporter` scraping;
- multiple Alloy services;
- stale/mislabelled host identities;
- migration test pipelines left enabled.

---

## 8. Grafana acceptance

Current Linux/node dashboards provisioned on `ids-01` include:

```text
homelab-noc2.json
homelab-noc.json
linux-os-monitoring.json
```

Before altering a dashboard, prove the underlying Prometheus data exists.

Useful queries:

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

VM101 passed all four dashboard-source queries on 2026-09-01.

A host variable should use the stable `hostname` label rather than depending on an IP or a hard-coded `job="node"` assumption.

---

## 9. Alerting for remote-written hosts

A conventional central scrape alert such as:

```promql
up{job="node"} == 0
```

is not a reliable host-loss rule for an Alloy remote-written VM.

Prefer a stable metric absence check, for example:

```promql
absent_over_time(
  node_uname_info{hostname="<HOSTNAME>"}[5m]
)
```

Baseline resource coverage should include filesystem, memory and CPU thresholds appropriate to the workload.

---

## 10. Reboot persistence

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

Then re-query `node_uname_info` centrally.

---

## Acceptance checklist

- [ ] Alloy service active/healthy.
- [ ] `ids-01:9090` reachable.
- [ ] Remote-write receiver enabled on authoritative Prometheus.
- [ ] `node_uname_info` returns exactly one host series.
- [ ] CPU metrics visible.
- [ ] Memory metrics visible.
- [ ] Filesystem metrics visible.
- [ ] Stable labels present.
- [ ] Duplicate path check passes.
- [ ] Dashboard-source queries return data.
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
Duplicate path: PASS / FAIL
Grafana data: PASS / FAIL
Alert coverage: PASS / FAIL
Reboot persistence: PASS / FAIL
Date:
Operator:
Notes:
```
