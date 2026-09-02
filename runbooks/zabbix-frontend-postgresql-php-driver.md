# Zabbix Frontend PostgreSQL PHP Driver Follow-up

## Status

OPEN — investigate/fix on 02 September 2026 evening follow-up.

The VM101 one-button end-to-end rebuild completed successfully for:

```text
VMID:     101
Hostname: zabbix-server-01
IP:       192.168.2.253
```

However, the Zabbix frontend at:

```text
http://192.168.2.253:8080/
```

reports:

```text
DB type "POSTGRESQL" is not supported by current setup. Possible values MYSQL.
```

## Interpretation

The infrastructure/service E2E result remains valid: OpenTofu, QGA, SSH trust, hardening, unattended-upgrades, Alloy, PostgreSQL, TimescaleDB, Nginx, Zabbix Server, idempotence and zero drift all passed.

This is a frontend PHP runtime dependency issue to resolve in IaC.

The likely missing dependency is the PostgreSQL PHP extension used by PHP-FPM (`pgsql` / `pdo_pgsql`). On Debian 13 with the current PHP 8.4 runtime, the expected package is `php8.4-pgsql`.

Do not install it manually as the final fix. Confirm the diagnosis, then add the dependency to the Ansible `zabbix_server` role.

## Diagnostic

```bash
ssh james@192.168.2.253 '
echo "===== PHP DATABASE MODULES ====="
php -m | grep -Ei "pgsql|mysqli|pdo"

echo
echo "===== POSTGRESQL PHP PACKAGE ====="
dpkg -l | grep -E "php.*pgsql" || true

echo
echo "===== PHP-FPM VERSION ====="
php-fpm8.4 -v 2>/dev/null || php -v
'
```

## Expected permanent fix

If PostgreSQL PHP support is absent:

1. add the required PHP PostgreSQL package to `ansible/roles/zabbix_server/defaults/main.yml` / managed package list;
2. ensure the role restarts/reloads the appropriate PHP-FPM service only when required;
3. rerun `ansible/playbooks/zabbix-server.yml`;
4. confirm PostgreSQL is supported in the frontend;
5. rerun the Zabbix playbook and require `changed=0`;
6. repeat the complete one-button clean rebuild when convenient to prove the dependency is recovered from code.

## Acceptance

- [ ] `pgsql` and/or `pdo_pgsql` is available to the PHP runtime as required by Zabbix.
- [ ] PostgreSQL is accepted by the Zabbix frontend.
- [ ] Nginx configuration remains valid.
- [ ] PHP-FPM remains active.
- [ ] Zabbix frontend loads successfully.
- [ ] Ansible second pass is `changed=0`.
- [ ] No manual package step is required after a rebuild.

Tracking issue: `jrwroberts1976/proxmox#12`.
