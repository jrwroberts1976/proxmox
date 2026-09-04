#!/usr/bin/env python3
import argparse
import json
import os
import secrets
import sys
import urllib.error
import urllib.request


class ZabbixApiError(RuntimeError):
    pass


class ZabbixApi:
    def __init__(self, url):
        self.url = url
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
                raise ZabbixApiError("authenticated call attempted before login")
            headers["Authorization"] = f"Bearer {self.auth}"

        req = urllib.request.Request(
            self.url,
            data=json.dumps(payload).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as response:
                body = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, json.JSONDecodeError) as exc:
            raise ZabbixApiError(f"{method} request failed: {exc}") from exc

        if "error" in body:
            error = body["error"]
            raise ZabbixApiError(
                f"{method} failed: {error.get('message', 'unknown error')} - "
                f"{error.get('data', '')}"
            )
        return body.get("result")

    def login(self, username, password):
        self.auth = self.call(
            "user.login",
            {"username": username, "password": password},
            authenticated=False,
        )

    def logout(self):
        if self.auth:
            try:
                self.call("user.logout", [])
            finally:
                self.auth = None


def one_or_none(items, label):
    if len(items) > 1:
        raise ZabbixApiError(f"expected at most one {label}, found {len(items)}")
    return items[0] if items else None


def int_value(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return value


def ensure_host_group(api, name):
    groups = api.call(
        "hostgroup.get",
        {"output": ["groupid", "name"], "filter": {"name": [name]}},
    )
    group = one_or_none(groups, f"host group {name!r}")
    if group:
        return group["groupid"], False

    result = api.call("hostgroup.create", {"name": name})
    return result["groupids"][0], True


def desired_role_rules():
    return {
        "api.access": 1,
        "api.mode": 1,
        "api": ["*.get", "apiinfo.version"],
        "actions.default_access": 0,
        "actions": [],
    }


def role_matches(role):
    if int_value(role.get("type")) != 1:
        return False
    rules = role.get("rules") or {}
    return (
        int_value(rules.get("api.access")) == 1
        and int_value(rules.get("api.mode")) == 1
        and set(rules.get("api") or []) == {"*.get", "apiinfo.version"}
        and int_value(rules.get("actions.default_access")) == 0
    )


def ensure_role(api, name):
    roles = api.call(
        "role.get",
        {
            "output": ["roleid", "name", "type"],
            "selectRules": "extend",
            "filter": {"name": [name]},
        },
    )
    role = one_or_none(roles, f"role {name!r}")

    if not role:
        result = api.call(
            "role.create",
            {"name": name, "type": 1, "rules": desired_role_rules()},
        )
        return result["roleids"][0], True

    if role_matches(role):
        return role["roleid"], False

    api.call(
        "role.update",
        {
            "roleid": role["roleid"],
            "type": 1,
            "rules": desired_role_rules(),
        },
    )
    return role["roleid"], True


def normalize_rights(rights):
    return sorted(
        (str(item["id"]), int_value(item["permission"]))
        for item in (rights or [])
    )


def ensure_user_group(api, name, group_ids):
    desired_rights = [
        {"id": str(group_id), "permission": 2}
        for group_id in group_ids
    ]
    groups = api.call(
        "usergroup.get",
        {
            "output": ["usrgrpid", "name", "gui_access", "users_status", "debug_mode"],
            "selectHostGroupRights": "extend",
            "filter": {"name": [name]},
        },
    )
    group = one_or_none(groups, f"user group {name!r}")
    desired_norm = normalize_rights(desired_rights)

    if not group:
        result = api.call(
            "usergroup.create",
            {
                "name": name,
                "gui_access": 3,
                "users_status": 0,
                "debug_mode": 0,
                "hostgroup_rights": desired_rights,
            },
        )
        return result["usrgrpids"][0], True

    matches = (
        int_value(group.get("gui_access")) == 3
        and int_value(group.get("users_status")) == 0
        and int_value(group.get("debug_mode")) == 0
        and normalize_rights(group.get("hostgroup_rights")) == desired_norm
    )
    if matches:
        return group["usrgrpid"], False

    api.call(
        "usergroup.update",
        {
            "usrgrpid": group["usrgrpid"],
            "gui_access": 3,
            "users_status": 0,
            "debug_mode": 0,
            "hostgroup_rights": desired_rights,
        },
    )
    return group["usrgrpid"], True


def ensure_user(api, username, role_id, user_group_id):
    users = api.call(
        "user.get",
        {
            "output": ["userid", "username", "roleid"],
            "selectUsrgrps": ["usrgrpid", "name"],
            "filter": {"username": [username]},
        },
    )
    user = one_or_none(users, f"user {username!r}")
    desired_group_ids = {str(user_group_id)}

    if not user:
        result = api.call(
            "user.create",
            {
                "username": username,
                "passwd": secrets.token_urlsafe(48),
                "roleid": str(role_id),
                "usrgrps": [{"usrgrpid": str(user_group_id)}],
            },
        )
        return result["userids"][0], True

    current_group_ids = {
        str(group["usrgrpid"]) for group in (user.get("usrgrps") or [])
    }
    if (
        str(user.get("roleid")) == str(role_id)
        and current_group_ids == desired_group_ids
    ):
        return user["userid"], False

    api.call(
        "user.update",
        {
            "userid": user["userid"],
            "roleid": str(role_id),
            "usrgrps": [{"usrgrpid": str(user_group_id)}],
        },
    )
    return user["userid"], True


def ensure_token(api, name, user_id, authority_present, token_output):
    tokens = api.call(
        "token.get",
        {
            "output": ["tokenid", "name", "userid", "status", "expires_at"],
            "userids": [str(user_id)],
        },
    )
    matches = [item for item in tokens if item.get("name") == name]
    token = one_or_none(matches, f"API token {name!r}")
    changed = False

    if not token:
        result = api.call(
            "token.create",
            {
                "name": name,
                "userid": str(user_id),
                "status": 0,
                "expires_at": 0,
            },
        )
        token_id = result["tokenids"][0]
        changed = True
    else:
        token_id = token["tokenid"]
        if int_value(token.get("status")) != 0 or int_value(token.get("expires_at")) != 0:
            api.call(
                "token.update",
                {"tokenid": token_id, "status": 0, "expires_at": 0},
            )
            changed = True

    generated = False
    if not authority_present:
        generated_items = api.call("token.generate", [str(token_id)])
        if len(generated_items) != 1 or not generated_items[0].get("token"):
            raise ZabbixApiError("token.generate did not return exactly one secret")
        with open(token_output, "w", encoding="utf-8") as fh:
            fh.write(generated_items[0]["token"] + "\n")
        os.chmod(token_output, 0o600)
        generated = True
        changed = True

    return changed, generated


def write_status(path, values):
    if not path:
        return
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        for key in sorted(values):
            fh.write(f"{key}={values[key]}\n")
    os.chmod(path, 0o600)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--api-url", required=True)
    parser.add_argument("--role-name", required=True)
    parser.add_argument("--user-group-name", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--token-name", required=True)
    parser.add_argument("--host-groups-json", required=True)
    parser.add_argument("--authority-present", choices=["yes", "no"], required=True)
    parser.add_argument("--token-output", required=True)
    parser.add_argument("--status-file")
    return parser.parse_args()


def main():
    args = parse_args()
    admin_username = os.environ.get("ZABBIX_API_USERNAME", "")
    admin_password = os.environ.get("ZABBIX_API_PASSWORD", "")
    if not admin_username or not admin_password:
        print("FAIL: Zabbix Admin API credentials are required", file=sys.stderr)
        return 1

    try:
        host_groups = json.loads(args.host_groups_json)
    except json.JSONDecodeError as exc:
        print(f"FAIL: invalid host-groups JSON: {exc}", file=sys.stderr)
        return 1
    if not isinstance(host_groups, list) or not host_groups:
        print("FAIL: at least one host group is required", file=sys.stderr)
        return 1

    api = ZabbixApi(args.api_url)
    changed = False
    try:
        api.login(admin_username, admin_password)

        group_ids = []
        for name in host_groups:
            group_id, item_changed = ensure_host_group(api, str(name))
            group_ids.append(group_id)
            changed = changed or item_changed

        role_id, item_changed = ensure_role(api, args.role_name)
        changed = changed or item_changed

        user_group_id, item_changed = ensure_user_group(
            api, args.user_group_name, group_ids
        )
        changed = changed or item_changed

        user_id, item_changed = ensure_user(
            api, args.username, role_id, user_group_id
        )
        changed = changed or item_changed

        item_changed, generated = ensure_token(
            api,
            args.token_name,
            user_id,
            args.authority_present == "yes",
            args.token_output,
        )
        changed = changed or item_changed

        write_status(
            args.status_file,
            {
                "authority_present": args.authority_present,
                "host_groups": len(group_ids),
                "result": "PASS",
                "role": "PRESENT",
                "token": "PRESENT",
                "token_generated": "YES" if generated else "NO",
                "user": "PRESENT",
                "user_group": "PRESENT",
            },
        )

        print("PASS: Zabbix Grafana API authority converged")
        return 2 if changed else 0
    except ZabbixApiError as exc:
        write_status(args.status_file, {"result": "FAIL", "reason": str(exc)})
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        try:
            api.logout()
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(main())
