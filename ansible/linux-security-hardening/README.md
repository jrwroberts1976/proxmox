# Linux Security Hardening Runbook

This Ansible runbook codifies the Linux security changes validated on 31 August 2026 following Greenbone findings against the homelab.

## Scope

Validated targets:

- `PROXMOX` — `192.168.2.70` — Debian-based Proxmox VE host
- `debian-iac-test-01` — `192.168.2.120` — Debian VM on Proxmox

The role applies two controls that were manually tested before automation:

1. Remove the two weak 64-bit UMAC algorithms reported by Greenbone.
2. Block IPv4 ICMP timestamp requests while leaving normal ICMP echo and SSH working.

The role is intentionally narrow. It does not enable the Proxmox firewall globally and it does not replace the host's general firewall policy.

## Findings remediated

### Weak SSH MAC algorithms

Greenbone reported:

- `umac-64-etm@openssh.com`
- `umac-64@openssh.com`

The validated OpenSSH drop-in is:

```text
MACs -umac-64-etm@openssh.com,umac-64@openssh.com
```

The role writes this to:

```text
/etc/ssh/sshd_config.d/90-homelab-macs.conf
```

Before SSH is reloaded, the role runs:

```bash
/usr/sbin/sshd -t
```

After the reload it checks the effective configuration with `sshd -T` and fails if either weak UMAC-64 algorithm is still present.

### ICMP timestamp replies

Both Linux systems replied to IPv4 ICMP timestamp requests (type 13). A temporary iptables rule was tested first:

```bash
iptables -I INPUT 1 -p icmp --icmp-type timestamp-request -j DROP
```

Validation confirmed:

- normal ping continued to work;
- a fresh SSH connection continued to work;
- `nmap -sn -PP --send-ip --reason <host>` no longer received a timestamp reply.

The role persists the rule through the dedicated systemd unit:

```text
homelab-icmp-timestamp-block.service
```

The service is idempotent: it checks for the rule before adding it and removes only its own matching rule when stopped.

## Accepted / excluded findings

### TCP timestamps

TCP timestamps remain enabled on the Linux systems:

```text
net.ipv4.tcp_timestamps = 1
```

This low-severity finding was deliberately not remediated. Disabling TCP timestamps solely to silence the scanner was not considered proportionate for trusted-LAN systems.

### Garage-door camera

`192.168.2.49` was identified as the TP-Link `garage-door-camera`. Its TCP/ICMP timestamp behaviour is vendor-controlled and is not managed by this Ansible role.

## Requirements

Target hosts must provide:

- Debian-family userspace;
- OpenSSH server with `/usr/sbin/sshd`;
- iptables at `/usr/sbin/iptables`;
- systemd;
- privilege escalation or root access.

The role was validated with OpenSSH 10.0p2 Debian and with both `iptables-nft` and `iptables-legacy` backends.

## Inventory

Copy the example inventory:

```bash
cp inventory.example.yml inventory.yml
```

Configure SSH authentication for each host. Do not store passwords or private keys in this repository.

Example targets are already represented in `inventory.example.yml`:

```yaml
linux_security_hardening:
  hosts:
    debian-iac-test-01:
      ansible_host: 192.168.2.120
      ansible_user: james
      ansible_become: true

    PROXMOX:
      ansible_host: 192.168.2.70
      ansible_user: root
      ansible_become: false
```

## Pre-change checks

Before running against a new host, confirm its current SSH MAC policy and firewall state:

```bash
sudo /usr/sbin/sshd -T | grep '^macs '
sudo /usr/sbin/iptables -S INPUT
```

Keep an existing administrative SSH session open during the first run against a new host.

## Run

From this directory:

```bash
ansible-playbook -i inventory.yml playbook.yml
```

If the non-root target requires an interactive sudo password:

```bash
ansible-playbook -i inventory.yml playbook.yml --ask-become-pass
```

Use `--limit` for the first deployment to an individual host:

```bash
ansible-playbook -i inventory.yml playbook.yml --limit debian-iac-test-01 --ask-become-pass
```

After that host passes validation, run against the remaining intended hosts.

## Manual post-change validation

From a separate trusted host:

### SSH algorithms

```bash
nmap -Pn --script ssh2-enum-algos -p 22 <target> \
  | sed -n '/mac_algorithms:/,/compression_algorithms:/p'
```

Neither of these should be offered:

```text
umac-64-etm@openssh.com
umac-64@openssh.com
```

### Normal connectivity

```bash
ping -c 3 <target>
ssh <target> 'hostname && echo PASS'
```

### ICMP timestamp probe

```bash
sudo nmap -sn -PP --send-ip --reason <target>
```

A remediated host should not report:

```text
received timestamp-reply
```

## Idempotence check

Run the playbook a second time. The expected result is no configuration change and no duplicate iptables rule.

```bash
ansible-playbook -i inventory.yml playbook.yml
```

Confirm only one timestamp DROP rule exists:

```bash
sudo /usr/sbin/iptables -S INPUT \
  | grep -- '--icmp-type 13'
```

## Rollback

### SSH MAC hardening

Remove the managed drop-in, validate SSH, then reload the service:

```bash
sudo rm -f /etc/ssh/sshd_config.d/90-homelab-macs.conf
sudo /usr/sbin/sshd -t
sudo systemctl reload ssh
```

### ICMP timestamp block

Disable and remove the dedicated unit:

```bash
sudo systemctl disable --now homelab-icmp-timestamp-block.service
sudo rm -f /etc/systemd/system/homelab-icmp-timestamp-block.service
sudo systemctl daemon-reload
```

The service's `ExecStop` removes the matching timestamp-request DROP rule.

## Security verification / closure

After deployment:

1. Verify fresh SSH access to each target.
2. Re-run `ssh2-enum-algos` and confirm the UMAC-64 algorithms are absent.
3. Re-run the forced ICMP timestamp probe and confirm no timestamp reply is returned.
4. Re-run the matching Greenbone scan/OIDs.
5. Document TCP timestamp findings as accepted risk where appropriate.
6. Document the TP-Link camera timestamp findings as vendor-controlled accepted risk.

The runbook is complete when the validated controls are idempotently applied, connectivity remains healthy, and the Greenbone re-scan no longer reports the remediated SSH and Linux ICMP findings.
