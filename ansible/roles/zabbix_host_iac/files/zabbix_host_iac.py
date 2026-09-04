#!/usr/bin/env python3

import argparse
import json
import os
import sys
import urllib.error
import urllib.request


class ZabbixApiError(RuntimeError):
    pass


class ZabbixApi:
    def __init__(self, url, token):
        self.url = url
        self.token = token
        self.request_id = 0

    def call(self, method, params):
        self.request_id += 1

        payload = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": self.request_id,
        }

        request = urllib.request.Request(
            self.url,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Content-Type": "application/json-rpc",
                "Authorization": f"Bearer {self.token}",
            },
            method="POST",
        )

        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                body = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, json.JSONDecodeError) as exc:
            raise ZabbixApiError(
                f"API request failed for {method}: {exc}"
            ) from exc

        if "error" in body:
            error = body["error"]
            raise ZabbixApiError(
                f"{method} failed: "
                f"{error.get('message', 'unknown error')} "
                f"{error.get('data', '')}"
            )

        return body.get("result")


def resolve_group(api, name):
    groups = api.call(
        "hostgroup.get",
        {
            "output": ["groupid", "name"],
            "filter": {"name": [name]},
        },
    )

    if len(groups) != 1:
        raise ZabbixApiError(
            f"expected exactly one host group {name!r}, found {len(groups)}"
        )

    return groups[0]["groupid"]


def resolve_template(api, name):
    templates = api.call(
        "template.get",
        {
            "output": ["templateid", "host", "name"],
            "filter": {"name": [name]},
        },
    )

    if len(templates) != 1:
        raise ZabbixApiError(
            f"expected exactly one template {name!r}, "
            f"found {len(templates)}"
        )

    return templates[0]["templateid"]


def get_host(api, host_name):
    hosts = api.call(
        "host.get",
        {
            "output": ["hostid", "host", "name", "status"],
            "selectHostGroups": ["groupid", "name"],
            "selectParentTemplates": ["templateid", "name"],
            "selectInterfaces": [
                "interfaceid",
                "type",
                "main",
                "useip",
                "ip",
                "dns",
                "port",
            ],
            "filter": {"host": [host_name]},
        },
    )

    if len(hosts) > 1:
        raise ZabbixApiError(
            f"multiple hosts returned for {host_name!r}"
        )

    return hosts[0] if hosts else None


def ensure_interface(api, hostid, host, ip, port):
    interfaces = [
        interface
        for interface in host.get("interfaces", [])
        if str(interface.get("type")) == "1"
        and str(interface.get("main")) == "1"
    ]

    desired = {
        "useip": "1",
        "ip": ip,
        "dns": "",
        "port": str(port),
    }

    if not interfaces:
        api.call(
            "hostinterface.create",
            {
                "hostid": hostid,
                "type": 1,
                "main": 1,
                "useip": 1,
                "ip": ip,
                "dns": "",
                "port": str(port),
            },
        )
        return True

    if len(interfaces) != 1:
        raise ZabbixApiError(
            "expected exactly one main Zabbix agent interface"
        )

    current = interfaces[0]

    current_view = {
        "useip": str(current.get("useip", "")),
        "ip": str(current.get("ip", "")),
        "dns": str(current.get("dns", "")),
        "port": str(current.get("port", "")),
    }

    if current_view == desired:
        return False

    api.call(
        "hostinterface.update",
        {
            "interfaceid": current["interfaceid"],
            "main": 1,
            "type": 1,
            "useip": 1,
            "ip": ip,
            "dns": "",
            "port": str(port),
        },
    )

    return True


def ensure_host(api, desired):
    host_name = desired["host"]
    visible_name = desired.get("name", host_name)
    ip = desired["ip"]
    port = str(desired.get("port", "10050"))

    group_names = desired["groups"]
    template_names = desired["templates"]

    desired_groupids = [
        resolve_group(api, name)
        for name in group_names
    ]

    desired_templateids = [
        resolve_template(api, name)
        for name in template_names
    ]

    existing = get_host(api, host_name)

    if existing is None:
        result = api.call(
            "host.create",
            {
                "host": host_name,
                "name": visible_name,
                "status": 0,
                "groups": [
                    {"groupid": groupid}
                    for groupid in desired_groupids
                ],
                "templates": [
                    {"templateid": templateid}
                    for templateid in desired_templateids
                ],
                "interfaces": [
                    {
                        "type": 1,
                        "main": 1,
                        "useip": 1,
                        "ip": ip,
                        "dns": "",
                        "port": port,
                    }
                ],
            },
        )

        hostids = result.get("hostids", [])

        if len(hostids) != 1:
            raise ZabbixApiError(
                "host.create did not return exactly one hostid"
            )

        return True

    changed = False

    current_groupids = sorted(
        group["groupid"]
        for group in existing.get("hostgroups", [])
    )
    current_templateids = sorted(
        template["templateid"]
        for template in existing.get("parentTemplates", [])
    )

    desired_groupids_sorted = sorted(desired_groupids)
    desired_templateids_sorted = sorted(desired_templateids)

    host_update = {
        "hostid": existing["hostid"],
    }

    update_required = False

    if existing.get("name", "") != visible_name:
        host_update["name"] = visible_name
        update_required = True

    if str(existing.get("status")) != "0":
        host_update["status"] = 0
        update_required = True

    if current_groupids != desired_groupids_sorted:
        host_update["groups"] = [
            {"groupid": groupid}
            for groupid in desired_groupids
        ]
        update_required = True

    if current_templateids != desired_templateids_sorted:
        host_update["templates"] = [
            {"templateid": templateid}
            for templateid in desired_templateids
        ]
        update_required = True

    if update_required:
        api.call("host.update", host_update)
        changed = True

    changed |= ensure_interface(
        api,
        existing["hostid"],
        existing,
        ip,
        port,
    )

    return changed


def verify_host(api, desired):
    host = get_host(api, desired["host"])

    if host is None:
        raise ZabbixApiError(
            f"verification failed: host {desired['host']!r} missing"
        )

    if str(host.get("status")) != "0":
        raise ZabbixApiError(
            "verification failed: host is not enabled"
        )

    desired_groupids = sorted(
        resolve_group(api, name)
        for name in desired["groups"]
    )

    actual_groupids = sorted(
        group["groupid"]
        for group in host.get("hostgroups", [])
    )

    if actual_groupids != desired_groupids:
        raise ZabbixApiError(
            "verification failed: host groups differ"
        )

    desired_templateids = sorted(
        resolve_template(api, name)
        for name in desired["templates"]
    )

    actual_templateids = sorted(
        template["templateid"]
        for template in host.get("parentTemplates", [])
    )

    if actual_templateids != desired_templateids:
        raise ZabbixApiError(
            "verification failed: templates differ"
        )

    agent_interfaces = [
        interface
        for interface in host.get("interfaces", [])
        if str(interface.get("type")) == "1"
        and str(interface.get("main")) == "1"
    ]

    if len(agent_interfaces) != 1:
        raise ZabbixApiError(
            "verification failed: expected one main agent interface"
        )

    interface = agent_interfaces[0]

    if (
        str(interface.get("ip")) != desired["ip"]
        or str(interface.get("port"))
        != str(desired.get("port", "10050"))
        or str(interface.get("useip")) != "1"
    ):
        raise ZabbixApiError(
            "verification failed: agent interface differs"
        )

    return host["hostid"]


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--api-url", required=True)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--host-json", required=True)
    return parser.parse_args()


def main():
    args = parse_args()

    try:
        with open(args.token_file, "r", encoding="utf-8") as handle:
            token = handle.read().strip()
    except OSError as exc:
        print(
            f"FAIL: unable to read Zabbix token file: {exc}",
            file=sys.stderr,
        )
        return 1

    if not token:
        print(
            "FAIL: Zabbix token file is empty",
            file=sys.stderr,
        )
        return 1

    try:
        desired = json.loads(args.host_json)
    except json.JSONDecodeError as exc:
        print(
            f"FAIL: invalid host JSON: {exc}",
            file=sys.stderr,
        )
        return 1

    api = ZabbixApi(args.api_url, token)

    try:
        changed = ensure_host(api, desired)
        hostid = verify_host(api, desired)
    except ZabbixApiError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    print(
        "PASS: "
        f"host={desired['host']} "
        f"hostid={hostid} "
        f"changed={str(changed).lower()}"
    )

    return 2 if changed else 0


if __name__ == "__main__":
    sys.exit(main())
