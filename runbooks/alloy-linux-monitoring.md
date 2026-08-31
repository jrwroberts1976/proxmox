# Add Linux Metrics Monitoring with Grafana Alloy

## 1. Purpose

This runbook defines the standard procedure for enabling Linux host metrics in Grafana using an existing Grafana Alloy installation.

The standard data path is:

```text
Linux host / VM
   |
   | prometheus.exporter.unix
   v
Grafana Alloy
   |
   | prometheus.scrape
   v
prometheus.remote_write
   |
   v
Prometheus
   |
   v
Grafana
```

`prometheus.exporter.unix` is Alloy's embedded node-exporter integration. It exposes the normal `node_*` metric families without requiring a separate `prometheus-node-exporter` systemd service.

This runbook assumes Alloy is already installed and healthy. The separate Alloy installation runbook should be completed first.

---

## 2. Scope

This runbook covers:

- host identity and preflight checks;
- enabling `prometheus.exporter.unix`;
- adding stable host labels;
- scraping the embedded exporter with Alloy;
- forwarding metrics to the central Prometheus remote-write receiver;
- validating Alloy configuration before restart;
- validating metrics in Prometheus and Grafana;
- dashboard and alert acceptance checks;
- avoiding duplicate node-exporter collection;
- rollback and troubleshooting;
- the future Ansible implementation target.

It does not install Prometheus, Grafana, or Alloy.

---

## 3. Standard

| Item | Standard |
|---|---|
| Linux metrics collector | `prometheus.exporter.unix` in Alloy |
| Scrape component | `prometheus.scrape` |
| Scrape interval | `15s` |
| Metrics destination | Central Prometheus remote-write endpoint |
| Prometheus endpoint | `http://<PROMETHEUS_LAN_IP>:9090/api/v1/write` |
| Host label | `hostname` |
| Role label | `role` |
| Environment label | `environment` |
| Environment value | `homelab` unless explicitly different |
| Alloy configuration | `/etc/alloy/config.alloy` |
| Alloy service | `alloy.service` |

Use a LAN-reachable Prometheus IP or DNS name. A Docker-only service name such as `prometheus` will not resolve from a systemd Alloy service running on another host.

---

## 4. Preconditions

Confirm before changing the host:

- [ ] Alloy is installed.
- [ ] `alloy.service` is active.
- [ ] `/etc/alloy/config.alloy` exists.
- [ ] The Alloy UI/health endpoint is available locally.
- [ ] The central Prometheus service is healthy.
- [ ] Prometheus has `--web.enable-remote-write-receiver` enabled.
- [ ] TCP `9090` is reachable from this Linux host to Prometheus.
- [ ] The host has a stable hostname.
- [ ] The intended `role` and `environment` labels are known.
- [ ] A separate node_exporter is not already sending the same metrics into Prometheus under the same identity.

### Capture values

```text
HOSTNAME=
HOST_ROLE=
ENVIRONMENT=homelab
PROMETHEUS_HOST=
PROMETHEUS_PORT=9090
```

---

# Stage 1 - Baseline

## 5. Confirm Alloy and host health

```bash
hostnamectl
systemctl --no-pager --full status alloy
curl -fsS http://127.0.0.1:12345/-/ready
curl -fsS http://127.0.0.1:12345/-/healthy
```

Expected result:

- Alloy is active;
- readiness succeeds;
- health succeeds.

Capture the current configuration before editing:

```bash
sudo cp /etc/alloy/config.alloy \
  /etc/alloy/config.alloy.before-linux-metrics
```

---

# Stage 2 - Confirm Prometheus remote-write receiver

## 6. Test network path

From the Linux host:

```bash
curl -fsS http://<PROMETHEUS_HOST>:9090/-/ready
```

Optional TCP check:

```bash
nc -vz <PROMETHEUS_HOST> 9090
```

If this fails, fix routing, DNS, firewalling, or Prometheus availability before changing Alloy.

Prometheus must have its remote-write receiver enabled with:

```text
--web.enable-remote-write-receiver
```

The receiver endpoint is:

```text
/api/v1/write
```

Do not confuse this with Prometheus `remote_write` configuration used to send Prometheus data elsewhere.

---

# Stage 3 - Add Linux metrics pipeline

## 7. Baseline Alloy configuration

Add the following logical pipeline to `/etc/alloy/config.alloy`.

Replace the placeholders before applying it.

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
    url = "http://<PROMETHEUS_HOST>:9090/api/v1/write"
  }
}
```

This creates the following path:

```text
prometheus.exporter.unix.linux
        |
        v
discovery.relabel.linux
        |
        v
prometheus.scrape.linux
        |
        v
prometheus.remote_write.homelab
```

### Why relabel here

Using explicit labels makes dashboards and alerts independent of IP-address changes:

```text
hostname=<stable host name>
role=<database|web|monitoring|application|...>
environment=homelab
```

Keep these label names consistent across hosts.

---

## 8. Optional collector tuning

Start with the default collectors. Do not enable every optional collector simply because it exists.

Collector changes should be justified by a dashboard, alert, or operational requirement.

Examples of useful host areas include:

- CPU;
- memory;
- load;
- filesystem;
- disk I/O;
- network;
- boot time;
- uname/kernel identity;
- thermal sensors where exposed by the host.

Virtual machines may not expose physical temperature sensors. That is not a monitoring failure.

---

# Stage 4 - Validate before restart

## 9. Validate Alloy syntax

```bash
sudo alloy validate /etc/alloy/config.alloy
```

Expected result: configuration validation succeeds with no error.

Do not restart Alloy with an invalid configuration.

Review the effective change:

```bash
sudo diff -u \
  /etc/alloy/config.alloy.before-linux-metrics \
  /etc/alloy/config.alloy
```

---

# Stage 5 - Apply

## 10. Restart Alloy

```bash
sudo systemctl restart alloy
```

Immediately validate:

```bash
systemctl --no-pager --full status alloy
curl -fsS http://127.0.0.1:12345/-/ready
curl -fsS http://127.0.0.1:12345/-/healthy
```

Check logs:

```bash
journalctl -u alloy -n 100 --no-pager
```

Look specifically for:

- configuration evaluation errors;
- connection refused;
- DNS resolution failures;
- HTTP 404/405 responses from Prometheus;
- repeated remote-write retries;
- permission errors.

---

# Stage 6 - Validate the Alloy pipeline

## 11. Alloy component health

Use a local SSH tunnel if accessing the Alloy UI remotely:

```bash
ssh -L 12345:127.0.0.1:12345 <HOST>
```

Then open:

```text
http://127.0.0.1:12345
```

Confirm the following components are healthy:

- `prometheus.exporter.unix.linux`;
- `discovery.relabel.linux`;
- `prometheus.scrape.linux`;
- `prometheus.remote_write.homelab`.

Do not expose the Alloy UI publicly to perform this check.

---

# Stage 7 - Validate Prometheus ingestion

## 12. Query the host

On Prometheus or through Grafana Explore:

```promql
node_uname_info{hostname="<HOSTNAME>"}
```

Expected result: one series for the new host.

Check core metrics:

```promql
node_memory_MemTotal_bytes{hostname="<HOSTNAME>"}
```

```promql
node_boot_time_seconds{hostname="<HOSTNAME>"}
```

```promql
node_cpu_seconds_total{hostname="<HOSTNAME>"}
```

```promql
node_filesystem_size_bytes{hostname="<HOSTNAME>"}
```

Confirm labels include:

- `hostname`;
- `role`;
- `environment`.

---

## 13. Detect duplicate collection

If a traditional node_exporter target already exists, check whether the same host is appearing twice.

Useful query:

```promql
count by (hostname) (
  node_uname_info{hostname="<HOSTNAME>"}
)
```

The expected cardinality depends on the chosen architecture, but the normal homelab standard is one authoritative Linux host metrics pipeline.

Do not run both direct Prometheus node_exporter scraping and Alloy remote-write for the same host unless there is a deliberate migration/validation reason.

---

# Stage 8 - Grafana validation

## 14. Validate dashboard visibility

In Grafana Explore, query:

```promql
node_uname_info{hostname="<HOSTNAME>"}
```

Then validate the Linux dashboard.

Minimum panels should populate for:

- host identity;
- uptime;
- CPU utilisation;
- load;
- memory;
- swap where present;
- filesystems;
- disk I/O;
- network throughput;
- network errors/drops.

Where a dashboard variable exists, prefer the stable host label:

```promql
label_values(node_uname_info, hostname)
```

---

# Stage 9 - Alert acceptance

## 15. Baseline alerts

A production Linux VM should ultimately participate in at least:

| Alert | Starting point |
|---|---|
| Host metrics missing | no samples for 5 minutes |
| Root filesystem warning | > 85% |
| Root filesystem critical | > 95% |
| Memory high | > 90% for 10 minutes |
| CPU high | > 90% for 15 minutes |
| Temperature high | host-specific where sensors exist |

Because Alloy remote-writes metrics, a conventional `up{job="node"}` scrape alert on the central Prometheus server may not represent this host in the same way as a directly scraped node_exporter target.

For Alloy-fed hosts, consider absence-based checks against a stable metric, for example:

```promql
absent_over_time(
  node_uname_info{hostname="<HOSTNAME>"}[5m]
)
```

Validate the final alert model in the monitoring repository before relying on it operationally.

---

# Stage 10 - Acceptance gate

## 16. Acceptance checklist

The host is considered successfully monitored only when all applicable checks pass:

- [ ] Alloy remains active.
- [ ] Alloy readiness succeeds.
- [ ] Alloy health succeeds.
- [ ] `prometheus.exporter.unix` is healthy.
- [ ] `prometheus.scrape` is healthy.
- [ ] `prometheus.remote_write` is healthy.
- [ ] Prometheus receives `node_*` metrics for the host.
- [ ] `hostname` is correct.
- [ ] `role` is correct.
- [ ] `environment` is correct.
- [ ] No unintended duplicate host metrics exist.
- [ ] Grafana dashboard panels populate.
- [ ] A host-loss alert strategy exists.
- [ ] No secrets were added to Git plaintext.

---

# Rollback

## 17. Restore previous configuration

```bash
sudo cp \
  /etc/alloy/config.alloy.before-linux-metrics \
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

Confirm health:

```bash
curl -fsS http://127.0.0.1:12345/-/ready
curl -fsS http://127.0.0.1:12345/-/healthy
```

Rollback should remove only the newly introduced Linux metrics pipeline and must not break an existing Alloy logging pipeline.

---

# Troubleshooting

## 18. Metrics present in Alloy but absent in Prometheus

Check:

```bash
journalctl -u alloy -n 200 --no-pager
curl -fsS http://<PROMETHEUS_HOST>:9090/-/ready
```

Verify Prometheus was started with:

```text
--web.enable-remote-write-receiver
```

Check that Alloy uses:

```text
http://<PROMETHEUS_HOST>:9090/api/v1/write
```

and not a Docker-only hostname unless Alloy is on that same Docker network.

---

## 19. DNS failure

Typical error:

```text
lookup prometheus ... server misbehaving
```

If Alloy runs as a systemd service on a Linux host, use a LAN-resolvable DNS name or stable LAN IP for the Prometheus endpoint.

Docker embedded DNS names such as `prometheus` only work inside the Docker networks where that service alias exists.

---

## 20. Duplicate host in Grafana

Search:

```promql
count by (hostname, instance, job) (
  node_uname_info{hostname="<HOSTNAME>"}
)
```

Identify whether the host is being:

- scraped directly by Prometheus from port `9100`;
- collected by Alloy and remote-written;
- collected by two Alloy instances.

Choose one authoritative production path.

---

# Future Ansible target

## 21. Automation model

The eventual Ansible implementation should extend the Alloy role with variables similar to:

```yaml
alloy_linux_metrics_enabled: true
alloy_prometheus_remote_write_url: "http://prometheus.example:9090/api/v1/write"
alloy_host_role: "application"
alloy_environment: "homelab"
alloy_linux_metrics_scrape_interval: "15s"
```

Ansible should:

1. render the Alloy configuration;
2. run `alloy validate` before restart;
3. restart only when configuration changes;
4. verify `/-/ready` and `/-/healthy`;
5. fail the deployment if validation does not pass.

---

## 22. Completion record

Record after commissioning:

```text
Host:
Role:
Environment:
Prometheus destination:
Alloy version:
Date enabled:
Config validation: PASS / FAIL
Prometheus metrics visible: PASS / FAIL
Grafana dashboard visible: PASS / FAIL
Duplicate metrics check: PASS / FAIL
Alert coverage checked: PASS / FAIL
Operator:
Notes:
```
