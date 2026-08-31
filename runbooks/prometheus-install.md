# Prometheus Installation Runbook

## 1. Purpose

This runbook defines the standard procedure for deploying Prometheus as the central metrics store/query service for the Proxmox homelab.

The target architecture is:

```text
Linux hosts / VMs
   |
   +--> Alloy prometheus.exporter.unix
   |       |
   |       +--> prometheus.remote_write
   |
   +--> direct exporters where required
           |
           v
Debian monitoring / Docker VM
           |
           +--> Prometheus :9090
           |
           +--> Grafana
```

Prometheus remains the source queried by Grafana for infrastructure metrics. The homelab standard also allows Alloy hosts to send Linux metrics to the Prometheus remote-write receiver.

---

## 2. Scope

This runbook covers:

- Docker Compose deployment on the monitoring VM;
- persistent TSDB storage;
- baseline Prometheus configuration;
- enabling the remote-write receiver for Alloy clients;
- safe configuration validation;
- reload/restart procedures;
- health and API validation;
- Grafana datasource configuration;
- backup and retention considerations;
- upgrade, rollback, and troubleshooting;
- future IaC automation.

It does not define every scrape target or alert rule. Service-specific exporters and alert rules should be added after the Prometheus service is healthy.

---

## 3. Standard

| Item | Standard |
|---|---|
| Deployment | Docker Compose |
| Container image | `prom/prometheus:<PINNED_VERSION>` |
| Container port | `9090` |
| Host/LAN port | `9090` |
| Config path in container | `/etc/prometheus/prometheus.yml` |
| TSDB path | `/prometheus` |
| Initial retention | `30d` unless capacity evidence supports another value |
| Config validation | `promtool check config` |
| Reload endpoint | `POST /-/reload` |
| Remote-write receiver | Enabled |
| Alloy write endpoint | `http://<MONITORING_VM_IP>:9090/api/v1/write` |
| Grafana datasource | `http://prometheus:9090` on internal Docker network |

Pin a tested Prometheus version. Do not deploy `latest` as the operational standard.

---

## 4. Security principles

1. TCP `9090` must not be directly exposed to the Internet.
2. Restrict access to trusted LAN/management networks.
3. Alloy clients need access to `/api/v1/write` when using remote write.
4. Grafana should use the internal Docker network where possible.
5. If authentication/TLS is required across a trust boundary, use an approved reverse proxy or Prometheus web configuration rather than exposing an unauthenticated service publicly.
6. Do not put credentials or private keys in Git plaintext.

---

## 5. Preconditions

Confirm:

- [ ] Monitoring VM is healthy.
- [ ] Docker Engine is healthy.
- [ ] Docker Compose v2 is available.
- [ ] Persistent storage is available.
- [ ] TCP `9090` is unused.
- [ ] A tested Prometheus version is selected.
- [ ] Grafana location/network is known.
- [ ] Intended retention fits available disk.
- [ ] Time synchronisation on the monitoring VM is healthy.

Capture:

```text
MONITORING_VM_IP=
PROMETHEUS_VERSION=
PROMETHEUS_STACK_PATH=
PROMETHEUS_RETENTION=30d
```

---

# Stage 1 - Prepare stack

## 6. Create directories

Example:

```bash
sudo mkdir -p /opt/homelab-observability/prometheus/config
sudo chown -R "$USER":"$USER" /opt/homelab-observability
cd /opt/homelab-observability/prometheus
```

Recommended structure:

```text
prometheus/
├── compose.yml
├── config/
│   ├── prometheus.yml
│   └── rules/
└── README.md              # optional local operations note
```

If an authoritative monitoring-stack repository already exists, use that location instead.

---

# Stage 2 - Baseline configuration

## 7. Create `prometheus.yml`

Create `config/prometheus.yml`:

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    environment: homelab
    prometheus: central

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - localhost:9090
```

Create the rules directory even if it is initially empty:

```bash
mkdir -p config/rules
```

This baseline intentionally starts small. Add node exporters, application exporters, and alert rules only after Prometheus itself passes acceptance checks.

---

# Stage 3 - Docker Compose definition

## 8. Create Compose service

Create `compose.yml`:

```yaml
services:
  prometheus:
    image: prom/prometheus:<PINNED_VERSION>
    container_name: prometheus
    restart: unless-stopped
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=30d
      - --web.enable-lifecycle
      - --web.enable-remote-write-receiver
    ports:
      - "9090:9090"
    volumes:
      - ./config/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./config/rules:/etc/prometheus/rules:ro
      - prometheus-data:/prometheus
    networks:
      - observability

volumes:
  prometheus-data:

networks:
  observability:
    name: observability
```

Replace `<PINNED_VERSION>` with the approved version.

### Required flag for Alloy metrics

Prometheus 3 uses the dedicated flag:

```text
--web.enable-remote-write-receiver
```

This enables:

```text
POST /api/v1/write
```

which is required by the Alloy Linux-metrics pipeline documented in this repository.

---

# Stage 4 - Preflight validation

## 9. Validate Compose

```bash
docker compose config
```

Pull the selected image:

```bash
docker compose pull prometheus
```

### Validate Prometheus YAML with the pinned image

```bash
docker run --rm \
  --entrypoint /bin/promtool \
  -v "$PWD/config:/etc/prometheus:ro" \
  prom/prometheus:<PINNED_VERSION> \
  check config /etc/prometheus/prometheus.yml
```

Expected result includes:

```text
SUCCESS
```

Do not start or reload Prometheus with an invalid configuration.

---

# Stage 5 - Start Prometheus

## 10. Deploy

```bash
docker compose up -d prometheus
```

Check:

```bash
docker compose ps
docker logs --tail 100 prometheus
```

Expected result: Prometheus remains running without repeated TSDB or configuration errors.

---

# Stage 6 - Health validation

## 11. Readiness and health

```bash
curl -fsS http://127.0.0.1:9090/-/ready
curl -fsS http://127.0.0.1:9090/-/healthy
```

Check runtime information:

```bash
curl -fsS http://127.0.0.1:9090/api/v1/status/runtimeinfo | jq
```

Check build information:

```bash
curl -fsS http://127.0.0.1:9090/api/v1/status/buildinfo | jq
```

Check listening socket:

```bash
ss -ltnp | grep ':9090'
```

---

# Stage 7 - Validate self-scrape

## 12. Query `up`

```bash
curl -fsS --get \
  http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=up{job="prometheus"}' \
  | jq
```

Expected value:

```text
1
```

Prometheus should be able to monitor itself before other targets are added.

---

# Stage 8 - Validate remote-write receiver

## 13. Confirm Alloy network path

From an Alloy-enabled Linux host:

```bash
curl -fsS http://<MONITORING_VM_IP>:9090/-/ready
```

Optional TCP check:

```bash
nc -vz <MONITORING_VM_IP> 9090
```

The remote-write API is a POST/protobuf endpoint, so a browser-style GET is not a functional write test.

The end-to-end write test is performed by enabling an Alloy pipeline and checking that a `node_*` metric arrives in Prometheus.

### Expected Alloy endpoint

```alloy
prometheus.remote_write "homelab" {
  endpoint {
    url = "http://<MONITORING_VM_IP>:9090/api/v1/write"
  }
}
```

---

# Stage 9 - Add Grafana datasource

## 14. Grafana connection

If Grafana is attached to the same `observability` Docker network, set its Prometheus datasource URL to:

```text
http://prometheus:9090
```

Do not use the LAN address unnecessarily from an adjacent container when the internal service name is available and healthy.

Test in Grafana Explore:

```promql
up{job="prometheus"}
```

Expected result: `1`.

If datasource provisioning is managed in Git, make the provisioning file authoritative rather than relying on an undocumented UI change.

---

# Stage 10 - Add scrape targets safely

## 15. Configuration change workflow

For every Prometheus configuration change:

1. edit the Git-managed source;
2. validate with `promtool`;
3. review the diff;
4. apply/reload;
5. confirm readiness;
6. confirm affected targets/queries.

### Validate running container configuration

```bash
docker exec prometheus \
  promtool check config /etc/prometheus/prometheus.yml
```

### Reload

Because `--web.enable-lifecycle` is enabled:

```bash
curl -fsS -X POST http://127.0.0.1:9090/-/reload
```

Check logs immediately afterwards:

```bash
docker logs --tail 100 prometheus
```

Prometheus will reject a malformed reload, but pre-validation remains mandatory.

---

# Stage 11 - Persistence

## 16. Verify TSDB volume

```bash
docker volume inspect prometheus-data
```

Restart:

```bash
docker compose restart prometheus
```

Recheck:

```bash
curl -fsS http://127.0.0.1:9090/-/ready
```

Confirm previously stored data remains queryable after restart.

Do not use an ephemeral container filesystem for Prometheus TSDB data.

---

# Stage 12 - Retention and capacity

## 17. Initial retention

The baseline uses:

```text
--storage.tsdb.retention.time=30d
```

This is an initial operating value, not a permanent guarantee.

Monitor:

- volume size;
- growth per day/week;
- active series count;
- scrape volume;
- Alloy remote-write volume;
- available disk space.

Adjust retention only from measured capacity data.

Disk exhaustion of the monitoring VM is a higher operational risk than losing old metrics.

---

# Stage 13 - Monitoring Prometheus

## 18. Minimum service checks

Monitor Prometheus for:

- service/container availability;
- readiness;
- restart count;
- TSDB disk usage;
- scrape failures;
- rule evaluation failures;
- remote-write receiver errors;
- CPU and memory;
- config reload failures.

Useful built-in metric families include Prometheus process, TSDB, scrape, and rule metrics exposed on `/metrics`.

---

# Stage 14 - Upgrade

## 19. Controlled upgrade

Before change:

```bash
docker inspect prometheus --format '{{.Config.Image}}'
curl -fsS http://127.0.0.1:9090/-/ready
```

Then:

1. review Prometheus release/migration notes;
2. update the pinned version in Git;
3. validate configuration using the new image;
4. pull the image;
5. recreate Prometheus;
6. verify readiness;
7. verify self-scrape;
8. verify Alloy-fed Linux metrics;
9. verify Grafana queries and alerts.

Example:

```bash
docker compose pull prometheus
docker compose up -d prometheus
```

Prometheus major-version changes require specific attention to migration notes and removed/renamed command-line flags.

---

# Rollback

## 20. Roll back image/configuration

If an upgrade/configuration change fails:

1. restore the last known-good config from Git;
2. restore the previous pinned image version;
3. run `promtool check config` with that version;
4. recreate Prometheus;
5. check readiness;
6. check stored data;
7. check Alloy-fed metrics;
8. check Grafana.

Do not delete the TSDB volume during a normal rollback.

---

# Troubleshooting

## 21. Prometheus container exits

```bash
docker logs prometheus
docker compose config
```

Then validate:

```bash
docker run --rm \
  --entrypoint /bin/promtool \
  -v "$PWD/config:/etc/prometheus:ro" \
  prom/prometheus:<PINNED_VERSION> \
  check config /etc/prometheus/prometheus.yml
```

---

## 22. Alloy cannot remote-write

On the Alloy host:

```bash
curl -fsS http://<MONITORING_VM_IP>:9090/-/ready
journalctl -u alloy -n 200 --no-pager
```

On Prometheus:

```bash
docker logs --tail 200 prometheus
```

Confirm command line contains:

```text
--web.enable-remote-write-receiver
```

Confirm Alloy URL is:

```text
http://<MONITORING_VM_IP>:9090/api/v1/write
```

---

## 23. Grafana error: lookup prometheus on Docker DNS

Test from the Grafana container:

```bash
docker exec grafana getent hosts prometheus
```

and:

```bash
docker exec grafana \
  sh -c 'wget -qO- http://prometheus:9090/-/ready || true'
```

If DNS resolution fails, verify:

- Grafana and Prometheus share the intended Docker network;
- the Prometheus service/container is running;
- the Docker network is healthy;
- service aliases/names are correct;
- Docker embedded DNS is functioning.

Do not change the external/LAN DNS system to fix a Docker-internal service-name problem.

---

## 24. Prometheus is healthy but no Linux host metrics arrive

Query:

```promql
node_uname_info
```

If missing, inspect the Alloy host pipeline:

- `prometheus.exporter.unix`;
- `discovery.relabel`;
- `prometheus.scrape`;
- `prometheus.remote_write`.

Check Alloy logs and component health before modifying Grafana.

---

# Acceptance gate

## 25. Completion checklist

- [ ] Prometheus image version is pinned.
- [ ] Compose validation passes.
- [ ] `promtool check config` passes.
- [ ] Prometheus remains running.
- [ ] `/-/ready` passes.
- [ ] `/-/healthy` passes.
- [ ] Self-scrape returns `up == 1`.
- [ ] TSDB storage is persistent.
- [ ] Retention is explicitly configured.
- [ ] TCP `9090` is not Internet-exposed.
- [ ] Remote-write receiver is enabled.
- [ ] An Alloy host can reach Prometheus.
- [ ] At least one Alloy-fed `node_*` metric has been proven.
- [ ] Grafana datasource test passes.
- [ ] Prometheus disk monitoring is present or planned before production.
- [ ] Configuration is committed to Git.
- [ ] No secrets are in Git plaintext.

---

# Future automation target

## 26. IaC model

```text
OpenTofu
  -> monitoring VM
cloud-init
  -> first boot
Ansible
  -> Docker baseline + directories
Docker Compose
  -> Prometheus
Jenkins
  -> promtool / compose validation / controlled deployment
```

CI should reject changes when:

```bash
promtool check config
```

fails.

Deployment should fail if:

```bash
curl -fsS http://127.0.0.1:9090/-/ready
```

does not succeed after apply.

---

## 27. Completion record

```text
Monitoring VM:
Monitoring VM IP:
Prometheus version:
Deployment path:
TSDB storage:
Retention:
Remote-write receiver enabled: YES / NO
Self-scrape: PASS / FAIL
Alloy remote-write test: PASS / FAIL
Grafana datasource: PASS / FAIL
Date:
Operator:
Notes:
```
