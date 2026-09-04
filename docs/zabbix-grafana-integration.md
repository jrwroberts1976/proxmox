# Zabbix ↔ Grafana integration

## Status

**Validated 4 September 2026.**

The Zabbix service identity, API token authority, Grafana Zabbix plugin and Grafana datasource path are working end to end.

This document covers the Grafana-to-Zabbix integration only. It does **not** mean the Proxmox host has yet been onboarded into Zabbix with the Proxmox VE template; that remains separate backlog work.

## Architecture

```text
CT201 zabbix-lxc-01
192.168.2.184:8080
        |
        | Zabbix API
        |
        v
ids-01 Grafana 13.2.0
alexanderzobnin-zabbix-app 6.6.0
        |
        +--> provisioned Zabbix datasource
        +--> Prometheus datasource
        +--> Loki datasource
```

The dedicated Zabbix API identity is managed from the Proxmox repository through Ansible. The encrypted API-token authority and ids-01 Grafana runtime definitions are managed in `jrwroberts1976/docker-env`.

## Zabbix identity

Ansible role:

```text
ansible/roles/zabbix_grafana_iac
```

Playbook:

```text
ansible/playbooks/zabbix-grafana-iac.yml
```

Managed objects:

```text
role:       Grafana API Read Only
user group: Grafana Read Only
user:       grafana-zabbix
token:      grafana-datasource
host groups:
  - Zabbix servers
  - Linux servers
  - Infrastructure/Proxmox
```

The API role uses an allow-list containing authenticated read methods only:

```text
*.get
```

`apiinfo.version` is intentionally not part of the authenticated role allow-list.

The Zabbix user group uses normal system authentication mode rather than frontend-disabled mode because the Grafana-Zabbix plugin requires normal frontend/API visibility for host and group discovery. The service user's generated password is not retained as an operator credential.

## Secret authority

The generated token is not committed in plaintext.

Authority flow:

```text
Zabbix token.generate
        |
        v
short-lived controller staging file
        |
        v
SOPS encryption on TestServer
        |
        v
docker-env/secrets/ids-01/grafana-zabbix.sops.env
        |
        v
protected ids-01 runtime secret
        |
        v
Docker Compose secret
        |
        v
Grafana secureJsonData.apiToken
```

The encrypted file is readable by the approved age recipients on TestServer and ids-01.

The token is generated only when encrypted authority is absent. Re-running the Zabbix Ansible role with existing authority does not rotate the token.

## Validation evidence

Initial API pre-flight:

```text
zabbix_api=PASS
zabbix_version=7.0.30
vault_decrypt=PASS
sops_config=PASS
```

SOPS/token proof:

```text
token_api=PASS
proxmox_group_visibility=PASS
plaintext_staging=PASS_ABSENT
```

Zabbix convergence after plugin-compatibility correction:

```text
result=PASS
role=PRESENT
user_group=PRESENT
user=PRESENT
token=PRESENT
token_generated=NO
```

Grafana startup proof:

```text
Grafana version=13.2.0
alexanderzobnin-zabbix-app=6.6.0
datasource uid=zabbix
grafana_health=PASS
```

Final end-to-end proof from inside the Grafana container:

```text
grafana_to_zabbix=PASS
proxmox_group_visibility=PASS
```

This proves Grafana can use the mounted service token to query Zabbix and read the `Infrastructure/Proxmox` host group.

## Known runtime ownership detail

Grafana runs as container UID `472`.

The first ids-01 runtime materialisation created the host token file as the local user with mode `0600`. Docker Compose secret bind-mount semantics preserved permissions, so Grafana could not read it and entered a restart loop.

The working runtime state is:

```text
/home/james/docker/secrets/zabbix-grafana-api-token
owner UID: 472
mode:      0400
```

The ids-01 deployment helper must preserve this ownership/mode requirement on future materialisation. Until that helper is corrected, validate ownership before any Grafana recreation.

## Scope boundary

Completed:

- dedicated read-only Zabbix API service identity;
- SOPS-encrypted token authority;
- Grafana Zabbix plugin installation/provisioning;
- Grafana Zabbix datasource provisioning;
- end-to-end API proof.

Still backlog:

- onboard the Proxmox VE host itself into Zabbix using the selected Proxmox integration/template;
- add Proxmox-specific Zabbix items/triggers only where they add value beyond Prometheus;
- any optional dashboard/alert enhancements.

Prometheus/Loki/Alloy remain authoritative for the existing metrics/logging paths. Zabbix complements rather than replaces them.
