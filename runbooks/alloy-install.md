# Grafana Alloy Installation Runbook

## 1. Purpose

This runbook defines the standard procedure for installing, configuring, validating, and operating Grafana Alloy on Linux hosts and VMs in the Proxmox homelab.

The intended observability path is:

```text
Linux host / VM
   |
   +--> systemd journal
   +--> application log files
   +--> optional host/application metrics
   |
   v
Grafana Alloy
   |
   +--> Loki        (logs)
   +--> Prometheus-compatible backend (optional metrics)
   +--> OTLP backend (future traces/telemetry)
   |
   v
Grafana
```

The immediate standard is to use Alloy as the host telemetry collector and forward Linux logs to the existing Loki/Grafana platform. The design should remain reusable for later Ansible automation.

---

## 2. Scope

This runbook covers:

- Debian/Ubuntu installation from the official Grafana APT repository;
- the packaged `alloy` systemd service;
- the standard `/etc/alloy/config.alloy` configuration;
- Alloy service identity and permissions;
- systemd journal collection;
- optional application file collection;
- forwarding logs to Loki;
- configuration validation before reload/restart;
- Alloy health and readiness checks;
- Grafana/Loki ingestion validation;
- security controls for the Alloy HTTP endpoint;
- upgrade, rollback, uninstall, and troubleshooting;
- a future Ansible implementation target.

This runbook does not define every possible Alloy pipeline. Application-specific pipelines such as Suricata, Docker, PostgreSQL, Nginx, OTLP, or custom JSON parsing should be documented separately once the base Alloy installation is healthy.

---

## 3. Standard

Use these defaults unless there is a documented reason to deviate.

| Item | Standard |
|---|---|
| Package source | Official Grafana APT repository |
| Linux service | `alloy.service` |
| Service account | `alloy` |
| Main configuration | `/etc/alloy/config.alloy` |
| Debian environment file | `/etc/default/alloy` |
| State/storage path | `/var/lib/alloy` |
| Local HTTP/UI endpoint | `127.0.0.1:12345` |
| Readiness endpoint | `http://127.0.0.1:12345/-/ready` |
| Health endpoint | `http://127.0.0.1:12345/-/healthy` |
| Internal metrics | `http://127.0.0.1:12345/metrics` |
| Log destination | Existing Loki service |
| Configuration management target | Ansible-managed |

Alloy supports Linux AMD64 and ARM64, making this installation model suitable for both x86 Proxmox guests and supported ARM Linux hosts.

---

## 4. Security principles

1. Run Alloy using the packaged unprivileged `alloy` account.
2. Do not run Alloy as root simply to solve log-file permission problems.
3. Keep the Alloy HTTP/UI listener on `127.0.0.1:12345` unless remote access is specifically required.
4. Do not expose port `12345` to the Internet.
5. Grant only the filesystem and journal permissions required by configured components.
6. Do not store passwords, tokens, or API keys in plaintext Git.
7. Validate configuration before reloading or restarting Alloy.
8. Preserve a working configuration before every material change.

---

## 5. Preconditions

Before starting, confirm:

- [ ] Hostname and management IP are correct.
- [ ] DNS works.
- [ ] Internet access to `apt.grafana.com` is available for installation.
- [ ] Time synchronisation is healthy.
- [ ] The Loki destination is known and reachable from the host.
- [ ] SSH/sudo access is available.
- [ ] No existing Alloy installation is already managing the same telemetry.
- [ ] Required application log locations are known.
- [ ] No secret values will be committed to Git.

Capture the intended values:

```text
HOSTNAME=
HOST_IP=
LOKI_HOST=
LOKI_PORT=3100
LOKI_PUSH_PATH=/loki/api/v1/push
ENVIRONMENT=homelab
ROLE=
```

Do not copy placeholder hostnames or addresses into production configuration without checking them.

---

# Stage 1 - Host baseline

## 6. Capture the current state

Run:

```bash
hostnamectl
ip -br addr
cat /etc/os-release
uname -m
timedatectl
systemctl --failed
```

Expected result:

- hostname is correct;
- intended management address is present;
- architecture is supported;
- time is synchronised;
- no unexpected failed services exist.

If the machine is unhealthy before Alloy installation, resolve that first.

---

# Stage 2 - Install Grafana Alloy

## 7. Install prerequisites

On Debian/Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y wget gpg ca-certificates
```

---

## 8. Add the official Grafana package signing key

```bash
sudo mkdir -p /etc/apt/keyrings
sudo wget -O /etc/apt/keyrings/grafana.asc \
  https://apt.grafana.com/gpg-full.key
sudo chmod 0644 /etc/apt/keyrings/grafana.asc
```

Verify the file exists:

```bash
ls -l /etc/apt/keyrings/grafana.asc
```

---

## 9. Add the Grafana stable APT repository

```bash
echo \
  "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" \
  | sudo tee /etc/apt/sources.list.d/grafana.list
```

Update package metadata:

```bash
sudo apt-get update
```

Check that Alloy is available:

```bash
apt-cache policy alloy
```

---

## 10. Install Alloy

```bash
sudo apt-get install -y alloy
```

Confirm the installed version:

```bash
alloy --version
```

Record the installed version in the implementation/build log.

---

# Stage 3 - Verify packaged service layout

## 11. Inspect the service

```bash
systemctl cat alloy
```

Confirm the service exists and is intended to run as the `alloy` account:

```bash
systemctl cat alloy | grep -E '^(User|Group)='
```

Also verify the runtime process after start:

```bash
ps -eo user,group,pid,cmd | grep '[a]lloy'
```

Do not modify the vendor systemd unit directly. Use a systemd drop-in if service-level overrides are required.

---

## 12. Verify standard paths

```bash
sudo ls -ld /etc/alloy /var/lib/alloy
sudo ls -l /etc/alloy/config.alloy
sudo test -f /etc/default/alloy && sudo cat /etc/default/alloy
```

The normal Debian package layout is:

```text
/etc/alloy/config.alloy
/etc/default/alloy
/var/lib/alloy
```

The service normally passes `--storage.path=/var/lib/alloy`.

---

# Stage 4 - Preserve the package configuration

## 13. Back up the current configuration

Before editing:

```bash
sudo cp -a \
  /etc/alloy/config.alloy \
  /etc/alloy/config.alloy.before-homelab
```

For later changes use a dated or descriptive backup name.

Example:

```bash
sudo cp -a /etc/alloy/config.alloy \
  "/etc/alloy/config.alloy.before-$(date +%Y%m%d-%H%M%S)"
```

Git should hold the authoritative configuration template once the Ansible role is introduced, but local backups remain useful during initial bring-up.

---

# Stage 5 - Configure journal access

## 14. Grant systemd journal access

For `loki.source.journal`, the `alloy` user requires access to the journal.

Check membership:

```bash
id alloy
```

The account should have access through the `adm` and `systemd-journal` groups where those groups exist.

If required:

```bash
sudo usermod -aG adm,systemd-journal alloy
```

A service restart is required after changing group membership.

```bash
sudo systemctl restart alloy
```

Verify Alloy can read the journal without running as root:

```bash
sudo -u alloy journalctl -n 5 --no-pager
```

If this command returns permission errors, resolve them before building a journal pipeline.

---

# Stage 6 - Create the baseline Loki pipeline

## 15. Determine the Loki endpoint

From the Alloy host, verify that the Loki host resolves and is reachable.

For example:

```bash
getent hosts <LOKI_HOST>
nc -vz <LOKI_HOST> 3100
```

If Loki exposes its readiness endpoint to the host, optionally check:

```bash
curl -fsS http://<LOKI_HOST>:3100/ready
```

Do not continue with a destination name that does not resolve from the Alloy host.

If Loki runs inside Docker, remember that Docker service names such as `loki` normally resolve only inside the appropriate Docker network. A systemd Alloy installation on another host normally needs a LAN DNS name or IP address instead.

---

## 16. Baseline systemd-journal configuration

Replace `/etc/alloy/config.alloy` with a deliberately small first pipeline.

Example:

```alloy
loki.source.journal "system" {
  forward_to = [loki.write.local.receiver]

  labels = {
    hostname    = constants.hostname,
    environment = "homelab",
    job         = "systemd-journal",
  }
}

loki.write "local" {
  endpoint {
    url = "http://<LOKI_HOST>:3100/loki/api/v1/push"
  }
}
```

Replace `<LOKI_HOST>` with the actual reachable Loki hostname or IP.

Important Alloy syntax notes:

- configuration uses Alloy syntax, not YAML;
- use `//` for comments rather than shell-style `#` comments;
- map/list entries require valid Alloy/HCL-style syntax;
- do not paste secrets directly into the file if the configuration will be stored in Git.

Set appropriate ownership and permissions:

```bash
sudo chown root:alloy /etc/alloy/config.alloy
sudo chmod 0640 /etc/alloy/config.alloy
```

---

# Stage 7 - Validate before applying

## 17. Format check

Alloy can format the configuration:

```bash
sudo alloy fmt /etc/alloy/config.alloy
```

Review the resulting file:

```bash
sudo sed -n '1,240p' /etc/alloy/config.alloy
```

---

## 18. Validate the configuration

Never reload/restart Alloy with an unvalidated configuration.

Run:

```bash
sudo alloy validate /etc/alloy/config.alloy
```

Expected result: validation completes without errors.

If validation fails, do not restart the service. Correct the file or restore the previous configuration.

---

# Stage 8 - Start and validate Alloy

## 19. Enable and start the service

```bash
sudo systemctl enable --now alloy
```

Check status:

```bash
systemctl --no-pager --full status alloy
```

Expected result:

```text
Active: active (running)
```

---

## 20. Inspect Alloy logs

```bash
sudo journalctl -u alloy -n 100 --no-pager
```

For a live view during initial commissioning:

```bash
sudo journalctl -u alloy -f
```

Look for:

- configuration parse errors;
- permission-denied errors;
- DNS failures;
- Loki connection failures;
- HTTP 4xx/5xx responses;
- repeated retry/backoff messages.

---

## 21. Readiness check

```bash
curl -fsS http://127.0.0.1:12345/-/ready
```

Expected result includes:

```text
Alloy is ready.
```

---

## 22. Health check

```bash
curl -fsS http://127.0.0.1:12345/-/healthy
```

Expected result includes:

```text
All Alloy components are healthy.
```

A ready process can still contain an unhealthy component, so check both endpoints.

---

## 23. Internal metrics check

```bash
curl -fsS http://127.0.0.1:12345/metrics | head -40
```

Useful controller metrics include metrics beginning with:

```text
alloy_component_
```

Confirm the endpoint returns Prometheus-format data.

---

# Stage 9 - Validate end-to-end Loki ingestion

## 24. Generate a controlled test log

Create an identifiable journal message:

```bash
logger -t homelab-alloy-test \
  "Alloy onboarding test $(hostname) $(date --iso-8601=seconds)"
```

Confirm it exists locally:

```bash
journalctl -t homelab-alloy-test -n 5 --no-pager
```

---

## 25. Validate in Grafana Explore

In Grafana Explore, select the existing Loki data source.

Start with:

```logql
{hostname="<HOSTNAME>"}
```

Then narrow the query if required:

```logql
{hostname="<HOSTNAME>", job="systemd-journal"} |= "Alloy onboarding test"
```

Acceptance condition:

- the generated message arrives in Loki;
- `hostname` is correct;
- `environment` is `homelab`;
- the timestamp is sensible;
- no duplicate stream is being generated by another collector.

Do not declare the installation complete merely because `alloy.service` is running. End-to-end delivery must be proven.

---

# Stage 10 - Optional application log files

## 26. Prefer explicit log-file selection

Do not recursively collect all files below `/var/log` without reviewing the volume and sensitivity of the data first.

For an application directory such as:

```text
/var/log/myapp/*.log
```

prefer a targeted file source.

Current Alloy supports built-in file matching inside `loki.source.file`, so a separate `local.file_match` component is not required for a simple new deployment.

Example:

```alloy
loki.source.file "myapp" {
  targets = [
    {
      __path__    = "/var/log/myapp/*.log",
      hostname    = constants.hostname,
      environment = "homelab",
      job         = "myapp",
    },
  ]

  forward_to   = [loki.write.local.receiver]
  tail_from_end = true

  file_match {
    enabled     = true
    sync_period = "10s"
  }
}
```

This can exist alongside the journal source and reuse the same `loki.write.local.receiver` destination.

---

## 27. Grant application log access with ACLs

Do not add the `alloy` user to broad application groups purely to read logs.

Prefer filesystem ACLs where appropriate:

```bash
sudo apt-get install -y acl
sudo setfacl -R -m u:alloy:rx /var/log/myapp
sudo setfacl -R -d -m u:alloy:rx /var/log/myapp
```

Then prove Alloy can read the files:

```bash
sudo -u alloy find /var/log/myapp -maxdepth 1 -type f -readable -print
```

If files contain secrets or sensitive data, review whether they should be ingested at all before granting access.

---

# Stage 11 - Optional Alloy UI access

## 28. Keep port 12345 local by default

The preferred default is:

```text
127.0.0.1:12345
```

Check:

```bash
sudo ss -ltnp | grep ':12345'
```

A local bind means the UI/API is available for SSH-based troubleshooting without unnecessarily exposing it to the LAN.

---

## 29. Temporary SSH tunnel for UI access

From an administrator workstation:

```bash
ssh -L 12345:127.0.0.1:12345 <USER>@<ALLOY_HOST>
```

Then open locally:

```text
http://127.0.0.1:12345
```

This is preferred over changing Alloy to listen on all interfaces solely for occasional troubleshooting.

---

## 30. If LAN exposure is genuinely required

On Debian, runtime arguments are managed through:

```text
/etc/default/alloy
```

The `CUSTOM_ARGS` value can include:

```text
--server.http.listen-addr=<HOST_IP>:12345
```

After changing it:

```bash
sudo systemctl restart alloy
```

If port `12345` is exposed to the LAN:

- restrict access using host/network firewall policy;
- do not expose it to the Internet;
- consider TLS/authentication if exposure is broader than a trusted management segment.

Recheck:

```bash
sudo ss -ltnp | grep ':12345'
```

---

# Stage 12 - Configuration change procedure

## 31. Standard safe-change sequence

For every material Alloy configuration change:

```text
1. Capture current service health
2. Back up current config
3. Edit config
4. alloy fmt
5. alloy validate
6. reload Alloy
7. check service status
8. check /-/ready
9. check /-/healthy
10. inspect journal
11. prove data arrived at destination
```

Commands:

```bash
sudo cp -a /etc/alloy/config.alloy \
  "/etc/alloy/config.alloy.before-$(date +%Y%m%d-%H%M%S)"

sudo alloy fmt /etc/alloy/config.alloy
sudo alloy validate /etc/alloy/config.alloy
sudo systemctl reload alloy
systemctl --no-pager --full status alloy
curl -fsS http://127.0.0.1:12345/-/ready
curl -fsS http://127.0.0.1:12345/-/healthy
sudo journalctl -u alloy -n 100 --no-pager
```

If the package/systemd environment does not support reload correctly for a particular change, use a controlled restart after validation:

```bash
sudo systemctl restart alloy
```

---

# Stage 13 - Monitoring Alloy itself

## 32. Local service monitoring

At minimum verify:

```bash
systemctl is-active alloy
systemctl is-enabled alloy
curl -fsS http://127.0.0.1:12345/-/ready
curl -fsS http://127.0.0.1:12345/-/healthy
```

The Alloy `/metrics` endpoint exposes internal health/operation metrics suitable for Prometheus scraping if a secure scrape design is implemented.

Do not expose the whole Alloy UI/API broadly merely to scrape `/metrics`. If remote scraping is required, document and restrict the endpoint appropriately.

---

## 33. Minimum alerting expectations

Once Alloy monitoring is integrated, important hosts should eventually alert on:

- `alloy.service` not running;
- Alloy HTTP health failure;
- persistent component unhealthy state;
- sustained Loki write/retry failures;
- telemetry silence for a host that should be continuously reporting.

A destination-side "no logs received" alert can catch failures that a simple process-up alert cannot.

---

# Stage 14 - Troubleshooting

## 34. Service will not start

Run:

```bash
sudo alloy validate /etc/alloy/config.alloy
sudo journalctl -u alloy -n 200 --no-pager
systemctl cat alloy
```

Most common causes:

- invalid Alloy syntax;
- wrong component names/arguments;
- configuration-file permission problems;
- runtime argument errors.

---

## 35. Alloy is running but no journal logs arrive

Check:

```bash
id alloy
sudo -u alloy journalctl -n 5 --no-pager
curl -fsS http://127.0.0.1:12345/-/healthy
sudo journalctl -u alloy -n 100 --no-pager
```

The `alloy` account normally needs journal access through `adm` and `systemd-journal`.

After changing group membership:

```bash
sudo systemctl restart alloy
```

---

## 36. Alloy can read logs but Loki receives nothing

Check destination resolution:

```bash
getent hosts <LOKI_HOST>
```

Check TCP reachability:

```bash
nc -vz <LOKI_HOST> 3100
```

Inspect Alloy logs:

```bash
sudo journalctl -u alloy -n 200 --no-pager \
  | grep -Ei 'loki|error|fail|retry|dns|resolve|timeout|refused'
```

Common causes:

- wrong Loki URL;
- Docker-only DNS name used from a non-Docker host;
- DNS failure;
- firewall/routing problem;
- Loki unavailable;
- authentication requirement not represented in `loki.write`.

---

## 37. File source discovers nothing

Check as the service account:

```bash
sudo -u alloy find /var/log/myapp -maxdepth 1 -type f -print
sudo -u alloy head -n 1 /var/log/myapp/<FILE>
```

Inspect ACLs:

```bash
getfacl /var/log/myapp
getfacl /var/log/myapp/<FILE>
```

Remember that directory execute permission is required to traverse a path.

---

## 38. Port 12345 is unexpectedly exposed

Check:

```bash
sudo ss -ltnp | grep ':12345'
sudo grep -n 'CUSTOM_ARGS' /etc/default/alloy
systemctl cat alloy
```

The preferred host installation binds the Alloy HTTP server to localhost unless remote access was explicitly approved.

---

## 39. High CPU or memory use

Review:

```bash
ps -o pid,user,%cpu,%mem,rss,vsz,cmd -C alloy
curl -fsS http://127.0.0.1:12345/metrics > /tmp/alloy-metrics.txt
sudo journalctl -u alloy -n 200 --no-pager
```

Then review:

- overly broad file globs;
- very high-volume log sources;
- parsing stages with excessive work;
- duplicate collection;
- unexpectedly high cardinality labels;
- downstream outages causing retries/buffering.

Do not immediately increase VM resources without determining whether the pipeline is misconfigured.

---

# Stage 15 - Upgrade procedure

## 40. Pre-upgrade checks

Before upgrading:

```bash
alloy --version
sudo alloy validate /etc/alloy/config.alloy
curl -fsS http://127.0.0.1:12345/-/healthy
sudo cp -a /etc/alloy/config.alloy \
  "/etc/alloy/config.alloy.pre-upgrade-$(date +%Y%m%d-%H%M%S)"
```

Review release notes before major/minor version changes where component behaviour may have changed.

---

## 41. Upgrade from APT

```bash
sudo apt-get update
apt-cache policy alloy
sudo apt-get install --only-upgrade alloy
```

Then verify:

```bash
alloy --version
systemctl --no-pager --full status alloy
curl -fsS http://127.0.0.1:12345/-/ready
curl -fsS http://127.0.0.1:12345/-/healthy
sudo journalctl -u alloy -n 100 --no-pager
```

Finally, generate a test log and prove end-to-end delivery again.

---

# Stage 16 - Rollback

## 42. Configuration rollback

If a configuration change fails after reload/restart:

```bash
sudo cp -a \
  /etc/alloy/config.alloy.before-homelab \
  /etc/alloy/config.alloy

sudo chown root:alloy /etc/alloy/config.alloy
sudo chmod 0640 /etc/alloy/config.alloy
sudo alloy validate /etc/alloy/config.alloy
sudo systemctl restart alloy
```

Then confirm:

```bash
curl -fsS http://127.0.0.1:12345/-/ready
curl -fsS http://127.0.0.1:12345/-/healthy
```

Use the most recent known-good backup rather than always using the initial package backup.

---

## 43. Stop Alloy without uninstalling

```bash
sudo systemctl disable --now alloy
```

This is the preferred emergency rollback if Alloy is causing load or telemetry problems and the configuration cannot be corrected immediately.

---

# Stage 17 - Uninstall

## 44. Remove Alloy

Stop the service:

```bash
sudo systemctl stop alloy
```

Remove the package:

```bash
sudo apt-get remove alloy
```

Do not automatically delete `/etc/alloy` or `/var/lib/alloy` until configuration/state retention requirements have been checked.

The Grafana APT repository may be retained if other Grafana packages use it. If it is no longer required, remove it deliberately:

```bash
sudo rm -i /etc/apt/sources.list.d/grafana.list
sudo apt-get update
```

---

# Stage 18 - Acceptance gate

## 45. Installation acceptance checklist

Do not mark Alloy onboarding complete until all applicable checks pass.

### Package/service

- [ ] Alloy installed from the approved package source.
- [ ] Installed version recorded.
- [ ] `alloy.service` is enabled.
- [ ] `alloy.service` is active.
- [ ] Process runs as the `alloy` user.

### Configuration

- [ ] `/etc/alloy/config.alloy` exists.
- [ ] Configuration has been formatted/reviewed.
- [ ] `alloy validate` passes.
- [ ] Configuration permissions do not expose secrets.

### Health

- [ ] `/-/ready` returns success.
- [ ] `/-/healthy` returns success.
- [ ] `/metrics` returns Alloy internal metrics locally.
- [ ] No persistent error/retry storm is present in `journalctl -u alloy`.

### Logs

- [ ] Alloy can read the intended systemd journal entries.
- [ ] Any required file sources are readable by `alloy` without root execution.
- [ ] Loki is reachable.
- [ ] Controlled test log appears in Grafana/Loki.
- [ ] Expected hostname/environment/job labels are present.
- [ ] No duplicate log stream is observed.

### Security

- [ ] Port `12345` is localhost-only unless explicitly approved otherwise.
- [ ] No Alloy/Loki secrets are stored in plaintext Git.
- [ ] File permissions/ACLs follow least privilege.

**Gate:** PASS only when the required items above are verified.

---

# Stage 19 - Future Ansible implementation

## 46. Target Ansible role

The long-term implementation should be a reusable role such as:

```text
ansible/roles/alloy/
├── defaults/main.yml
├── handlers/main.yml
├── tasks/main.yml
└── templates/config.alloy.j2
```

The role should manage:

1. Grafana repository key.
2. Grafana APT repository.
3. Alloy package installation/version policy.
4. `/etc/alloy/config.alloy`.
5. `/etc/default/alloy` where runtime flags are required.
6. Config file ownership/mode.
7. Journal group membership.
8. Optional application-log ACLs.
9. systemd enable/start/restart/reload.
10. `alloy validate` before service changes.
11. readiness/health verification.
12. optional controlled end-to-end log test.

Suggested inventory variables:

```yaml
alloy_enabled: true
alloy_environment: homelab
alloy_role: application
alloy_loki_url: "http://loki.example:3100/loki/api/v1/push"
alloy_collect_journal: true
alloy_file_sources: []
alloy_http_listen_address: "127.0.0.1:12345"
```

Secret values must use Ansible Vault, SOPS, or another approved secret mechanism rather than plaintext inventory variables.

---

## 47. Desired end state

Every Linux VM provisioned through the Proxmox IaC workflow should eventually follow this sequence:

```text
OpenTofu / Terraform
        |
        v
Proxmox VM
        |
        v
cloud-init
        |
        v
Ansible
   |         |
   |         +--> node_exporter / host monitoring
   |
   +------------> Grafana Alloy
                     |
                     +--> Loki
                     +--> future metrics/traces
        |
        v
Acceptance tests
        |
        v
Production service deployment
```

Observability should be installed and validated before important application workloads are declared production-ready.
