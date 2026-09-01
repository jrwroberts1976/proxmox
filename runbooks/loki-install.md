# Grafana Loki Installation and Operations Runbook

## 1. Purpose

This runbook defines the current Loki standard for the Proxmox homelab and records the authoritative deployment used by new Alloy-managed VMs.

```text
Linux VM
   |
   +--> Grafana Alloy
            |
            +--> loki.write
                     |
                     v
                ids-01 Loki
                     |
                     v
                  Grafana
```

---

## 2. Current authoritative deployment

Verified 2026-09-01:

```text
Host:                 ids-01
LAN IP:               192.168.2.242
Published port:       3100
Compose project:      /home/james/docker/stacks/monitoring
Compose file:         /home/james/docker/stacks/monitoring/docker-compose.yml
Config:               /home/james/docker/data/monitoring/loki/local-config.yaml
Data:                 /home/james/docker/data/monitoring/loki/data
Container config:     /etc/loki/local-config.yaml
Grafana datasource:   http://loki:3100
Alloy LAN push URL:   http://192.168.2.242:3100/loki/api/v1/push
```

The deployed Loki container is pinned by image/digest in the monitoring stack. Do not replace it with `latest`.

Grafana and Loki share the monitoring Docker network, so Grafana should continue using `http://loki:3100`. Remote systemd Alloy clients must use the LAN endpoint.

---

## 3. Security standard

Loki does not provide the security boundary for an Internet-facing log service.

Therefore:

- TCP/3100 must not be Internet-exposed;
- remote Alloy clients should reach it only over trusted LAN paths;
- do not publish credentials or secrets in Git;
- use an authenticating proxy if Loki ever crosses a trust boundary.

---

# Stage 0 - Baseline

On `ids-01`:

```bash
cd /home/james/docker/stacks/monitoring

docker compose config -q
docker inspect loki --format 'image={{.Config.Image}} status={{.State.Status}}'
curl -fsS http://127.0.0.1:3100/ready
```

Expected:

```text
ready
```

Confirm the published listener:

```bash
docker port loki
ss -ltn | grep ':3100'
```

---

# Stage 1 - Client path

From a new Alloy VM:

```bash
curl -fsS http://192.168.2.242:3100/ready
```

If local readiness on `ids-01` works but the remote check fails, investigate routing/firewall policy before changing Loki configuration.

Do not weaken the whole LAN firewall for a single client.

---

# Stage 2 - Alloy client configuration

Remote systemd Alloy clients use:

```alloy
loki.write "homelab" {
  endpoint {
    url = "http://192.168.2.242:3100/loki/api/v1/push"
  }
}
```

A Docker service name such as `loki` is not a valid assumption on another VM.

For journal collection, add stable labels:

```alloy
loki.source.journal "system" {
  forward_to = [loki.write.homelab.receiver]

  labels = {
    hostname    = "<HOSTNAME>",
    role        = "<ROLE>",
    environment = "homelab",
    source      = "journal",
  }
}
```

Validate the actual labels received in Loki rather than assuming a specific `job` label.

VM101's validated runtime stream included:

```text
environment=homelab
hostname=app-platform-01
job=loki.source.journal.system
role=application
service_name=loki.source.journal.system
source=journal
```

This differs from older examples that assumed `job="systemd-journal"`.

---

# Stage 3 - End-to-end acceptance

A running Loki container is not sufficient proof.

Generate a unique event on the Alloy host:

```bash
TEST_ID="observability-$(hostname)-$(date +%s)"
logger -t homelab-observability-test "$TEST_ID"
echo "$TEST_ID"
```

Search with the stable host label:

```logql
{hostname="<HOSTNAME>"} |= "<TEST_ID>"
```

Or query the API from a trusted admin host:

```bash
curl -fsS --get \
  --data-urlencode 'query={hostname="<HOSTNAME>"} |= "<TEST_ID>"' \
  --data-urlencode "start=$(date -d '5 minutes ago' +%s%N)" \
  --data-urlencode "end=$(date +%s%N)" \
  --data-urlencode 'limit=20' \
  http://192.168.2.242:3100/loki/api/v1/query_range |
jq
```

VM101 passed this test on 2026-09-01. The unique message was visible within normal ingestion latency.

If an Ansible shell task containing the same test ID is journalled, a Loki query may return both the real test message and the Ansible command log. That is not by itself evidence of duplicate log forwarding.

---

# Stage 4 - Grafana datasource

Current datasource provisioning uses:

```text
http://loki:3100
```

Validate from the Grafana container if necessary:

```bash
docker exec grafana \
  sh -c 'wget -qO- http://loki:3100/ready || true'
```

Do not change LAN DNS to fix a Docker-internal `loki` lookup problem.

---

# Stage 5 - Configuration changes

Use the Git-managed host configuration:

```text
/home/james/docker/data/monitoring/loki/local-config.yaml
```

and Compose authority:

```text
/home/james/docker/stacks/monitoring/docker-compose.yml
```

Before apply:

```bash
cd /home/james/docker/stacks/monitoring
docker compose config -q
```

Review Git diff. Recreate only Loki if required:

```bash
docker compose up -d --no-deps --force-recreate loki
```

Then wait for:

```bash
curl -fsS http://127.0.0.1:3100/ready
```

and perform a fresh end-to-end test log.

---

# Stage 6 - Persistence

Verify host-mounted data:

```bash
du -sh /home/james/docker/data/monitoring/loki/data
```

A controlled restart must not remove historical data:

```bash
docker compose restart loki
curl -fsS http://127.0.0.1:3100/ready
```

Confirm an older known log remains queryable.

---

# Stage 7 - Capacity and retention

Monitor:

- Loki data directory growth;
- host filesystem free space;
- ingestion failures;
- HTTP error rates;
- container restart count;
- CPU/memory use.

Do not copy arbitrary retention settings without measuring ingestion volume and available disk.

---

# Stage 8 - Upgrade

Before upgrading:

```bash
docker inspect loki --format '{{.Config.Image}}'
curl -fsS http://127.0.0.1:3100/ready
```

Then:

1. review Loki release/upgrade notes;
2. change the pinned image in Git;
3. run `docker compose config -q`;
4. pull/recreate only Loki;
5. verify readiness;
6. generate a unique Alloy journal event;
7. prove it is queryable;
8. verify Grafana Explore.

---

# Troubleshooting

## Alloy reports connection refused

From the Alloy VM:

```bash
curl -v http://192.168.2.242:3100/ready
```

On `ids-01`:

```bash
docker ps --filter name=loki
ss -ltn | grep ':3100'
```

## Alloy reports `lookup loki`

Use the LAN endpoint:

```text
http://192.168.2.242:3100/loki/api/v1/push
```

Remote systemd clients should not rely on Docker service DNS.

## Service is ready but test event is missing

Check:

```bash
journalctl -u alloy -n 200 --no-pager
```

Confirm:

- journal permission as the `alloy` account;
- correct host labels;
- correct write URL;
- no repeated Loki push/backoff errors.

Query by the exact unique ID rather than a broad dashboard view.

---

# Rollback

For a failed Loki config/image change:

1. restore previous Git-managed config/image;
2. validate Compose;
3. recreate only Loki;
4. verify `/ready`;
5. verify historical queryability;
6. generate and query a new unique test event.

Do not delete the Loki data directory during a normal rollback.

---

## Acceptance checklist

- [ ] `ids-01` confirmed as Loki authority.
- [ ] Image pinned.
- [ ] Compose validation passes.
- [ ] `/ready` passes locally.
- [ ] VM can reach `192.168.2.242:3100`.
- [ ] Alloy uses LAN push endpoint.
- [ ] Alloy can read journal as unprivileged account.
- [ ] Unique event is visible in Loki.
- [ ] Actual stream labels are recorded.
- [ ] Grafana datasource works.
- [ ] Persistent storage is healthy.
- [ ] TCP/3100 is not Internet-exposed.
- [ ] Capacity/retention are documented.

---

## Completion record

```text
Host: ids-01
Loki image/version:
Config path:
Data path:
Local readiness: PASS / FAIL
Client reachability: PASS / FAIL
Unique log E2E: PASS / FAIL
Grafana datasource: PASS / FAIL
Persistence: PASS / FAIL
Date:
Operator:
Notes:
```
