# Linux Monitoring in Grafana Runbook

## 1. Purpose

This runbook defines the standard procedure for adding a Linux host or VM to the homelab monitoring platform using:

```text
Linux host
   |
   | node_exporter :9100
   v
Prometheus
   |
   v
Grafana
   |
   +--> dashboards
   +--> alerts
```

The objective is to make Linux monitoring repeatable, testable, and suitable for later automation through Ansible.

This procedure is intended for Debian-family Linux systems used in the Proxmox homelab. The Prometheus and Grafana locations may change during the Proxmox migration; the onboarding process remains the same.

---

## 2. Scope

This runbook covers:

- installing Prometheus `node_exporter` on a Linux host;
- validating the exporter locally;
- restricting access to the monitoring endpoint;
- adding the host to Prometheus;
- validating the Prometheus scrape;
- exposing the host in Grafana;
- creating or importing a Linux dashboard;
- establishing baseline alerting;
- acceptance testing;
- rollback and troubleshooting.

This runbook does **not** cover application-specific exporters such as PostgreSQL, Nginx, Zabbix, Docker/cAdvisor, or Proxmox API exporters. Those should be added separately after host-level monitoring is healthy.

---

## 3. Monitoring standard

Use the following defaults unless there is a documented reason to deviate.

| Item | Standard |
|---|---|
| Exporter | Prometheus `node_exporter` |
| Exporter TCP port | `9100` |
| Prometheus scrape interval | `15s` unless the existing job uses another value |
| Prometheus job | Reuse the existing Linux/node-exporter job; `node` is the preferred generic name |
| Grafana data source | Existing Prometheus data source |
| Host identification | Add explicit `hostname`, `role`, and `environment` target labels |
| Security | Port `9100` must not be Internet-facing; restrict to Prometheus where practical |
| Secrets | None required for the standard node_exporter endpoint |
| Deployment model | Manual procedure initially; Ansible should become the long-term implementation |

### Required labels

Every Linux target should carry these labels where practical:

```yaml
hostname: example-host
role: application
 environment: homelab
```

Recommended `role` values include:

- `hypervisor`
- `database`
- `web`
- `monitoring`
- `security`
- `dns`
- `application`
- `lab`

Keep label names and values stable. Grafana dashboards and alert routing may depend on them.

---

## 4. Preconditions

Before changing anything, confirm:

- [ ] The Linux host is reachable from the Prometheus host.
- [ ] The host has a stable IP address or stable DNS name.
- [ ] SSH/sudo access is available.
- [ ] Prometheus is currently healthy.
- [ ] Grafana is currently healthy.
- [ ] The Prometheus configuration location is known.
- [ ] The Prometheus service/container name is known.
- [ ] The host is not already scraped on port `9100`.
- [ ] Any host firewall policy is understood before opening port `9100`.

Do not add duplicate scrape targets for the same exporter.

---

## 5. Capture onboarding values

Record the values before starting.

```text
HOSTNAME=
HOST_IP=
HOST_ROLE=
ENVIRONMENT=homelab
PROMETHEUS_HOST=
PROMETHEUS_CONFIG=
PROMETHEUS_JOB=
```

Example:

```text
HOSTNAME=db-01
HOST_IP=192.168.2.100
HOST_ROLE=database
ENVIRONMENT=homelab
PROMETHEUS_HOST=TestServer
PROMETHEUS_CONFIG=/path/to/prometheus.yml
PROMETHEUS_JOB=node
```

Do not copy example addresses into production configuration without checking them.

---

# Stage 1 - Host baseline

## 6. Confirm host identity and health

On the Linux host:

```bash
hostnamectl
ip -br addr
uname -a
cat /etc/os-release
uptime
systemctl --failed
```

Expected result:

- hostname is correct;
- intended management IP is present;
- no unexpected failed services are introduced by this work.

Capture the host IP and hostname before continuing.

---

# Stage 2 - Install node_exporter

## 7. Debian / Ubuntu package installation

For Debian-family systems, prefer the distribution package unless there is a specific version requirement.

```bash
sudo apt update
sudo apt install -y prometheus-node-exporter
```

Enable and start it:

```bash
sudo systemctl enable --now prometheus-node-exporter
```

Check status:

```bash
systemctl --no-pager --full status prometheus-node-exporter
```

Expected result:

```text
Active: active (running)
```

---

## 8. Confirm port 9100

```bash
sudo ss -ltnp | grep ':9100'
```

Expected result: node_exporter is listening on TCP port `9100`.

Do **not** expose this port through the Internet router or a public reverse proxy.

---

## 9. Validate metrics locally

```bash
curl -fsS http://127.0.0.1:9100/metrics | head -40
```

Check important metric families:

```bash
curl -fsS http://127.0.0.1:9100/metrics | grep -E '^node_(uname_info|boot_time_seconds|cpu_seconds_total|memory_MemTotal_bytes|filesystem_size_bytes)' | head -30
```

Expected result: Prometheus-format `node_*` metrics are returned.

If this fails, do not continue to Prometheus configuration.

---

## 10. Optional collectors

The default collectors are sufficient for the initial host onboarding.

If systemd unit or process metrics are specifically required by a dashboard, additional collectors may be enabled after testing. Do not enable collectors simply because a dashboard supports them; additional collectors can increase metric volume and cardinality.

After changing exporter arguments, restart and revalidate:

```bash
sudo systemctl restart prometheus-node-exporter
systemctl --no-pager --full status prometheus-node-exporter
curl -fsS http://127.0.0.1:9100/metrics >/dev/null
```

---

# Stage 3 - Restrict exporter access

## 11. Network policy

The normal security model for the homelab is:

```text
Prometheus host ---> Linux host:9100    ALLOW
Other LAN clients -> Linux host:9100    optional / normally not required
Internet ---------> Linux host:9100    DENY
```

If UFW is in use, an example restriction is:

```bash
sudo ufw allow from <PROMETHEUS_IP> to any port 9100 proto tcp
```

Do not apply firewall commands blindly. Preserve existing SSH, management, application, monitoring, and cluster access rules.

If the host has no local firewall, ensure upstream network controls do not publish `9100` externally.

---

# Stage 4 - Validate from Prometheus

## 12. Test network reachability

From the Prometheus host:

```bash
curl -fsS http://<HOST_IP>:9100/metrics | head
```

Optional TCP check:

```bash
nc -vz <HOST_IP> 9100
```

Expected result: Prometheus can reach the exporter before its configuration is changed.

If local host access works but this test fails, investigate routing or firewalling first.

---

# Stage 5 - Add Prometheus target

## 13. Preserve the current configuration

Before editing the Prometheus configuration, create a local backup appropriate to the deployment.

Example:

```bash
cp prometheus.yml prometheus.yml.before-<HOSTNAME>
```

If the configuration is Git-managed, make the change in the authoritative repository rather than treating a container filesystem as the source of truth.

---

## 14. Reuse the existing node_exporter job

First find the existing Linux/node_exporter scrape job.

```bash
grep -nE 'job_name|9100' prometheus.yml
```

If a node_exporter job already exists, add the new target to it.

Avoid creating another job that scrapes the same host and port.

### Recommended target format

Use one `static_configs` entry per host when host-specific labels are required:

```yaml
scrape_configs:
  - job_name: node
    scrape_interval: 15s
    static_configs:
      - targets:
          - '192.168.2.100:9100'
        labels:
          hostname: 'db-01'
          role: 'database'
          environment: 'homelab'
```

For multiple hosts:

```yaml
scrape_configs:
  - job_name: node
    scrape_interval: 15s
    static_configs:
      - targets:
          - '192.168.2.70:9100'
        labels:
          hostname: 'PROXMOX'
          role: 'hypervisor'
          environment: 'homelab'

      - targets:
          - '192.168.2.100:9100'
        labels:
          hostname: 'db-01'
          role: 'database'
          environment: 'homelab'
```

The exact IPs above are examples only.

---

## 15. Validate Prometheus configuration

Never reload Prometheus before the configuration passes validation.

### Native Prometheus

```bash
promtool check config /etc/prometheus/prometheus.yml
```

### Docker Prometheus

If Prometheus runs in the `prometheus` container and the configuration is mounted at `/etc/prometheus/prometheus.yml`:

```bash
docker exec prometheus \
  promtool check config /etc/prometheus/prometheus.yml
```

Expected result:

```text
SUCCESS
```

If validation fails, restore/fix the configuration before continuing.

---

## 16. Reload Prometheus

Use the least disruptive supported method.

If lifecycle reload is enabled:

```bash
curl -fsS -X POST http://127.0.0.1:9090/-/reload
```

If lifecycle reload is not enabled, restart the service/container using the deployment's normal management method.

Examples:

```bash
sudo systemctl restart prometheus
```

or, from the appropriate Compose project:

```bash
docker compose restart prometheus
```

A restart causes a brief scrape gap, so configuration validation must happen first.

---

# Stage 6 - Validate Prometheus ingestion

## 17. Check the target

Use the Prometheus Targets page and confirm the new endpoint is `UP`.

For API-based validation:

```bash
curl -fsS --get \
  http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=up{instance="<HOST_IP>:9100"}' \
  | jq
```

Expected metric value:

```text
1
```

Also verify the target labels:

```promql
up{hostname="<HOSTNAME>"}
```

Expected labels include:

- `hostname`
- `role`
- `environment`
- `instance`
- `job`

---

## 18. Validate core Linux metrics

Run these in the Prometheus expression browser.

### Host availability

```promql
up{hostname="<HOSTNAME>"}
```

### CPU utilisation

```promql
100 - (
  avg by (hostname, instance) (
    rate(node_cpu_seconds_total{mode="idle"}[5m])
  ) * 100
)
```

### Memory utilisation

```promql
100 * (
  1 - (
    node_memory_MemAvailable_bytes
    /
    node_memory_MemTotal_bytes
  )
)
```

### Root filesystem utilisation

```promql
100 * (
  1 - (
    node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay|squashfs"}
    /
    node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay|squashfs"}
  )
)
```

### Load average

```promql
node_load1
```

### Uptime

```promql
time() - node_boot_time_seconds
```

Do not proceed to Grafana until Prometheus returns data for the new host.

---

# Stage 7 - Enable the host in Grafana

## 19. Confirm Prometheus data source

Grafana has built-in Prometheus data-source support.

If the existing homelab Prometheus data source is already healthy, reuse it. Do not create a second data source for each Linux host.

In Grafana Explore, select the Prometheus data source and run:

```promql
up{hostname="<HOSTNAME>"}
```

Expected result: `1`.

If Prometheus contains the metric but Grafana does not, troubleshoot the Grafana-to-Prometheus data source before changing node_exporter.

---

## 20. Use the existing homelab Linux dashboard

Preferred approach:

1. Open the existing Linux/host overview dashboard.
2. Confirm the new `hostname` appears in the host variable.
3. Select the host.
4. Confirm CPU, memory, filesystem, load, uptime, disk I/O, and network panels populate.
5. Confirm the selected host does not display another machine's data.

Dashboard variables should preferably filter on the explicit `hostname` label added to the Prometheus target.

Example variable query:

```promql
label_values(up{job="node"}, hostname)
```

If the existing Prometheus job has a different name, use that job name rather than changing the monitoring standard only to satisfy a dashboard variable.

---

## 21. Dashboard fallback - Node Exporter Full

If there is no established homelab Linux dashboard, Grafana's dashboard catalog contains **Node Exporter Full**, dashboard ID `1860`.

It is designed for Prometheus node_exporter metrics and commonly assumes a `job_name` of `node`.

Import procedure:

1. Open Grafana.
2. Open **Dashboards**.
3. Choose **New / Import**.
4. Enter dashboard ID `1860`.
5. Select the existing Prometheus data source.
6. Import the dashboard.
7. Verify the host appears and every major panel is populated.

Treat imported dashboards as a starting point. Homelab-standard dashboards should ultimately be provisioned from Git so changes are reproducible.

---

# Stage 8 - Baseline Grafana panels

## 22. Minimum dashboard coverage

Every production Linux host should expose at least:

- host UP/down state;
- uptime;
- CPU utilisation;
- 1/5/15 minute load;
- memory utilisation;
- swap utilisation where swap exists;
- filesystem utilisation;
- filesystem inode utilisation;
- disk read/write throughput;
- disk I/O latency/utilisation where available;
- network receive/transmit throughput;
- network errors/drops;
- host identity and kernel information;
- temperature metrics where the hardware/kernel exposes them.

For VM guests, temperature metrics may not be available and should not be treated as a failure.

---

# Stage 9 - Baseline alerting

## 23. Minimum alert set

At minimum, important Linux hosts should have alerts for:

| Alert | Suggested threshold |
|---|---|
| Host down | `up == 0` for 5 minutes |
| Root filesystem | > 85% warning |
| Root filesystem | > 95% critical |
| Memory | > 90% for 10 minutes |
| CPU | > 90% for 15 minutes |
| Filesystem read-only | immediate/short delay where applicable |
| Temperature | host-specific threshold where sensors are available |

Thresholds are starting points, not universal limits. Adjust them where workload behaviour justifies it.

### Example host-down rule

```yaml
groups:
  - name: linux-hosts
    rules:
      - alert: LinuxHostDown
        expr: up{job="node"} == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Linux host {{ $labels.hostname }} is down"
          description: "Prometheus cannot scrape {{ $labels.instance }} for more than 5 minutes."
```

### Example filesystem warning

```yaml
      - alert: LinuxFilesystemUsageHigh
        expr: |
          100 * (
            1 - (
              node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs"}
              /
              node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs"}
            )
          ) > 85
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Filesystem usage high on {{ $labels.hostname }}"
          description: "{{ $labels.mountpoint }} on {{ $labels.hostname }} is above 85% used."
```

Validate rule files with `promtool` before reloading Prometheus.

---

# Stage 10 - Acceptance test

## 24. Acceptance checklist

Monitoring onboarding is complete only when all applicable checks pass.

### Linux host

- [ ] `prometheus-node-exporter` package installed.
- [ ] `prometheus-node-exporter` enabled at boot.
- [ ] Service is `active (running)`.
- [ ] TCP `9100` is listening.
- [ ] Local `/metrics` request succeeds.
- [ ] Port `9100` is not exposed to the Internet.

### Prometheus

- [ ] Prometheus host can reach `<HOST_IP>:9100`.
- [ ] Configuration passes `promtool check config`.
- [ ] Prometheus reload/restart succeeds.
- [ ] Target state is `UP`.
- [ ] `up{hostname="<HOSTNAME>"}` returns `1`.
- [ ] `hostname`, `role`, and `environment` labels are correct.
- [ ] CPU metrics are present.
- [ ] Memory metrics are present.
- [ ] Filesystem metrics are present.
- [ ] Network metrics are present.

### Grafana

- [ ] Grafana Explore returns the host metric.
- [ ] Host appears in the dashboard host selector.
- [ ] CPU panel contains data.
- [ ] Memory panel contains data.
- [ ] Filesystem panel contains data.
- [ ] Network panel contains data.
- [ ] Uptime/host information is correct.
- [ ] No panels accidentally show another host.

### Alerting

- [ ] Host-down alert covers the target.
- [ ] Filesystem alert covers the target.
- [ ] Other required baseline alerts cover the target.
- [ ] Alert labels identify the host clearly.

**Gate:** monitoring is accepted only when Prometheus is scraping successfully and Grafana displays the correct host data.

---

# Stage 11 - Optional alert-path test

## 25. Controlled exporter outage test

Only perform this on a disposable or non-critical host, or during an approved test window.

Stop node_exporter:

```bash
sudo systemctl stop prometheus-node-exporter
```

Confirm Prometheus changes the target to `DOWN` and the configured host-down alert progresses as expected.

Immediately restore the exporter:

```bash
sudo systemctl start prometheus-node-exporter
```

Then confirm:

```bash
systemctl is-active prometheus-node-exporter
```

and:

```promql
up{hostname="<HOSTNAME>"}
```

returns `1` again.

---

# Rollback

## 26. Remove a host from monitoring

If the onboarding must be rolled back:

1. Remove the target from the authoritative Prometheus configuration.
2. Run `promtool check config`.
3. Reload/restart Prometheus.
4. Confirm the removed target no longer appears in active targets.
5. Remove any host-specific firewall allowance for TCP `9100` if no longer required.
6. Leave historical Grafana/Prometheus data to expire normally according to retention policy unless there is a specific reason to delete it.

If node_exporter itself must be removed:

```bash
sudo systemctl disable --now prometheus-node-exporter
sudo apt remove prometheus-node-exporter
```

Do not remove the package merely because Prometheus configuration is being corrected.

---

# Troubleshooting

## 27. Exporter does not start

```bash
systemctl --no-pager --full status prometheus-node-exporter
journalctl -u prometheus-node-exporter -n 100 --no-pager
```

Check:

- invalid command-line arguments;
- port `9100` already in use;
- package/service installation failure.

---

## 28. `curl localhost:9100` works but Prometheus cannot connect

Check:

```bash
sudo ss -ltnp | grep ':9100'
ip -br addr
```

From Prometheus:

```bash
ping -c 3 <HOST_IP>
nc -vz <HOST_IP> 9100
curl -v http://<HOST_IP>:9100/metrics
```

Likely causes:

- host firewall;
- wrong IP;
- routing/VLAN policy;
- exporter bound only to loopback;
- upstream firewall policy.

---

## 29. Prometheus target is DOWN

Inspect the target's `lastError` in Prometheus.

Common errors:

### Connection refused

Exporter is stopped or not listening on the expected address/port.

### Context deadline exceeded

Usually routing, packet loss, firewalling, or an unresponsive host.

### No route to host

Correct routing/IP/firewall before changing Prometheus.

---

## 30. Prometheus has data but Grafana does not

Run the same query in both Prometheus and Grafana Explore:

```promql
up{hostname="<HOSTNAME>"}
```

If Prometheus succeeds and Grafana fails, check:

- Grafana Prometheus data-source URL;
- Grafana-to-Prometheus network/Docker network connectivity;
- data-source health;
- dashboard variable filters;
- dashboard `job` assumptions;
- selected time range.

A Grafana error similar to:

```text
lookup prometheus on 127.0.0.11:53
```

is a Docker DNS/network-resolution problem between Grafana and Prometheus. It is not a node_exporter problem on the monitored Linux host.

---

## 31. Host appears by IP instead of hostname

Confirm the target has the expected static label:

```promql
up{instance="<HOST_IP>:9100"}
```

and inspect its labels.

If `hostname` is missing, correct the Prometheus target configuration and reload Prometheus.

Prefer fixing target metadata rather than embedding IP-to-host mappings independently in multiple dashboards.

---

## 32. Dashboard has partial data

Confirm the missing metric exists directly in Prometheus.

Examples:

```promql
node_cpu_seconds_total{hostname="<HOSTNAME>"}
node_memory_MemTotal_bytes{hostname="<HOSTNAME>"}
node_filesystem_size_bytes{hostname="<HOSTNAME>"}
node_network_receive_bytes_total{hostname="<HOSTNAME>"}
```

If Prometheus has the metrics, review the dashboard query and variable filters.

If Prometheus does not have the metric, determine whether the relevant node_exporter collector is enabled and supported on the target operating system.

---

# Automation target

## 33. Ansible implementation

This manual runbook is the operational specification for a future reusable Ansible role.

The Ansible role should eventually manage:

- node_exporter package installation;
- service enable/start state;
- optional collector arguments;
- host firewall allowance where policy permits;
- standard monitoring metadata;
- service validation.

Prometheus target management should also move to Git-managed configuration so adding a Linux VM through the Proxmox IaC pipeline can become:

```text
OpenTofu
   |
   v
VM created
   |
   v
cloud-init
   |
   v
Ansible
   +--> Linux baseline
   +--> node_exporter
   +--> service roles
   |
   v
Prometheus target
   |
   v
Grafana dashboard + alerts
```

The final goal is that a newly provisioned production Linux VM cannot pass its deployment gate until monitoring has also passed the acceptance checks in this runbook.

---

# References

- Prometheus documentation: Monitoring Linux host metrics with the Node Exporter — https://prometheus.io/docs/guides/node-exporter/
- Grafana documentation: Prometheus data source — https://grafana.com/docs/grafana/latest/datasources/prometheus/
- Grafana dashboard catalog: Node Exporter Full, dashboard 1860 — https://grafana.com/grafana/dashboards/1860-node-exporter-full/
