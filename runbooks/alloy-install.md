# Grafana Alloy Installation Runbook

## 1. Purpose

This runbook defines the current standard for installing and validating Grafana Alloy on Debian-family Proxmox guests.

For new Proxmox VMs, Alloy is the preferred single host telemetry agent for both Linux metrics and system logs.

```text
Linux VM
   |
   +--> prometheus.exporter.unix
   |        |
   |        +--> discovery.relabel
   |        |        |
   |        |        +--> hostname=<stable name>
   |        |        +--> host=<stable name>
   |        |        +--> job=linux-hosts
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

Do not install a separate `prometheus-node-exporter` on a new VM when Alloy is already providing the same node metrics.

---

## 2. Current homelab authority

Verified 2026-09-01:

| Component | Authority | Endpoint |
|---|---|---|
| Prometheus | `ids-01` | `http://192.168.2.242:9090` |
| Prometheus remote write | `ids-01` | `http://192.168.2.242:9090/api/v1/write` |
| Loki | `ids-01` | `http://192.168.2.242:3100` |
| Loki push | `ids-01` | `http://192.168.2.242:3100/loki/api/v1/push` |
| Grafana | `ids-01` | `https://grafana.jrwroberts.co.uk/` |

Grafana uses Docker-local datasources:

```text
http://prometheus:9090
http://loki:3100
```

Those Docker service names are valid inside the `ids-01` monitoring network only. Remote systemd Alloy clients must use the LAN endpoint or a real LAN DNS name.

The homelab contains more than one Prometheus deployment. Do not choose a Prometheus server merely because TCP/9090 is reachable. Verify Grafana's datasource before commissioning a host.

---

## 3. Authoritative implementation

The preferred implementation is Ansible-managed:

```text
ansible/roles/alloy/
ansible/playbooks/alloy.yml
```

VM101 inventory currently lives at:

```text
ansible/inventories/vm101/hosts.yml
```

The role manages:

- the official Grafana APT repository;
- the `alloy` package;
- journal-readable group membership;
- `/etc/default/alloy`;
- `/etc/alloy/config.alloy`;
- configuration validation before restart;
- service enable/start state;
- readiness and health checks;
- journal-read validation as the `alloy` account;
- Linux metric label normalization for the established Grafana dashboard contract.

Manual commands in this runbook are recovery/debugging references, not the preferred configuration source.

---

## 4. Standard values

| Item | Standard |
|---|---|
| Package source | Official Grafana APT repository |
| Service | `alloy.service` |
| Service account | `alloy` |
| Main config | `/etc/alloy/config.alloy` |
| Environment file | `/etc/default/alloy` |
| State path | `/var/lib/alloy` |
| Local HTTP/UI | `127.0.0.1:12345` |
| Metrics backend | `192.168.2.242:9090` |
| Logs backend | `192.168.2.242:3100` |
| Canonical host label | `hostname=<stable name>` |
| Dashboard compatibility label | `host=<stable name>` |
| Linux metrics job | `linux-hosts` |
| Environment label | `homelab` |

VM101 validated Alloy version on 2026-09-01:

```text
v1.19.2
```

The role does not pin that package version yet; record the installed version during commissioning and deliberately control upgrades.

---

## 5. Established Grafana label contract

The provisioned `Linux OS Monitoring` dashboard on `ids-01` was inspected on 2026-09-01.

Its host variable is:

```text
label_values(up{job="linux-hosts"}, host)
```

Its core panel queries also filter on:

```text
job="linux-hosts"
host=~"$host"
```

Therefore new Alloy-managed Linux metrics must expose:

```text
job=linux-hosts
host=<stable hostname>
```

The role also keeps:

```text
hostname=<stable hostname>
```

as the canonical identity for new queries, alerts and cross-signal correlation. Do not remove `host`/`job=linux-hosts` until Grafana dashboards and alerts have been deliberately migrated to a different contract.

---

# Stage 0 - Preconditions

Confirm:

- intended hostname/IP are correct;
- time sync is healthy;
- no unexpected failed units exist;
- SSH and privilege escalation work;
- `apt.grafana.com` is reachable;
- VM can reach `192.168.2.242:9090` and `192.168.2.242:3100`;
- authoritative Prometheus is running with `--web.enable-remote-write-receiver`;
- no duplicate node-exporter path already exists for the host.

From the target VM:

```bash
hostnamectl
ip -br addr
timedatectl
systemctl --failed
curl -fsS http://192.168.2.242:9090/-/ready
curl -fsS http://192.168.2.242:3100/ready
```

Stop if either central endpoint is unavailable.

---

# Stage 1 - Ansible preflight

From the controller repository:

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

Do not disable host-key checking to make a failed SSH preflight pass.

---

# Stage 2 - First-install check mode

A first-install `--check --diff` has a special limitation: repository/key changes are simulated, so APT cannot actually see the new Alloy package during that same dry run.

The role therefore reports the intended package action and ends the host before package-dependent tasks on the first check-mode run.

```bash
ansible-playbook \
  -i inventories/vm101/hosts.yml \
  playbooks/alloy.yml \
  --check \
  --diff
```

Expected first-install result:

```text
failed=0
CHECK MODE: Grafana Alloy would be installed after the Grafana APT repository is applied.
```

Do not interpret this first dry run as proof that Alloy itself was installed or that package-created users/directories exist.

Also note: Ansible `uri` tasks may be skipped in check mode. Perform the central endpoint preflight explicitly before relying on the dry run.

---

# Stage 3 - Real deployment

Apply only after syntax, inventory, network and dry-run gates are clean:

```bash
ansible-playbook \
  -i inventories/vm101/hosts.yml \
  playbooks/alloy.yml
```

The role must validate:

```bash
alloy validate /etc/alloy/config.alloy
```

before a managed restart is allowed.

A second normal run must be idempotent:

```text
changed=0
failed=0
```

---

# Stage 4 - Service validation

On the VM:

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

Expected:

```text
enabled
active
127.0.0.1:12345
Alloy is ready.
All Alloy components are healthy.
```

The HTTP/UI listener should remain local-only unless a deliberate design change is approved.

---

# Stage 5 - Journal access

Alloy remains unprivileged. It should receive journal access through the normal journal-readable groups:

```text
adm
systemd-journal
```

Validate as the service account:

```bash
runuser -u alloy -- journalctl -n 5 --no-pager
```

For manual administration, `sudo -u alloy journalctl ...` is also acceptable where sudo policy permits it.

### Ansible implementation warning

Do not use an Ansible task that simply switches from root to `become_user: alloy` for this validation unless the remote temporary-file ACL requirements are understood. On VM101 this caused Ansible to attempt an unsupported temporary-file chmod/ACL mode.

The role deliberately uses:

```bash
runuser -u alloy -- journalctl -n 1 --no-pager
```

so journal access is tested as the real service account without introducing an unrelated Ansible temporary-file ACL dependency.

---

# Stage 6 - Expected baseline configuration

The managed configuration should contain one metrics path and one journal path:

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
    replacement  = "<ROLE>"
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

loki.source.journal "system" {
  forward_to = [loki.write.homelab.receiver]

  labels = {
    hostname    = "<HOSTNAME>",
    role        = "<ROLE>",
    environment = "homelab",
    source      = "journal",
  }
}

loki.write "homelab" {
  endpoint {
    url = "http://192.168.2.242:3100/loki/api/v1/push"
  }
}
```

Do not create a second node_exporter path for the same host.

---

# Stage 7 - End-to-end metrics acceptance

A healthy Alloy process alone is not enough.

Canonical query:

```promql
node_uname_info{hostname="<HOSTNAME>"}
```

Dashboard-compatible query:

```promql
node_uname_info{job="linux-hosts",host="<HOSTNAME>"}
```

Expected: exactly one current host series from each selector, representing the same Alloy path.

Also verify:

```promql
node_memory_MemTotal_bytes{hostname="<HOSTNAME>"}
node_boot_time_seconds{hostname="<HOSTNAME>"}
node_cpu_seconds_total{hostname="<HOSTNAME>"}
node_filesystem_size_bytes{hostname="<HOSTNAME>"}
```

Expected current labels:

```text
hostname=<HOSTNAME>
host=<HOSTNAME>
instance=<HOSTNAME>
job=linux-hosts
role=<ROLE>
environment=homelab
```

### VM101 migration note

Before the Grafana-compatibility correction, VM101 metrics were observed with `job=integrations/unix` and no `host` compatibility label. That proved remote-write ingestion but could not satisfy the established Linux dashboard selector.

After applying the corrected role, verify the current `job=linux-hosts`/`host=app-platform-01` series before closing the Grafana gate.

Remote-written hosts do not appear as a normal scrape target in Prometheus `/targets`. Validate them by querying the metrics themselves.

Duplicate check:

```promql
count by (hostname, host, instance, job) (
  node_uname_info{hostname="<HOSTNAME>"}
)
```

Normal new-VM expectation: one current authoritative series/path. Historical samples from the previous label set may remain queryable for their retention window; use current instant queries to distinguish history from an active duplicate collector.

---

# Stage 8 - End-to-end journal acceptance

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

VM101 validation proved the unique event reached `ids-01` Loki within normal ingestion latency.

The currently observed Loki stream labels include:

```text
environment=homelab
hostname=app-platform-01
job=loki.source.journal.system
role=application
service_name=loki.source.journal.system
source=journal
```

Do not hard-code dashboard logic around an assumed `job="systemd-journal"` label; validate the actual labels produced by the deployed Alloy version/configuration.

---

# Stage 9 - Grafana acceptance

The provisioned `Linux OS Monitoring` dashboard uses:

```text
label_values(up{job="linux-hosts"}, host)
```

for its host selector and its panels filter on the same `job` and `host` labels.

After Alloy is applied, prove:

```promql
up{job="linux-hosts",host="<HOSTNAME>"}
node_uname_info{job="linux-hosts",host="<HOSTNAME>"}
node_memory_MemTotal_bytes{job="linux-hosts",host="<HOSTNAME>"}
node_filesystem_size_bytes{job="linux-hosts",host="<HOSTNAME>"}
```

Then confirm the VM appears in the dashboard's `Linux host` selector and core panels populate.

Current provisioned Linux/node dashboards on `ids-01` include:

```text
homelab-noc2.json
homelab-noc.json
linux-os-monitoring.json
```

---

# Stage 10 - Reboot persistence

Before closing commissioning:

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

Then re-run the Prometheus canonical/dashboard-compatible queries and generate another unique journal event.

---

# Acceptance checklist

- [ ] Correct monitoring authority verified.
- [ ] Prometheus and Loki reachable from VM.
- [ ] Alloy installed through Ansible.
- [ ] Alloy configuration validates before restart.
- [ ] Service enabled and active.
- [ ] UI bound to `127.0.0.1:12345`.
- [ ] Readiness passes.
- [ ] Health passes.
- [ ] Alloy can read journal as unprivileged account.
- [ ] Metrics visible in authoritative Prometheus.
- [ ] `hostname=<HOSTNAME>` present.
- [ ] `host=<HOSTNAME>` present.
- [ ] `job=linux-hosts` present.
- [ ] Core CPU/memory/filesystem metrics visible.
- [ ] Duplicate metrics check passes.
- [ ] Unique journal event visible in authoritative Loki.
- [ ] VM appears in the `Linux OS Monitoring` host selector.
- [ ] Dashboard core panels populate.
- [ ] Second Ansible apply is idempotent.
- [ ] Reboot persistence passes.
- [ ] No secrets entered Git plaintext.

---

# Rollback

Use Git/Ansible as the source of truth. If the managed configuration must be rolled back:

1. restore the previous known-good role/template revision;
2. run `alloy validate` on the rendered configuration;
3. apply through Ansible;
4. verify readiness/health;
5. verify central metrics/logs.

If Alloy was newly installed solely for a failed commissioning attempt and removal is explicitly required:

```bash
sudo systemctl disable --now alloy
sudo apt-get remove alloy
```

Do not remove central Prometheus remote-write support while any Alloy-managed host depends on it.

---

## Completion record

```text
Host:
IP:
Role:
OS:
Alloy version:
Prometheus destination:
Loki destination:
Syntax check: PASS / FAIL
Check mode: PASS / FAIL
Apply: PASS / FAIL
Idempotence: PASS / FAIL
Ready: PASS / FAIL
Healthy: PASS / FAIL
Journal access: PASS / FAIL
Metrics E2E: PASS / FAIL
Dashboard label compatibility: PASS / FAIL
Logs E2E: PASS / FAIL
Grafana dashboard: PASS / FAIL
Duplicate check: PASS / FAIL
Reboot persistence: PASS / FAIL
Date:
Operator:
Notes:
```
