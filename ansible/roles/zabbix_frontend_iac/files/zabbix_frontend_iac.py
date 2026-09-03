#!/usr/bin/env python3
import argparse
import copy
import json
import os
import sys
import urllib.error
import urllib.request


class ZabbixApiError(RuntimeError):
    pass


class ZabbixApi:
    def __init__(self, url, username, password):
        self.url = url
        self.username = username
        self.password = password
        self.auth = None
        self.request_id = 0

    def call(self, method, params, authenticated=True):
        self.request_id += 1
        payload = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": self.request_id,
        }
        headers = {"Content-Type": "application/json-rpc"}
        if authenticated:
            if not self.auth:
                raise ZabbixApiError("authenticated API call attempted before login")
            headers["Authorization"] = f"Bearer {self.auth}"

        request = urllib.request.Request(
            self.url,
            data=json.dumps(payload).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                body = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, json.JSONDecodeError) as exc:
            raise ZabbixApiError(f"API request failed for {method}: {exc}") from exc

        if "error" in body:
            error = body["error"]
            raise ZabbixApiError(
                f"{method} failed: {error.get('message', 'unknown error')} - "
                f"{error.get('data', '')}"
            )
        return body.get("result")

    def login(self):
        self.auth = self.call(
            "user.login",
            {"username": self.username, "password": self.password},
            authenticated=False,
        )

    def logout(self):
        if self.auth:
            try:
                self.call("user.logout", [], authenticated=True)
            finally:
                self.auth = None


def desired_default_view(args):
    return f"{args.latitude},{args.longitude},{args.zoom}"


def ensure_host_inventory(api, args):
    hosts = api.call(
        "host.get",
        {
            "output": ["hostid", "host", "inventory_mode"],
            "selectInventory": ["location", "location_lat", "location_lon"],
            "filter": {"host": [args.host_name]},
        },
    )
    if len(hosts) != 1:
        raise ZabbixApiError(
            f"expected exactly one host named {args.host_name!r}, found {len(hosts)}"
        )

    host = hosts[0]
    inventory = host.get("inventory") or {}
    desired = {
        "location": args.location,
        "location_lat": args.latitude,
        "location_lon": args.longitude,
    }
    current = {key: str(inventory.get(key, "")) for key in desired}

    if str(host.get("inventory_mode")) == "0" and current == desired:
        return False

    api.call(
        "host.update",
        {
            "hostid": host["hostid"],
            "inventory_mode": 0,
            "inventory": desired,
        },
    )

    verify = api.call(
        "host.get",
        {
            "output": ["hostid", "host", "inventory_mode"],
            "selectInventory": ["location", "location_lat", "location_lon"],
            "hostids": [host["hostid"]],
        },
    )
    if len(verify) != 1:
        raise ZabbixApiError("host inventory verification lookup failed")
    verified_inventory = verify[0].get("inventory") or {}
    verified = {key: str(verified_inventory.get(key, "")) for key in desired}
    if str(verify[0].get("inventory_mode")) != "0" or verified != desired:
        raise ZabbixApiError("host inventory verification failed")
    return True


def widget_payload(widget, fields=None):
    payload = {
        "widgetid": widget["widgetid"],
        "type": widget["type"],
        "name": widget.get("name", ""),
        "x": int(widget.get("x", 0)),
        "y": int(widget.get("y", 0)),
        "width": int(widget.get("width", 1)),
        "height": int(widget.get("height", 1)),
        "view_mode": int(widget.get("view_mode", 0)),
        "fields": copy.deepcopy(widget.get("fields", [])) if fields is None else fields,
    }
    return payload


def ensure_geomap_default_view(api, args):
    dashboards = api.call(
        "dashboard.get",
        {
            "output": ["dashboardid", "name"],
            "selectPages": "extend",
            "editable": True,
            "filter": {"name": [args.dashboard_name]},
        },
    )
    if len(dashboards) != 1:
        raise ZabbixApiError(
            f"expected exactly one editable dashboard named {args.dashboard_name!r}, "
            f"found {len(dashboards)}"
        )

    dashboard = dashboards[0]
    geomaps = []
    for page in dashboard.get("pages", []):
        for widget in page.get("widgets", []):
            if widget.get("type") == "geomap":
                geomaps.append((page, widget))

    if len(geomaps) != 1:
        raise ZabbixApiError(
            f"expected exactly one Geomap widget on dashboard {args.dashboard_name!r}, "
            f"found {len(geomaps)}"
        )

    target_page, target_widget = geomaps[0]
    target_view = desired_default_view(args)
    current_view = None
    for field in target_widget.get("fields", []):
        if field.get("name") == "default_view":
            current_view = str(field.get("value", ""))
            break

    if current_view == target_view:
        return False

    new_fields = copy.deepcopy(target_widget.get("fields", []))
    for field in new_fields:
        if field.get("name") == "default_view":
            field["type"] = 1
            field["value"] = target_view
            break
    else:
        new_fields.append({"type": 1, "name": "default_view", "value": target_view})

    pages_payload = []
    for page in dashboard.get("pages", []):
        page_payload = {"dashboard_pageid": page["dashboard_pageid"]}
        if page["dashboard_pageid"] == target_page["dashboard_pageid"]:
            widgets = []
            for widget in page.get("widgets", []):
                if widget["widgetid"] == target_widget["widgetid"]:
                    widgets.append(widget_payload(widget, new_fields))
                else:
                    widgets.append(widget_payload(widget))
            page_payload["widgets"] = widgets
        pages_payload.append(page_payload)

    api.call(
        "dashboard.update",
        {"dashboardid": dashboard["dashboardid"], "pages": pages_payload},
    )

    verify = api.call(
        "dashboard.get",
        {
            "output": ["dashboardid", "name"],
            "selectPages": "extend",
            "dashboardids": [dashboard["dashboardid"]],
        },
    )
    verified_view = None
    for page in verify[0].get("pages", []):
        for widget in page.get("widgets", []):
            if widget.get("widgetid") == target_widget["widgetid"]:
                for field in widget.get("fields", []):
                    if field.get("name") == "default_view":
                        verified_view = str(field.get("value", ""))
                        break
    if verified_view != target_view:
        raise ZabbixApiError("Geomap default_view verification failed")
    return True


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--api-url", required=True)
    parser.add_argument("--dashboard-name", required=True)
    parser.add_argument("--host-name", required=True)
    parser.add_argument("--location", required=True)
    parser.add_argument("--latitude", required=True)
    parser.add_argument("--longitude", required=True)
    parser.add_argument("--zoom", required=True, type=int)
    return parser.parse_args()


def main():
    args = parse_args()
    username = os.environ.get("ZABBIX_API_USERNAME", "")
    password = os.environ.get("ZABBIX_API_PASSWORD", "")
    if not username or not password:
        print("Zabbix API credentials are required", file=sys.stderr)
        return 1

    api = ZabbixApi(args.api_url, username, password)
    changed = False
    try:
        api.login()
        changed |= ensure_host_inventory(api, args)
        changed |= ensure_geomap_default_view(api, args)
    except ZabbixApiError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        try:
            api.logout()
        except Exception as exc:
            print(f"FAIL: user.logout failed: {exc}", file=sys.stderr)
            return 1

    print(
        "PASS: Zabbix frontend IaC "
        f"location={args.location} view={desired_default_view(args)} changed={str(changed).lower()}"
    )
    return 2 if changed else 0


if __name__ == "__main__":
    sys.exit(main())
