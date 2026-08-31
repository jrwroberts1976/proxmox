# Grafana Loki Installation Runbook

## 1. Purpose

This runbook defines the standard procedure for deploying Grafana Loki as the central log store for the Proxmox homelab.

The target architecture is:

```text
Linux hosts / VMs
   |
   | Grafana Alloy
   | /loki/api/v1/push
   v
Debian monitoring / Docker VM
   |
   +--> Loki :3100
   |
   +--> Grafana
```

Loki is the log storage/query engine. Grafana Alloy is the preferred collector used to send Linux and application logs into Loki.

The initial homelab deployment is a single Loki instance using local persistent storage. This is appropriate for the current lab scale and can later be migrated to object storage if required.

---

## 2. Scope

This runbook covers:

- Docker Compose deployment on the monitoring VM;
- persistent Loki storage;
- a single-binary Loki configuration;
- configuration validation and startup;
- readiness and metrics checks;
- LAN reachability for Alloy clients;
- adding Loki to Grafana;
- end-to-end log ingestion validation;
- backup considerations;
- upgrade, rollback, and troubleshooting;
- a future Ansible/Docker Compose automation target.

This runbook does not install Grafana Alloy on clients.

---

## 3. Standard

| Item | Standard |
|---|---|
| Deployment | Docker Compose |
| Container image | `grafana/loki:<PINNED_VERSION>` |
| Container port | `3100` |
| Host/LAN port | `3100` where Alloy clients require direct access |
| Container config | `/etc/loki/config.yml` |
| Host config | Git-managed monitoring stack path |
| Persistent data | Docker volume or dedicated bind mount |
| Initial mode | Single binary / single replica |
| Initial storage | Filesystem |
| Grafana datasource URL | `http://loki:3100` inside the monitoring Compose network |
| Alloy push URL | `http://<MONITORING_VM_LAN_IP>:3100/loki/api/v1/push` |

Never use `latest` for a production-like deployment. Pin and deliberately upgrade the Loki version.

---

## 4. Security warning

Loki does not provide a built-in authentication layer.

Therefore:

1. do not expose TCP `3100` directly to the Internet;
2. allow only the trusted LAN/monitoring networks that need to push or query logs;
3. if Loki must cross a trust boundary, place an authenticating reverse proxy in front of it;
4. keep Grafana-to-Loki traffic on the internal Docker network where practical;
5. do not commit proxy credentials, tokens, or TLS private keys to Git plaintext.

---

## 5. Preconditions

Before deployment confirm:

- [ ] The monitoring VM is healthy.
- [ ] Docker Engine is installed and healthy.
- [ ] Docker Compose v2 is available.
- [ ] Persistent storage is available.
- [ ] The intended Loki data location is included in the backup design.
- [ ] TCP `3100` is not already in use.
- [ ] Grafana is healthy or its future location is known.
- [ ] A tested Loki version has been selected and pinned.
- [ ] LAN firewall policy for Alloy clients is understood.

Capture:

```text
MONITORING_VM_IP=
LOKI_VERSION=
LOKI_STACK_PATH=
LOKI_DATA_PATH=
```

---

# Stage 1 - Prepare directories

## 6. Create stack structure

Example:

```bash
sudo mkdir -p /opt/homelab-observability/loki
sudo chown -R "$USER":"$USER" /opt/homelab-observability
cd /opt/homelab-observability/loki
```

If the authoritative Docker configuration already has an established repository/path, use that instead.

Recommended structure:

```text
loki/
├── compose.yml
└── config/
    └── loki.yml
```

Create the config directory:

```bash
mkdir -p config
```

---

# Stage 2 - Create Loki configuration

## 7. Baseline single-node configuration

Create `config/loki.yml`:

```yaml
auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /loki
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules

schema_config:
  configs:
    - from: 2024-04-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

compactor:
  working_directory: /loki/compactor
```

This is a deliberately small single-node baseline.

Do not add aggressive retention, multi-tenancy, object storage, ruler/Alertmanager integration, or distributed-mode complexity until basic ingestion and recovery are proven.

---

# Stage 3 - Create Docker Compose service

## 8. Compose definition

Create `compose.yml`:

```yaml
services:
  loki:
    image: grafana/loki:<PINNED_VERSION>
    container_name: loki
    restart: unless-stopped
    command:
      - -config.file=/etc/loki/config.yml
    ports:
      - "3100:3100"
    volumes:
      - ./config/loki.yml:/etc/loki/config.yml:ro
      - loki-data:/loki
    networks:
      - observability

volumes:
  loki-data:

networks:
  observability:
    name: observability
```

Replace `<PINNED_VERSION>` with the approved version.

If an existing Grafana/Prometheus Compose project already defines an `observability` network, attach Loki to that authoritative network instead of accidentally creating a conflicting design.

---

# Stage 4 - Preflight validation

## 9. Validate Compose

```bash
docker compose config
```

Expected result: rendered configuration is valid.

Check the selected image before deployment:

```bash
docker compose pull loki
```

Do not deploy if the image cannot be pulled for the VM architecture.

---

# Stage 5 - Start Loki

## 10. Deploy

```bash
docker compose up -d loki
```

Check:

```bash
docker compose ps
docker logs --tail 100 loki
```

Expected result: Loki remains running with no repeated configuration/storage errors.

---

# Stage 6 - Local health checks

## 11. Readiness

```bash
curl -fsS http://127.0.0.1:3100/ready
```

Expected result:

```text
ready
```

Check metrics:

```bash
curl -fsS http://127.0.0.1:3100/metrics | head -30
```

Check listening socket:

```bash
ss -ltnp | grep ':3100'
```

---

# Stage 7 - Validate LAN client path

## 12. Test from an Alloy host

From a Linux client/VM that will ship logs:

```bash
curl -fsS http://<MONITORING_VM_IP>:3100/ready
```

Optional:

```bash
nc -vz <MONITORING_VM_IP> 3100
```

If local readiness works but the remote test fails, investigate:

- host firewall;
- Proxmox/network firewall;
- routing;
- wrong IP;
- port publishing;
- upstream ACLs.

Do not weaken firewall policy globally just to make the test pass.

---

# Stage 8 - Add Loki to Grafana

## 13. Grafana datasource

If Grafana is on the same Docker network, use:

```text
http://loki:3100
```

Do not use the public/LAN path from Grafana unnecessarily if an internal Docker network exists.

In Grafana:

1. open **Connections / Data sources**;
2. add or open **Loki**;
3. set the URL to the internal Loki endpoint;
4. save and test.

Expected result: datasource test succeeds.

If datasource provisioning is Git-managed, add the Loki datasource there rather than making the UI the permanent source of truth.

---

# Stage 9 - Configure Alloy client

## 14. Push URL

On a remote systemd Alloy installation, use a LAN-resolvable Loki endpoint:

```alloy
loki.write "homelab" {
  endpoint {
    url = "http://<MONITORING_VM_IP>:3100/loki/api/v1/push"
  }
}
```

Do not use:

```text
http://loki:3100/...
```

from a remote systemd host unless that hostname genuinely resolves on the LAN. Docker service names are normally scoped to Docker networks.

---

# Stage 10 - End-to-end acceptance test

## 15. Generate a unique client log

On an Alloy-enabled Linux host:

```bash
TEST_ID="loki-e2e-$(date +%s)"
logger -t homelab-loki-test "$TEST_ID"
echo "$TEST_ID"
```

Wait for normal ingestion latency, then search in Grafana Explore using Loki.

A useful starting query where journal labels include host/service identity is:

```logql
{job=~".+"} |= "<TEST_ID>"
```

The exact labels depend on the Alloy pipeline.

Acceptance requires the exact generated test ID to be visible in Loki/Grafana.

A running Loki container alone is not sufficient proof.

---

# Stage 11 - Prometheus monitoring of Loki

## 16. Monitor Loki itself

Loki exposes Prometheus-format metrics at:

```text
http://loki:3100/metrics
```

Add Loki to the central Prometheus monitoring design after the service is healthy.

At minimum monitor:

- container/service availability;
- Loki readiness;
- request failures;
- ingestion errors;
- disk capacity for Loki storage;
- restart count;
- memory/CPU use.

Do not allow log storage to consume the monitoring VM filesystem without disk alerts.

---

# Stage 12 - Persistence and backup

## 17. Confirm persistent data

```bash
docker volume inspect loki-data
```

or, for a bind mount:

```bash
du -sh <LOKI_DATA_PATH>
```

Restart test:

```bash
docker compose restart loki
curl -fsS http://127.0.0.1:3100/ready
```

Confirm an older known log remains queryable after restart.

### Backup principle

Logs are operationally useful but should not be allowed to compromise recovery of higher-priority services.

At minimum:

- back up the Loki configuration;
- document whether Loki data itself is backed up or treated as reconstructible telemetry;
- protect the monitoring VM from disk exhaustion;
- keep service configuration in Git.

---

# Stage 13 - Retention

## 18. Add retention only after baseline

Retention should be chosen according to available disk and actual ingestion volume.

Before enabling automated deletion:

1. measure daily Loki growth;
2. define target retention;
3. confirm the currently deployed Loki version's compactor retention requirements;
4. test deletion in the lab;
5. document the chosen value.

Do not copy an arbitrary Internet retention configuration into production.

---

# Stage 14 - Upgrade

## 19. Controlled upgrade

Before upgrading:

```bash
docker compose ps
curl -fsS http://127.0.0.1:3100/ready
docker inspect loki --format '{{.Config.Image}}'
```

Record the current version.

Then:

1. review Loki release notes and upgrade notes;
2. change the pinned image version in Git;
3. run `docker compose config`;
4. pull the new image;
5. recreate Loki;
6. verify readiness;
7. run an end-to-end Alloy log test;
8. verify Grafana queries.

Example apply:

```bash
docker compose pull loki
docker compose up -d loki
```

---

# Rollback

## 20. Container rollback

If an upgrade fails:

1. restore the previous config if changed;
2. restore the previous pinned Loki image version;
3. run `docker compose config`;
4. recreate Loki;
5. validate readiness and existing logs.

Do not delete the persistent data volume as part of normal rollback.

---

# Troubleshooting

## 21. Loki container exits immediately

```bash
docker logs loki
docker compose config
```

Common causes:

- invalid YAML;
- incompatible configuration for the selected version;
- storage permissions;
- invalid command/path;
- port already in use.

---

## 22. Alloy gets connection refused

From the Alloy host:

```bash
curl -v http://<MONITORING_VM_IP>:3100/ready
```

On the monitoring VM:

```bash
docker compose ps
ss -ltnp | grep ':3100'
```

---

## 23. Alloy reports DNS failure for `loki`

A remote host usually cannot resolve a Docker Compose service name.

Use:

```text
http://<MONITORING_VM_LAN_IP>:3100/loki/api/v1/push
```

or a real LAN DNS record.

---

## 24. Grafana cannot query Loki but Alloy can push

Check whether Grafana uses the correct path for its network location.

Inside the same Docker network:

```text
http://loki:3100
```

From outside that Docker network:

```text
http://<MONITORING_VM_IP>:3100
```

Also test from the Grafana container:

```bash
docker exec grafana \
  sh -c 'wget -qO- http://loki:3100/ready || true'
```

---

# Acceptance gate

## 25. Completion checklist

- [ ] Loki image version is pinned.
- [ ] Compose validation passes.
- [ ] Loki remains running.
- [ ] `/ready` passes locally.
- [ ] `/metrics` returns data.
- [ ] Persistent storage exists.
- [ ] Loki is not Internet-exposed.
- [ ] Required Alloy hosts can reach TCP `3100`.
- [ ] Grafana datasource test passes.
- [ ] A unique Alloy-generated test log is visible in Grafana.
- [ ] Disk capacity monitoring exists or is planned before production use.
- [ ] Backup/retention policy is documented.
- [ ] Configuration is committed to Git.
- [ ] No secrets are stored in Git plaintext.

---

# Future automation target

## 26. IaC model

The eventual implementation should be managed through the Proxmox IaC chain:

```text
OpenTofu
  -> monitoring VM
cloud-init
  -> first boot
Ansible
  -> Docker host baseline
Docker Compose
  -> Loki
Jenkins
  -> validate / deploy
```

Automation should run at least:

```bash
docker compose config
curl -fsS http://127.0.0.1:3100/ready
```

and should not mark deployment successful until Loki is queryable end-to-end.

---

## 27. Completion record

```text
Monitoring VM:
Monitoring VM IP:
Loki version:
Deployment path:
Storage type/location:
Grafana datasource: PASS / FAIL
Remote Alloy reachability: PASS / FAIL
End-to-end test log: PASS / FAIL
Backup policy:
Retention policy:
Date:
Operator:
Notes:
```
