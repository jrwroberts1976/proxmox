# Containers

This directory contains Proxmox LXC container projects and their Infrastructure-as-Code definitions, configuration management, runbooks, and migration documentation.

## Structure

Each container workload should use its own subdirectory so that lifecycle, state, configuration, and documentation remain isolated from VM projects.

Planned first project:

- `zabbix-lxc/` — Debian 13 unprivileged LXC running PostgreSQL, TimescaleDB, Zabbix Server, Nginx/PHP, Zabbix Agent 2, Alloy, and unattended upgrades.

## Principles

- Proxmox LXC resources are provisioned with OpenTofu.
- Guest configuration is managed with Ansible.
- Containers are unprivileged unless a documented requirement proves otherwise.
- Each workload has an independent OpenTofu state/lifecycle.
- Persistent data is backed up before destructive changes.
- Monitoring and decommissioning are part of the managed lifecycle.
