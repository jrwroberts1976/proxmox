# TimescaleDB Installation Runbook

## 1. Purpose

This runbook defines the controlled installation and validation procedure for TimescaleDB on the PostgreSQL VM.

The existing Ansible implementation is:

```text
ansible/playbooks/timescaledb.yml
ansible/roles/timescaledb/
```

The repository currently targets TimescaleDB on PostgreSQL 17 and Debian 13.

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

TimescaleDB inherits the already accepted security and observability baseline; it must not regress either one.

---

## 2. Preconditions

The PostgreSQL installation runbook must already have passed, and the VM's prior observability gate must remain healthy.

Required:

- PostgreSQL is active and healthy;
- `pg_isready` succeeds;
- the intended PostgreSQL major version is known;
- target databases are declared in Ansible;
- Ansible can connect to the host;
- no unexpected failed services exist;
- Alloy remains enabled/active/healthy;
- host metrics remain visible in authoritative Prometheus on `ids-01`;
- journal logs remain visible in authoritative Loki on `ids-01`.

Verify:

```bash
cd ansible
ansible timescaledb_servers -m ping
ansible <DB_HOST> -m shell -a 'pg_isready -h 127.0.0.1 -p 5432'
ansible <DB_HOST> -b -m shell -a 'systemctl is-active alloy && curl -fsS http://127.0.0.1:12345/-/healthy && systemctl --failed --no-legend'
```

Stop if the VM baseline has regressed.

---

## 3. Current role behaviour

Current defaults include:

```yaml
postgresql_version: 17
timescaledb_package: "timescaledb-2-postgresql-{{ postgresql_version }}"
timescaledb_databases: []
timescaledb_run_tune: false
```

The role:

1. verifies Debian 13 or newer;
2. installs repository prerequisites;
3. configures the TimescaleDB PackageCloud repository;
4. installs the matching TimescaleDB package for the selected PostgreSQL major version;
5. writes `shared_preload_libraries = 'timescaledb'`;
6. restarts PostgreSQL when required;
7. optionally runs `timescaledb-tune` only when explicitly enabled;
8. creates the TimescaleDB extension in selected databases.

`timescaledb-tune` is intentionally disabled by default because tuning must reflect actual VM CPU/RAM rather than applying assumptions.

---

## 4. Inventory

The same VM may belong to multiple groups:

```yaml
all:
  children:
    postgresql_servers:
      hosts:
        db-01:
          ansible_host: <DB_IP>
    timescaledb_servers:
      hosts:
        db-01:
```

It should also remain under the Alloy management model established during the observability gate.

Validate:

```bash
cd ansible
ansible-inventory --graph
ansible timescaledb_servers -m ping
```

---

## 5. Variables

Declare which database or databases require TimescaleDB.

Example:

```yaml
postgresql_version: 17

timescaledb_databases:
  - homelab

timescaledb_run_tune: false
```

The database must already exist before the extension task runs.

Do not enable TimescaleDB automatically in every PostgreSQL database.

---

# Stage 0 - Compatibility gate

## 6. Confirm PostgreSQL/TimescaleDB package compatibility

Before first deployment or any major-version change, confirm the TimescaleDB repository publishes a package for:

```text
Debian 13
<selected PostgreSQL major version>
amd64
```

The package name used by the role is:

```text
timescaledb-2-postgresql-<major>
```

Stop if the package does not exist for the selected PostgreSQL major release.

Do not upgrade PostgreSQL major version independently of TimescaleDB compatibility.

---

# Stage 1 - Static validation

## 7. Syntax check

```bash
cd ansible
ansible-playbook playbooks/timescaledb.yml --syntax-check
```

## 8. Check mode

```bash
ansible-playbook playbooks/timescaledb.yml \
  --check --diff \
  --limit <DB_HOST>
```

Review the proposed repository, package, and PostgreSQL configuration changes.

Package/repository actions can have check-mode limitations; use check mode as a preview rather than proof of runtime package availability.

---

# Stage 2 - Install TimescaleDB

## 9. Apply the playbook

```bash
cd ansible
ansible-playbook playbooks/timescaledb.yml \
  --limit <DB_HOST>
```

A PostgreSQL restart is expected if the preload configuration is newly created or changed.

---

# Stage 3 - Package validation

## 10. Confirm installed package

On the database VM:

```bash
dpkg -l | grep -E 'timescaledb|postgresql-17'
apt-cache policy timescaledb-2-postgresql-17
```

Adjust the PostgreSQL major number only if the repository baseline deliberately changes.

---

# Stage 4 - Preload validation

## 11. Confirm configuration file

```bash
cat /etc/postgresql/17/main/conf.d/98-timescaledb.conf
```

Expected:

```text
shared_preload_libraries = 'timescaledb'
```

## 12. Confirm PostgreSQL loaded the library

```bash
sudo -u postgres psql -Atqc 'SHOW shared_preload_libraries;'
```

Expected output contains:

```text
timescaledb
```

## 13. Confirm PostgreSQL remains healthy

```bash
systemctl is-active postgresql
pg_isready -h 127.0.0.1 -p 5432
```

Both must succeed.

---

# Stage 5 - Extension validation

## 14. Confirm extension exists

For each declared TimescaleDB database:

```bash
sudo -u postgres psql -d <DATABASE> -c '\dx timescaledb'
```

Or:

```bash
sudo -u postgres psql -d <DATABASE> -Atqc "SELECT extversion FROM pg_extension WHERE extname='timescaledb';"
```

Expected: one installed TimescaleDB extension version.

---

# Stage 6 - Functional hypertable test

## 15. Create a disposable test table

Run this only in a lab/test database:

```bash
sudo -u postgres psql -d <DATABASE> <<'SQL'
CREATE TABLE IF NOT EXISTS runbook_metrics (
    ts timestamptz NOT NULL,
    host text NOT NULL,
    value double precision NOT NULL
);

SELECT create_hypertable('runbook_metrics', by_range('ts'), if_not_exists => TRUE);

INSERT INTO runbook_metrics(ts, host, value)
VALUES (now(), 'runbook-test', 1.0);

SELECT * FROM runbook_metrics ORDER BY ts DESC LIMIT 5;
SQL
```

Confirm the table is a hypertable:

```bash
sudo -u postgres psql -d <DATABASE> -c "SELECT hypertable_schema, hypertable_name FROM timescaledb_information.hypertables WHERE hypertable_name='runbook_metrics';"
```

After validation, remove the disposable test table:

```bash
sudo -u postgres psql -d <DATABASE> -c 'DROP TABLE runbook_metrics;'
```

---

# Stage 7 - Tuning decision

## 16. Do not enable automatic tuning yet

Current initial VM sizing is deliberately modest while the Proxmox host remains memory constrained.

Keep:

```yaml
timescaledb_run_tune: false
```

until:

- the final VM RAM allocation is agreed;
- host RAM has been reviewed/upgraded as necessary;
- PostgreSQL workload characteristics are known;
- generated settings can be reviewed before acceptance.

When tuning is eventually enabled, capture the before/after PostgreSQL settings and rerun workload validation.

---

# Stage 8 - Idempotence

## 17. Run the playbook a second time

```bash
ansible-playbook playbooks/timescaledb.yml \
  --limit <DB_HOST>
```

Expected: no unnecessary package/configuration changes and no repeated PostgreSQL restart.

Investigate repeated changes before continuing.

---

# Stage 9 - Observability regression check

TimescaleDB installation can restart PostgreSQL, so re-check both database health and the pre-existing host telemetry afterward.

```bash
systemctl is-active postgresql
pg_isready -h 127.0.0.1 -p 5432
systemctl is-active alloy
curl -fsS http://127.0.0.1:12345/-/healthy
systemctl --failed --no-legend
```

Centrally confirm:

```promql
node_uname_info{hostname="<HOSTNAME>"}
```

Generate a unique journal marker if required to prove Loki flow after the PostgreSQL restart/change window.

TimescaleDB/PostgreSQL application metrics can be added later through a dedicated exporter/integration, but host metrics/logging must remain continuously healthy.

---

# Stage 10 - Upgrade discipline

## 18. Patch/minor updates

Before updating TimescaleDB:

1. review TimescaleDB release notes;
2. confirm support for the installed PostgreSQL major version;
3. take/verify the required backup;
4. apply to a disposable/test environment first;
5. run extension upgrade if required;
6. validate hypertables and application queries;
7. confirm Alloy and central telemetry remain healthy.

Check installed and available versions:

```bash
apt-cache policy timescaledb-2-postgresql-17
sudo -u postgres psql -d <DATABASE> -Atqc "SELECT extversion FROM pg_extension WHERE extname='timescaledb';"
```

Do not blindly run database extension upgrades across important databases.

---

# Stage 11 - Rollback

## 19. Configuration failure

If PostgreSQL fails after the preload change:

```bash
journalctl -u postgresql -n 100 --no-pager
pg_lsclusters
```

Then revert the Git/Ansible change and rerun the playbook or restore the previous known-good configuration.

## 20. Package/extension rollback

Do not remove the TimescaleDB package from a database that contains TimescaleDB-managed objects without a specific migration/recovery plan.

For the first disposable proof, destroying/rebuilding the entire VM through IaC is preferred to attempting an in-place destructive rollback.

After recovery, re-check Alloy and central telemetry.

---

## 21. Acceptance criteria

TimescaleDB installation is complete when:

- [ ] VM security/observability baseline was already accepted.
- [ ] PostgreSQL runbook has passed.
- [ ] Matching TimescaleDB package is available for Debian/PostgreSQL versions in use.
- [ ] Ansible syntax check passes.
- [ ] Playbook applies successfully.
- [ ] PostgreSQL remains active after installation.
- [ ] `shared_preload_libraries` contains `timescaledb`.
- [ ] TimescaleDB extension exists in every declared database.
- [ ] Disposable hypertable create/insert/query test passes.
- [ ] Test table is removed afterward.
- [ ] `timescaledb-tune` remains disabled unless deliberately approved.
- [ ] Second Ansible run is idempotent.
- [ ] Alloy remains healthy and host metrics/logs remain visible after installation.

Then proceed to `runbooks/nginx-install.md`.
