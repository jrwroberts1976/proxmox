# Nginx Installation Runbook

## 1. Purpose

This runbook defines the controlled installation and validation procedure for Nginx on a Debian VM managed through the Proxmox IaC and Ansible workflow.

The existing Ansible implementation is:

```text
ansible/playbooks/nginx.yml
ansible/roles/nginx/
```

The required platform sequence is:

```text
Linux VM IaC
  -> guest acceptance
  -> Linux security hardening
  -> Alloy observability acceptance
  -> PostgreSQL
  -> TimescaleDB
  -> Nginx
```

Nginx may run on the same initial lab VM as PostgreSQL/TimescaleDB for the first proof, but the roles remain separate so it can later be moved to a dedicated web/proxy VM without redesigning the automation.

---

## 2. Preconditions

Required:

- Linux VM deployment runbook has passed;
- Linux security-hardening gate has passed;
- observability gate has passed and remains healthy;
- Ansible can reach the host;
- intended Nginx role is understood: static site, reverse proxy, or application frontend;
- upstream service address/port is known if proxying;
- no conflicting service is already bound to the intended listen port;
- DNS/TLS requirements are defined before exposing the service outside the lab.

Verify from the target VM:

```bash
ss -ltnp
systemctl --failed
systemctl is-active alloy
curl -fsS http://127.0.0.1:12345/-/healthy
```

From the controller:

```bash
cd ansible
ansible nginx_servers -m ping
```

For a new Proxmox VM, authoritative host metrics/logs must already be reaching `ids-01` before Nginx installation begins.

---

## 3. Current role behaviour

Current defaults:

```yaml
nginx_packages:
  - nginx
nginx_service_name: nginx
nginx_remove_default_site: true
nginx_sites: []
```

The role:

1. verifies a Debian-family guest;
2. installs Nginx;
3. removes the default enabled site when configured;
4. renders declared sites into `/etc/nginx/sites-available/`;
5. creates enabled-site symlinks;
6. runs `nginx -t` before reload;
7. reloads Nginx only after configuration changes;
8. ensures the service is enabled and running.

The role uses the operating-system Nginx package by default. Moving to the upstream nginx.org repository is a separate design decision and should not be mixed into the first build without a reason.

---

## 4. Inventory

Place the target host in `nginx_servers`.

Example:

```yaml
all:
  children:
    nginx_servers:
      hosts:
        db-01:
          ansible_host: <VM_IP>
```

The same VM may also belong to `postgresql_servers` and `timescaledb_servers` during the initial proof and should remain under the Alloy management model established during observability commissioning.

Validate:

```bash
cd ansible
ansible-inventory --graph
ansible nginx_servers -m ping
```

---

## 5. Site variables

The role supports site objects with values such as:

```text
name
listen
server_name
client_max_body_size
root
index
proxy_pass
extra_lines
```

### Reverse-proxy example

```yaml
nginx_sites:
  - name: homelab-app
    listen: "80"
    server_name: app.example.internal
    proxy_pass: http://127.0.0.1:8080
```

### Static-site example

```yaml
nginx_sites:
  - name: status
    listen: "80"
    server_name: status.example.internal
    root: /var/www/status
    index: index.html
```

Do not use fake public DNS names in the real inventory. Use the actual internal naming decision when it is agreed.

---

# Stage 0 - Port and exposure gate

## 6. Confirm listen ports are available

On the target VM:

```bash
ss -ltnp | grep -E ':(80|443)\b' || true
```

If another service already owns the required port, stop and resolve the design conflict.

## 7. Confirm intended exposure

For the first lab deployment, keep Nginx internal to the homelab.

Do not create router port-forwarding or public exposure as part of this runbook.

If TLS is required later, certificate issuance, private keys, DNS and renewal must be handled through an approved secret/certificate workflow.

---

# Stage 1 - Static validation

## 8. Syntax check

```bash
cd ansible
ansible-playbook playbooks/nginx.yml --syntax-check
```

## 9. Check mode

```bash
ansible-playbook playbooks/nginx.yml \
  --check --diff \
  --limit <NGINX_HOST>
```

Review the intended package, site files, symlinks and default-site removal.

No unrelated web configuration should change.

---

# Stage 2 - Install and configure Nginx

## 10. Apply the playbook

```bash
cd ansible
ansible-playbook playbooks/nginx.yml \
  --limit <NGINX_HOST>
```

The role runs `nginx -t` before reloading the service. A failed syntax validation must stop the deployment rather than loading a broken configuration.

---

# Stage 3 - Service validation

## 11. Confirm service state

On the target VM:

```bash
systemctl --no-pager --full status nginx
systemctl is-enabled nginx
systemctl is-active nginx
```

Expected: enabled and active.

## 12. Validate configuration

```bash
nginx -t
```

Expected:

```text
syntax is ok
test is successful
```

## 13. Confirm listeners

```bash
ss -ltnp | grep nginx
```

Only intended ports/interfaces should be present.

---

# Stage 4 - Configuration validation

## 14. Inspect enabled sites

```bash
find /etc/nginx/sites-available -maxdepth 1 -type f -print
find /etc/nginx/sites-enabled -maxdepth 1 -type l -ls
```

If `nginx_remove_default_site: true`, `/etc/nginx/sites-enabled/default` should not exist.

## 15. Inspect generated configuration

```bash
nginx -T
```

Review carefully for:

- correct server name;
- correct listen port;
- correct upstream if reverse proxying;
- no accidentally exposed management endpoint;
- no plaintext secret embedded in configuration.

---

# Stage 5 - Functional test

## 16. Local HTTP test

On the Nginx VM:

```bash
curl -fsSI http://127.0.0.1/
```

For a named virtual host:

```bash
curl -fsSI -H 'Host: <SERVER_NAME>' http://127.0.0.1/
```

Expected: an intentional HTTP response from the configured site/upstream.

## 17. Remote internal test

From another homelab host:

```bash
curl -fsSI http://<NGINX_IP>/
```

Or for a named site:

```bash
curl -fsSI -H 'Host: <SERVER_NAME>' http://<NGINX_IP>/
```

If proxying, confirm the upstream application receives the request and returns the expected result.

---

# Stage 6 - Reverse-proxy checks

## 18. Validate forwarded headers

The existing template sets:

```text
Host
X-Real-IP
X-Forwarded-For
X-Forwarded-Proto
```

If an application uses these values for security or URL generation, validate its trusted-proxy configuration before production use.

## 19. Upstream failure behaviour

Temporarily stop only a disposable/test upstream and verify Nginx fails in the expected way rather than hanging indefinitely.

Restore the upstream and verify service recovery.

Do not perform this test against a production dependency without a maintenance plan.

---

# Stage 7 - Logging and observability

## 20. Preserve the accepted host telemetry

Host-level observability must already be commissioned through:

```text
runbooks/linux-vm-observability-bootstrap.md
```

After Nginx installation, re-check it has not regressed:

```bash
systemctl is-active alloy
curl -fsS http://127.0.0.1:12345/-/healthy
systemctl --failed --no-legend
```

Centrally verify:

```promql
node_uname_info{hostname="<HOSTNAME>"}
```

Generate a unique journal event if log flow needs to be re-proven.

Check Nginx logs locally:

```bash
journalctl -u nginx -n 100 --no-pager
ls -l /var/log/nginx/
```

Application-specific Nginx access/error log ingestion can be added to Alloy deliberately after reviewing volume and sensitivity. Do not recursively ingest arbitrary log directories by default.

At minimum monitor:

- host availability/metric absence;
- CPU/RAM/disk usage;
- Nginx service failure;
- relevant Nginx error logs.

---

# Stage 8 - Security gate

## 21. Minimum requirements

Before production acceptance:

- do not expose Nginx directly to the Internet by default;
- remove unused/default sites;
- avoid directory listings unless explicitly needed;
- do not place credentials/API keys in site files;
- scope firewall access to the intended clients;
- use TLS for sensitive application traffic when appropriate;
- keep package patching in the normal OS maintenance process;
- run a Greenbone/security scan once the service exposure is final.

---

# Stage 9 - Idempotence

## 22. Run the playbook again

```bash
ansible-playbook playbooks/nginx.yml \
  --limit <NGINX_HOST>
```

Expected: no unexpected changes and no unnecessary reload.

---

# Stage 10 - Rollback

## 23. Configuration rollback

If a site change fails:

1. revert the site definition in Git;
2. rerun the Ansible playbook;
3. run `nginx -t`;
4. verify HTTP behaviour;
5. confirm Alloy/host observability remains healthy.

Avoid editing generated files manually because Ansible will overwrite them on the next run.

## 24. Fresh disposable VM rollback

If Nginx is part of the first disposable platform proof and the entire build needs to be abandoned, destroy/recreate the guest through the Linux VM IaC runbook rather than manually trying to unwind every package/configuration change.

---

## 25. Acceptance criteria

Nginx installation is complete when:

- [ ] VM security/observability baseline was already accepted.
- [ ] Ansible syntax check passes.
- [ ] Playbook applies successfully.
- [ ] `nginx -t` succeeds.
- [ ] Nginx is enabled and active.
- [ ] Only intended sites are enabled.
- [ ] Default site is removed when required.
- [ ] Local HTTP test succeeds.
- [ ] Internal remote HTTP test succeeds.
- [ ] Reverse-proxy upstream works if configured.
- [ ] No plaintext secrets are present in generated configuration/Git.
- [ ] Alloy remains healthy and host metrics/logs remain visible after installation.
- [ ] Nginx service/log alerting strategy is defined where required.
- [ ] Second Ansible run is idempotent.

At this point the initial Linux + PostgreSQL + TimescaleDB + Nginx platform build has passed its component installation gates and can move to integrated testing, backup/restore, application-specific observability and service-specific alerting.
