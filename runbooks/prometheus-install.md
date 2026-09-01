# Prometheus Installation and Operations Runbook

## 1. Purpose

This runbook defines the current Prometheus standard for the Proxmox homelab and records the authoritative deployment that new Alloy-managed VMs must use.

```text
Alloy-managed Linux VMs
        |
        +--> prometheus.remote_write
                  |
                  v
           ids-01 Prometheus
                  |
                  v
               Grafana
```

Existing direct exporters may still be scraped normally. New Proxmox VM host metrics should use Alloy remote write unless a documented exception exists.

---

## 2. Current authoritative deployment

Verified 2026-09-01:

```text
Host:                 ids-01
LAN IP:               192.168.2.242
Prometheus image:     prom/prometheus:v3.13.1
Published port:       9090
Compose project:      /home/james/docker/stacks/monitoring
Compose file:         /home/james/docker/stacks/monitoring/docker-compose.yml
Configuration mount: /home/james/docker/data/monitoring/prometheus -> /etc/prometheus
TSDB mount:           /home/james/docker/data/monitoring/prometheus/data -> /prometheus
Grafana datasource:   http://prometheus:9090
```

Running command flags include:

```text
--config.file=/etc/prometheus/prometheus.yml
--storage.tsdb.path=/prometheus
--web.enable-lifecycle
--web.enable-remote-write-receiver
```

The remote-write receiver was enabled and validated on 2026-09-01. After controlled recreation, the established scrape-target baseline returned to:

```text
active_targets=26
healthy_targets=26
unhealthy_targets=0
```

That target count is a health baseline for normal scrape targets. Alloy remote-written VMs do **not** appear as new entries in `/api/v1/targets` merely because their series are being received.

---

## 3. Authority rule

The homelab contains more than one Prometheus instance.

Before changing a monitoring client, verify authority by checking:

1. where Grafana is running;
2. Grafana's provisioned Prometheus datasource;
3. Prometheus target/job inventory;
4. the intended Loki/Grafana pairing.

Current authority is `ids-01`. Do not point new VMs at TestServer Prometheus by default.

---

## 4. Standard endpoints

| Purpose | URL |
|---|---|
| LAN readiness | `http://192.168.2.242:9090/-/ready` |
| LAN health | `http://192.168.2.242:9090/-/healthy` |
| Query API | `http://192.168.2.242:9090/api/v1/query` |
| Remote write | `http://192.168.2.242:9090/api/v1/write` |
| Grafana internal datasource | `http://prometheus:9090` |

TCP/9090 must not be Internet-exposed.

---

# Stage 0 - Pre-change baseline

Before changing Compose, configuration, image or flags:

```bash
cd /home/james/docker/stacks/monitoring

docker compose config -q
docker inspect prometheus --format '{{.Config.Image}}'
docker inspect prometheus --format '{{range .Config.Cmd}}{{println .}}{{end}}'
curl -fsS http://127.0.0.1:9090/-/ready
```

Capture the target baseline:

```bash
curl -fsS http://127.0.0.1:9090/api/v1/targets |
jq -r '
  "active=" + ((.data.activeTargets | length) | tostring),
  "healthy=" + ([.data.activeTargets[] | select(.health == "up")] | length | tostring),
  "unhealthy=" + ([.data.activeTargets[] | select(.health != "up")] | length | tostring)
'
```

Do not assume a different target count is automatically a failure after future architecture changes; compare with the pre-change baseline for that specific maintenance window.

---

# Stage 1 - Configuration changes

Prometheus configuration authority is the host-mounted Git-managed monitoring stack, not the container filesystem.

Validate config before reload:

```bash
docker exec prometheus \
  promtool check config /etc/prometheus/prometheus.yml
```

Validate Compose before recreation:

```bash
cd /home/james/docker/stacks/monitoring
docker compose config -q
```

Review the diff in Git before applying.

---

# Stage 2 - Enable remote-write receiver

For Alloy Linux metrics, Prometheus must run with:

```text
--web.enable-remote-write-receiver
```

The required Compose command section includes:

```yaml
command:
  - --config.file=/etc/prometheus/prometheus.yml
  - --storage.tsdb.path=/prometheus
  - --web.enable-lifecycle
  - --web.enable-remote-write-receiver
```

The write endpoint is:

```text
POST /api/v1/write
```

Do not confuse the receiver flag with Prometheus `remote_write` configuration used to send Prometheus data to another backend.

---

# Stage 3 - Controlled Prometheus-only recreation

When a command-line flag changes, recreate only Prometheus:

```bash
cd /home/james/docker/stacks/monitoring

docker compose up \
  -d \
  --no-deps \
  --force-recreate \
  prometheus
```

Do not restart Loki/Grafana unnecessarily.

Wait for readiness:

```bash
for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:9090/-/ready >/dev/null 2>&1; then
    echo PASS
    break
  fi
  sleep 2
done
```

Then verify the running flags:

```bash
docker inspect prometheus \
  --format '{{range .Config.Cmd}}{{println .}}{{end}}'
```

---

# Stage 4 - Wait for scrape discovery to settle

Immediately after a recreate, `/api/v1/targets` may temporarily show zero active targets, followed by a gradual recovery as service discovery and scrapes resume.

Do not declare a regression from the first post-start API sample.

Poll until the expected baseline returns:

```bash
for i in $(seq 1 24); do
  JSON="$(curl -fsS http://127.0.0.1:9090/api/v1/targets)"
  ACTIVE="$(printf '%s' "$JSON" | jq '.data.activeTargets | length')"
  HEALTHY="$(printf '%s' "$JSON" | jq '[.data.activeTargets[] | select(.health == "up")] | length')"
  UNHEALTHY="$(printf '%s' "$JSON" | jq '[.data.activeTargets[] | select(.health != "up")] | length')"
  printf 'attempt=%s active=%s healthy=%s unhealthy=%s\n' "$i" "$ACTIVE" "$HEALTHY" "$UNHEALTHY"
  sleep 5
done
```

During the 2026-09-01 receiver change, ids-01 recovered from `0/0` through intermediate unhealthy states to the established `26/26` healthy baseline.

---

# Stage 5 - Validate Alloy client path

From a new VM:

```bash
curl -fsS http://192.168.2.242:9090/-/ready
```

The functional receiver test is not a GET to `/api/v1/write`. Enable the Alloy remote-write pipeline and prove a metric arrives.

Use:

```promql
node_uname_info{hostname="<HOSTNAME>"}
```

For VM101, the validated runtime result was one series with:

```text
hostname=app-platform-01
instance=app-platform-01
job=integrations/unix
role=application
environment=homelab
```

Core metrics were also present for memory, boot time, CPU and filesystem.

---

# Stage 6 - Grafana datasource

Current datasource provisioning on ids-01 uses:

```text
http://prometheus:9090
```

That is correct because Grafana and Prometheus share the monitoring Docker network.

Do not replace this with a LAN address merely to match remote Alloy clients. The client and Grafana network contexts are different.

---

# Stage 7 - Safe reload

For ordinary `prometheus.yml` changes that do not alter container command flags:

1. edit Git-managed source;
2. validate with `promtool`;
3. review diff;
4. POST lifecycle reload;
5. verify readiness and affected targets.

```bash
curl -fsS -X POST http://127.0.0.1:9090/-/reload
```

Check logs:

```bash
docker logs --tail 100 prometheus
```

---

# Stage 8 - Upgrade

Before upgrading:

```bash
docker inspect prometheus --format '{{.Config.Image}}'
curl -fsS http://127.0.0.1:9090/-/ready
```

Then:

1. review release notes;
2. update the pinned image in Git;
3. run `docker compose config -q`;
4. validate Prometheus config using the selected image where required;
5. pull/recreate only Prometheus;
6. wait for target baseline recovery;
7. verify Alloy-fed metrics;
8. verify Grafana and alerts.

Never use `latest` for the operational monitoring authority.

---

# Troubleshooting

## Alloy can reach 9090 but metrics do not arrive

Check:

```bash
docker inspect prometheus \
  --format '{{range .Config.Cmd}}{{println .}}{{end}}' |
grep -- '--web.enable-remote-write-receiver'
```

On the Alloy host:

```bash
journalctl -u alloy -n 200 --no-pager
curl -fsS http://192.168.2.242:9090/-/ready
```

Query the metric directly. Do not look only at `/targets` for remote-written hosts.

## Grafana reports `lookup prometheus`

Inside Grafana:

```bash
docker exec grafana getent hosts prometheus
```

If Docker DNS fails, troubleshoot the monitoring Docker network. Do not change LAN DNS to fix a Docker-internal service-name issue.

## Targets temporarily unhealthy after restart

Wait for discovery/scrape recovery and compare with the pre-change baseline before taking corrective action.

---

# Rollback

For a failed Compose/flag change:

1. restore the previous Git-managed Compose/config source;
2. run `docker compose config -q`;
3. recreate only Prometheus;
4. verify readiness;
5. wait for the previous target baseline;
6. verify Grafana and Alloy-fed metrics.

Do not delete TSDB data during a normal rollback.

Do not remove `--web.enable-remote-write-receiver` while any production Alloy client depends on it.

---

## Acceptance checklist

- [ ] `ids-01` confirmed as authority.
- [ ] Image pinned.
- [ ] Compose validation passes.
- [ ] `promtool` validation passes for config changes.
- [ ] Readiness and health pass.
- [ ] Lifecycle flag enabled.
- [ ] Remote-write receiver enabled.
- [ ] Existing target baseline recovers after recreation.
- [ ] Alloy client can reach 9090.
- [ ] Alloy-fed `node_*` metric is queryable.
- [ ] Grafana datasource works.
- [ ] TSDB data remains persistent.
- [ ] Port 9090 is not Internet-exposed.
- [ ] Changes are source controlled.

---

## Completion record

```text
Host: ids-01
Prometheus image/version:
Compose path:
Change:
Pre-change target baseline:
Post-change target baseline:
Readiness: PASS / FAIL
Remote-write receiver: PASS / FAIL
Alloy-fed metric proof: PASS / FAIL
Grafana datasource: PASS / FAIL
Date:
Operator:
Notes:
```
