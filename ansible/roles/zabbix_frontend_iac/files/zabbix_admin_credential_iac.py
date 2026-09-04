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

    def login(self, username, password):
        self.auth = self.call(
            "user.login",
            {"username": username, "password": password},
            authenticated=False,
        )

    def logout(self):
        if self.auth:
            try:
                self.call("user.logout", [], authenticated=True)
            finally:
                self.auth = None


def verify_login(url, username, password):
    api = ZabbixApi(url)
    try:
        api.login(username, password)
    finally:
        try:
            api.logout()
        except Exception:
            pass


def rotate_password(url, username, current_password, desired_password):
    api = ZabbixApi(url)
    try:
        api.login(username, current_password)
        users = api.call(
            "user.get",
            {
                "output": ["userid", "username"],
                "filter": {"username": [username]},
            },
        )
        if len(users) != 1:
            raise ZabbixApiError(
                f"expected exactly one user named {username!r}, found {len(users)}"
            )
        api.call(
            "user.update",
            {
                "userid": users[0]["userid"],
                "passwd": desired_password,
                "current_passwd": current_password,
            },
        )
    finally:
        try:
            api.logout()
        except Exception:
            pass

    verify_login(url, username, desired_password)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--api-url", required=True)
    parser.add_argument("--username", default="Admin")
    parser.add_argument("--mode", choices=["rotate", "verify"], required=True)
    return parser.parse_args()


def main():
    args = parse_args()
    desired = os.environ.get("ZABBIX_DESIRED_PASSWORD", "")
    recovery = os.environ.get("ZABBIX_RECOVERY_PASSWORD", "")

    if not desired:
        print("FAIL: desired Zabbix password is required", file=sys.stderr)
        return 1

    try:
        if args.mode == "verify":
            verify_login(args.api_url, args.username, desired)
            print("PASS: Zabbix Admin Vault credential verified")
            return 0

        if not recovery:
            print("FAIL: recovery password is required for rotation", file=sys.stderr)
            return 1

        rotate_password(
            args.api_url,
            args.username,
            recovery,
            desired,
        )
        print("PASS: Zabbix Admin credential rotated and verified")
        return 2
    except ZabbixApiError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
