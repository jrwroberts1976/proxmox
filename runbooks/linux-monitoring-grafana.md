# Linux Monitoring in Grafana Runbook

## 1. Purpose

This runbook is the **legacy/direct-scrape compatibility path** for Linux hosts that already use `prometheus-node-exporter` on TCP/9100.

It is not the preferred onboarding path for new Proxmox VMs.

Preferred new-VM path:

```text
Linux VM
   |
   +--> Grafana Alloy
          |
          +--> prometheus.exporter.unix
          +--> prometheus.remote_write
                   |
                   v
             ids-01 Prometheus
```

Legacy compatibility path covered here:

```text
Linux host
   |
   +--> node_exporter :9100
             |
             v
       ids-01 Prometheus
             |
             v
          Grafana
```

Use `alloy-linux-monitoring.md` and `linux-vm-observability-bootstrap.md` for new Proxmox VMs.

---

## 2. Current monitoring authority

Verified 2026-09-01:

```text
Prometheus/Grafana authority: ids-01
ids-01 LAN IP:               192.168.2.242
Prometheus:                  http://192.168.2.242:9090
Grafana:                     https://grafana.jrwroberts.co.uk/
```

Grafana's Prometheus datasource inside the monitoring Docker network is:

```text
http://prometheus:9090
```

Do not use TestServer as the default Prometheus authority for new host onboarding. The homelab contains more than one Prometheus instance.

---

## 3. When to use this runbook

Use this path only when:

- an existing host is already directly scraped on port `9100`;
- migration risk makes immediate conversion to Alloy undesirable;
- the design explicitly requires central Prometheus pull rather than Alloy remote write.

Do not run direct node_exporter and Alloy `prometheus.exporter.unix` for the same production host unless a temporary migration comparison is intentional.

---

## 4. Standard direct-scrape values

| Item | Standard |
|---|---|
| Exporter | `prometheus-node-exporter` |
| Port | `9100` |
| Scraper | authoritative Prometheus on `ids-01` |
| Scrape interval | normally `15s` |
| Required labels | `hostname`, `role`, `environment` |
| Environment | `homelab` |
| Security | restrict port 9100 to trusted monitoring/LAN paths |

Do not assume the Prometheus job must be called `node`. Reuse the established job structure for the current monitoring configuration.

---

# Stage 0 - Preflight

Before changing anything:

- verify the host is not already represented through Alloy;
- verify `ids-01` can route to the host;
- verify port `9100` is not already in use by another service;
- verify authoritative Prometheus is healthy;
- capture the current target baseline.

On the host:

```bash
hostnamectl
ip -br addr
systemctl --failed
ss -ltnp | grep ':9100' || true
```

On `ids-01`:

```bash
curl -fsS http://127.0.0.1:9090/-/ready
```

---

# Stage 1 - Install node_exporter

Debian-family hosts:

```bash
sudo apt-get update
sudo apt-get install -y prometheus-node-exporter
sudo systemctl enable --now prometheus-node-exporter
```

Validate locally:

```bash
systemctl is-enabled prometheus-node-exporter
systemctl is-active prometheus-node-exporter
curl -fsS http://127.0.0.1:9100/metrics | head -40
```

Confirm core metrics:

```bash
curl -fsS http://127.0.0.1:9100/metrics \
  | grep -E '^node_(uname_info|boot_time_seconds|cpu_seconds_total|memory_MemTotal_bytes|filesystem_size_bytes)' \
  | head -30
```

---

# Stage 2 - Restrict access

Preferred network model:

```text
ids-01 -> host:9100   ALLOW
Internet -> host:9100 DENY
```

If UFW is in use, a scoped example is:

```bash
sudo ufw allow from 192.168.2.242 to any port 9100 proto tcp
```

Do not apply firewall commands blindly. Preserve SSH and existing service access.

---

# Stage 3 - Prove reachability from ids-01

From `ids-01`:

```bash
curl -fsS http://<HOST_IP>:9100/metrics | head
```

If local exporter access works but this fails, fix routing/firewalling before editing Prometheus.

---

# Stage 4 - Add the target to authoritative Prometheus

Current authoritative monitoring Compose project:

```text
/home/james/docker/stacks/monitoring/docker-compose.yml
```

Current Prometheus configuration is mounted from:

```text
/home/james/docker/data/monitoring/prometheus/
```

Use the existing configuration structure and source-control workflow. Do not edit the container filesystem as the source of truth.

Example target shape:

```yaml
- targets:
    - '<HOST_IP>:9100'
  labels:
    hostname: '<HOSTNAME>'
    role: '<ROLE>'
    environment: 'homelab'
```

Validate the running configuration before reload:

```bash
docker exec prometheus \
  promtool check config /etc/prometheus/prometheus.yml
```

Then use the least disruptive supported apply path. The current Prometheus command includes `--web.enable-lifecycle`, so a validated config may be reloaded with:

```bash
curl -fsS -X POST http://127.0.0.1:9090/-/reload
```

Re-check readiness and targets after any change.

---

# Stage 5 - Prometheus acceptance

For direct-scrape hosts, `up` is meaningful:

```promql
up{hostname="<HOSTNAME>"}
```

Expected: `1`.

Core metrics:

```promql
node_uname_info{hostname="<HOSTNAME>"}
node_memory_MemTotal_bytes{hostname="<HOSTNAME>"}
node_boot_time_seconds{hostname="<HOSTNAME>"}
node_cpu_seconds_total{hostname="<HOSTNAME>"}
node_filesystem_size_bytes{hostname="<HOSTNAME>"}
```

Confirm the endpoint appears `UP` in Prometheus targets.

---

# Stage 6 - Grafana acceptance

Current provisioned Linux/node dashboards on `ids-01` include:

```text
homelab-noc2.json
homelab-noc.json
linux-os-monitoring.json
```

Use the stable `hostname` label for host selection where possible.

Do not force a dashboard to depend on `job="node"` if the established Prometheus job uses a different name.

Minimum data should include:

- identity/kernel;
- uptime;
- CPU/load;
- memory;
- filesystem;
- disk I/O;
- network traffic/errors.

Temperature data may legitimately be absent on VMs.

---

# Stage 7 - Duplicate gate

Before closing onboarding, run:

```promql
count by (hostname, instance, job) (
  node_uname_info{hostname="<HOSTNAME>"}
)
```

Investigate unexpected multiple paths.

A new Proxmox VM should normally use Alloy instead of this runbook.

---

# Stage 8 - Alerting

For a directly scraped exporter, a host-down rule may use `up`, for example:

```promql
up{hostname="<HOSTNAME>"} == 0
```

Do not reuse that assumption for Alloy remote-written hosts; use absence-based checks such as `absent_over_time(node_uname_info[5m])` there.

---

# Rollback

To remove a newly added direct-scrape host:

1. remove only its Prometheus target from the Git-managed configuration;
2. validate with `promtool`;
3. reload Prometheus;
4. confirm the target disappeared;
5. disable/remove node_exporter on the host only if it is no longer required.

Do not disrupt other targets in the same scrape job.

---

## Acceptance checklist

- [ ] This host genuinely requires the legacy direct-scrape path.
- [ ] No Alloy duplicate path exists.
- [ ] node_exporter enabled and active.
- [ ] Local `/metrics` works.
- [ ] `ids-01` can reach port 9100.
- [ ] Prometheus config validates.
- [ ] Target is `UP`.
- [ ] Core `node_*` metrics exist.
- [ ] Grafana data is visible.
- [ ] Duplicate check passes.
- [ ] Appropriate `up` alerting exists.
- [ ] Port 9100 is not Internet-exposed.

---

## Completion record

```text
Host:
IP:
Role:
Prometheus authority: ids-01 / exception
Exporter version:
Prometheus job:
Target UP: PASS / FAIL
Grafana data: PASS / FAIL
Duplicate check: PASS / FAIL
Alert coverage: PASS / FAIL
Date:
Operator:
Notes:
```
