# Linux VM Security Hardening Gate

## 1. Purpose

Security hardening is a mandatory build stage for new Debian Linux VMs before application services such as PostgreSQL, TimescaleDB or Nginx are installed.

The current validated control set is implemented by the existing Ansible content under:

```text
ansible/linux-security-hardening/
```

This gate integrates those validated controls into the application-platform build without expanding their scope beyond what has already been tested.

The required build order is:

```text
OpenTofu VM creation
        |
        v
Guest commissioning / cloud-init acceptance
        |
        v
Linux security hardening
        |
        v
Observability / baseline acceptance
        |
        v
PostgreSQL
        |
        v
TimescaleDB
        |
        v
Nginx
```

For VM `101` (`app-platform-01`), PostgreSQL installation must not begin until this hardening gate passes.

---

## 2. Validated controls

The role currently applies two deliberately narrow controls that were already validated on Debian-family homelab hosts.

### 2.1 Remove weak OpenSSH UMAC-64 algorithms

The role installs:

```text
/etc/ssh/sshd_config.d/90-homelab-macs.conf
```

with:

```text
MACs -umac-64-etm@openssh.com,umac-64@openssh.com
```

Before SSH is reloaded, the role validates the configuration with:

```bash
/usr/sbin/sshd -t
```

It then checks the effective configuration with `sshd -T` and fails if either weak UMAC-64 algorithm remains.

### 2.2 Block IPv4 ICMP timestamp requests

The role installs and enables:

```text
homelab-icmp-timestamp-block.service
```

The unit idempotently enforces:

```bash
iptables -I INPUT 1 -p icmp --icmp-type timestamp-request -j DROP
```

Normal ICMP echo and SSH connectivity must continue to work.

---

## 3. Explicit non-goals

This hardening role is intentionally narrow.

It does **not**:

- enable the Proxmox firewall globally;
- replace a general host firewall policy;
- disable TCP timestamps;
- claim to implement a full CIS/STIG baseline;
- alter unrelated SSH algorithms or authentication settings.

TCP timestamps remain an accepted low-severity risk unless a separate approved control changes that decision.

---

## 4. VM commissioning prerequisites

Do not run hardening until the new guest has passed the basic IaC/guest acceptance gates:

- VM exists because it is declared in OpenTofu;
- Debian 13 has booted successfully;
- cloud-init has completed;
- SSH public-key access works;
- the approved hostname and network identity are known;
- DNS and routing work;
- QEMU guest agent works where enabled;
- no unexpected failed services are present.

For VM101, add the approved address to a local Ansible inventory only after its network identity has been accepted.

Do not commit passwords, private keys or temporary credential material.

---

## 5. Pre-change checks

Keep an existing administrative SSH session open during the first hardening run against a new host.

On the guest, capture the current state:

```bash
sudo /usr/sbin/sshd -T | grep '^macs '
sudo /usr/sbin/iptables -S INPUT
systemctl --failed
```

From a separate trusted administration host, confirm fresh SSH access before proceeding.

---

## 6. Inventory

Use the existing hardening inventory format under:

```text
ansible/linux-security-hardening/inventory.example.yml
```

For VM101, use the approved address rather than guessing an IP:

```yaml
all:
  children:
    linux_security_hardening:
      hosts:
        app-platform-01:
          ansible_host: <APPROVED_VM101_IP>
          ansible_user: james
          ansible_become: true
```

The real inventory may remain local until the permanent host inventory design is finalized. Secret material must not be committed.

---

## 7. Syntax and connectivity gates

From `TestServer`:

```bash
cd /home/james/projects/proxmox/ansible/linux-security-hardening

ansible-playbook -i inventory.yml playbook.yml --syntax-check
ansible -i inventory.yml linux_security_hardening -m ping --limit app-platform-01
```

If privilege escalation requires an interactive password, use the approved local invocation method rather than storing the password.

Do not proceed if syntax checking or Ansible connectivity fails.

---

## 8. Apply hardening

Run against VM101 only for the first deployment:

```bash
cd /home/james/projects/proxmox/ansible/linux-security-hardening

ansible-playbook \
  -i inventory.yml \
  playbook.yml \
  --limit app-platform-01 \
  --ask-become-pass
```

Omit `--ask-become-pass` only when privilege escalation is already configured securely.

Do not run the role against a wider inventory until VM101 passes all post-change checks.

---

## 9. Post-change validation

### 9.1 Fresh SSH access

From a separate trusted host:

```bash
ssh james@<VM101_IP> 'hostname && echo SSH_PASS'
```

A fresh SSH session is mandatory after changing SSH policy.

### 9.2 Effective SSH MAC policy

On the VM:

```bash
sudo /usr/sbin/sshd -T | grep '^macs '
```

The following must be absent:

```text
umac-64-etm@openssh.com
umac-64@openssh.com
```

Optionally validate remotely with:

```bash
nmap -Pn --script ssh2-enum-algos -p 22 <VM101_IP> \
  | sed -n '/mac_algorithms:/,/compression_algorithms:/p'
```

### 9.3 ICMP timestamp block

On the VM:

```bash
sudo /usr/sbin/iptables -C INPUT \
  -p icmp \
  --icmp-type timestamp-request \
  -j DROP

systemctl is-enabled homelab-icmp-timestamp-block.service
systemctl is-active homelab-icmp-timestamp-block.service
```

From a trusted scanner/admin host:

```bash
sudo nmap -sn -PP --send-ip --reason <VM101_IP>
```

The host must not report a timestamp reply.

Normal connectivity must still succeed:

```bash
ping -c 3 <VM101_IP>
ssh james@<VM101_IP> 'hostname && echo PASS'
```

---

## 10. Idempotence gate

Run the Ansible playbook a second time against VM101.

Expected result:

- no duplicate ICMP DROP rule;
- no unnecessary SSH configuration change;
- no failed tasks;
- connectivity remains healthy.

Confirm only one matching timestamp rule exists:

```bash
sudo /usr/sbin/iptables -S INPUT \
  | grep -- '--icmp-type 13'
```

---

## 11. Security scan closure

After local validation, re-run the relevant Greenbone checks against the VM.

The gate passes when:

- the weak UMAC-64 findings are absent;
- the Linux ICMP timestamp-request finding is absent;
- fresh SSH access still works;
- normal ping still works;
- the Ansible role is idempotent;
- any remaining TCP timestamp finding is documented as the existing accepted risk unless policy changes.

---

## 12. Rollback

### SSH hardening rollback

```bash
sudo rm -f /etc/ssh/sshd_config.d/90-homelab-macs.conf
sudo /usr/sbin/sshd -t
sudo systemctl reload ssh
```

### ICMP timestamp rollback

```bash
sudo systemctl disable --now homelab-icmp-timestamp-block.service
sudo rm -f /etc/systemd/system/homelab-icmp-timestamp-block.service
sudo systemctl daemon-reload
```

The service's stop action removes its matching ICMP timestamp DROP rule.

---

## 13. Acceptance criteria

Security hardening is complete when:

- [ ] VM guest commissioning has already passed.
- [ ] Ansible syntax check passes.
- [ ] Ansible can reach the VM.
- [ ] Hardening playbook completes successfully against only the intended VM.
- [ ] Fresh SSH login succeeds after the change.
- [ ] `umac-64-etm@openssh.com` is not offered.
- [ ] `umac-64@openssh.com` is not offered.
- [ ] ICMP timestamp requests receive no reply.
- [ ] Normal ping remains functional.
- [ ] `homelab-icmp-timestamp-block.service` is enabled and active.
- [ ] Second Ansible run is idempotent.
- [ ] Matching Greenbone findings are cleared or formally documented.

Only after this gate passes should the application build continue to PostgreSQL, TimescaleDB and Nginx.

## 14. Source implementation

The authoritative implementation remains:

```text
ansible/linux-security-hardening/README.md
ansible/linux-security-hardening/playbook.yml
ansible/linux-security-hardening/roles/linux-security-hardening/
```

This runbook defines where that validated role sits in the standard VM build lifecycle; it does not duplicate or broaden the role's implementation.