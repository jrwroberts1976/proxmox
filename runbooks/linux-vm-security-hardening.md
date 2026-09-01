# Linux VM Security Hardening Gate

## 1. Purpose

Security hardening is a mandatory build stage for new Debian Linux VMs before observability and application services are commissioned.

The authoritative implementation is:

```text
ansible/linux-security-hardening/
```

Required build order:

```text
OpenTofu VM creation
        |
Guest/cloud-init acceptance
        |
Linux security hardening
        |
Alloy observability acceptance
        |
PostgreSQL
        |
TimescaleDB
        |
Nginx
```

Passing this runbook does **not** authorize jumping directly to PostgreSQL. The next mandatory gate is `linux-vm-observability-bootstrap.md`.

---

## 2. Validated controls

The current role deliberately implements a narrow validated control set.

### 2.1 Remove weak OpenSSH UMAC-64 algorithms

Managed file:

```text
/etc/ssh/sshd_config.d/90-homelab-macs.conf
```

Policy:

```text
MACs -umac-64-etm@openssh.com,umac-64@openssh.com
```

Before reload, the role validates:

```bash
/usr/sbin/sshd -t
```

It then checks the effective `sshd -T` result and fails if either weak UMAC-64 algorithm remains.

### 2.2 Block IPv4 ICMP timestamp requests

Managed service:

```text
homelab-icmp-timestamp-block.service
```

The service idempotently enforces an IPv4 ICMP timestamp-request DROP rule while preserving normal ping and SSH access.

---

## 3. Explicit non-goals

This role does not:

- enable a global Proxmox/host firewall;
- implement a complete CIS/STIG baseline;
- disable TCP timestamps;
- alter unrelated SSH authentication/algorithm policy;
- replace Greenbone verification.

TCP timestamps remain a separately managed/accepted low-severity issue unless policy deliberately changes.

---

# Stage 0 - Preconditions

Do not run hardening until guest acceptance has passed:

- VM exists through OpenTofu;
- Debian 13 booted successfully;
- cloud-init completed;
- SSH public-key access works;
- hostname/network identity is approved;
- DNS/routing work;
- QEMU guest agent works where enabled;
- no unexpected failed services exist.

Keep a working administrative SSH session available during the first SSH-policy change.

Capture pre-change state:

```bash
sudo /usr/sbin/sshd -T | grep '^macs '
sudo /usr/sbin/iptables -S INPUT
systemctl --failed
```

---

# Stage 1 - Inventory and connectivity

Use the existing hardening inventory/playbook under:

```text
ansible/linux-security-hardening/
```

For VM101 use the approved address rather than guessing one.

Example shape:

```yaml
all:
  children:
    linux_security_hardening:
      hosts:
        app-platform-01:
          ansible_host: 192.168.2.253
          ansible_user: james
          ansible_become: true
```

Do not commit passwords/private keys.

From TestServer:

```bash
cd /home/james/projects/proxmox/ansible/linux-security-hardening

ansible-playbook -i inventory.yml playbook.yml --syntax-check
ansible -i inventory.yml linux_security_hardening -m ping --limit app-platform-01
```

Do not disable SSH host-key checking to bypass an identity mismatch.

---

# Stage 2 - Apply

Run against the intended VM only during first commissioning:

```bash
ansible-playbook \
  -i inventory.yml \
  playbook.yml \
  --limit app-platform-01
```

If privilege escalation requires an interactive password, use the approved local invocation method rather than storing the password. VM101 currently has securely configured passwordless sudo for its Ansible commissioning path, so `--ask-become-pass` is not inherently required there.

---

# Stage 3 - Fresh SSH validation

After the SSH policy change, establish a **new** SSH session:

```bash
ssh james@<VM_IP> 'hostname && echo SSH_PASS'
```

A pre-existing session alone is not proof that new connections work.

---

# Stage 4 - SSH MAC validation

On the VM:

```bash
sudo /usr/sbin/sshd -T | grep '^macs '
```

These must be absent:

```text
umac-64-etm@openssh.com
umac-64@openssh.com
```

External verification where appropriate:

```bash
nmap -Pn --script ssh2-enum-algos -p 22 <VM_IP> \
  | sed -n '/mac_algorithms:/,/compression_algorithms:/p'
```

---

# Stage 5 - ICMP timestamp validation

On the VM:

```bash
sudo /usr/sbin/iptables -C INPUT \
  -p icmp \
  --icmp-type timestamp-request \
  -j DROP

systemctl is-enabled homelab-icmp-timestamp-block.service
systemctl is-active homelab-icmp-timestamp-block.service
```

From a trusted scanner/admin host, run the established ICMP timestamp probe and confirm no timestamp reply is returned.

Normal connectivity must still pass:

```bash
ping -c 3 <VM_IP>
ssh james@<VM_IP> 'hostname && echo PASS'
```

---

# Stage 6 - Idempotence

Run the hardening playbook a second time.

Expected:

- no duplicate ICMP rule;
- no unnecessary SSH config change;
- no failed tasks;
- fresh SSH still works.

Check matching ICMP rule count/content:

```bash
sudo /usr/sbin/iptables -S INPUT \
  | grep -- '--icmp-type 13'
```

---

# Stage 7 - Security scan closure

Re-run the relevant Greenbone checks.

The security gate closes when:

- weak UMAC-64 findings are absent;
- ICMP timestamp finding is absent;
- fresh SSH works;
- normal ping works;
- role is idempotent;
- remaining accepted risks are documented.

---

# Stage 8 - Handover to observability

After hardening passes, the **next** runbook is:

```text
runbooks/linux-vm-observability-bootstrap.md
```

Do not install PostgreSQL, TimescaleDB or Nginx until the observability gate is also closed.

The current new-VM observability standard is:

```text
Grafana Alloy
 -> metrics -> ids-01 Prometheus 192.168.2.242:9090
 -> logs    -> ids-01 Loki       192.168.2.242:3100
 -> Grafana on ids-01
```

---

# Rollback

## SSH hardening

```bash
sudo rm -f /etc/ssh/sshd_config.d/90-homelab-macs.conf
sudo /usr/sbin/sshd -t
sudo systemctl reload ssh
```

## ICMP timestamp control

```bash
sudo systemctl disable --now homelab-icmp-timestamp-block.service
sudo rm -f /etc/systemd/system/homelab-icmp-timestamp-block.service
sudo systemctl daemon-reload
```

After rollback, revalidate SSH/network behavior and update Git/Ansible so the source of truth matches the recovered state.

---

## Acceptance checklist

- [ ] Guest commissioning already passed.
- [ ] Ansible syntax check passes.
- [ ] Ansible connectivity passes.
- [ ] Hardening playbook completes against only intended VM.
- [ ] Fresh SSH succeeds after change.
- [ ] UMAC-64 algorithms absent.
- [ ] ICMP timestamp requests blocked.
- [ ] Normal ping remains functional.
- [ ] ICMP timestamp service enabled/active.
- [ ] Second Ansible run is idempotent.
- [ ] Matching security findings cleared/documented.
- [ ] Next stage explicitly set to observability, not PostgreSQL.

---

## VM101 status

As of 2026-09-01:

```text
VM101 security hardening: PASS
UMAC-64 removal:          PASS
ICMP timestamp block:     PASS
Fresh SSH:                PASS
Idempotence:              PASS
```

VM101 has already moved into the observability stage; database installation remains gated until observability closure.
