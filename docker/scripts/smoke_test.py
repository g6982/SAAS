#!/usr/bin/env python3
"""End-to-end check of the SaaS Kit stack.

Creates (or reuses) a SaaS server, a plan with its template database, a
contract and a client instance, then checks the client answers through nginx.
Reads docker/.env; run it on the Docker host after ./setup.sh.

    python3 scripts/smoke_test.py [--login admin --password ... --subdomain demo1]
"""
import argparse
import json
import os
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


def load_env(path):
    env = {}
    for line in open(path):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            env[key] = value
    return env


class Odoo:
    def __init__(self, url, db, login, password):
        self.url, self.db, self.password = url, db, password
        self.uid = self._rpc("common", "login", db, login, password)
        if not self.uid:
            sys.exit("Login failed for %s on %s" % (login, db))

    def _rpc(self, service, method, *args):
        payload = {"jsonrpc": "2.0", "method": "call", "id": 1,
                   "params": {"service": service, "method": method, "args": args}}
        req = urllib.request.Request(self.url + "/jsonrpc", json.dumps(payload).encode(),
                                     {"Content-Type": "application/json"})
        reply = json.load(urllib.request.urlopen(req, timeout=3600))
        if reply.get("error"):
            data = reply["error"].get("data", {})
            raise RuntimeError(data.get("message") or reply["error"].get("message"))
        return reply.get("result")

    def call(self, model, method, *args, **kwargs):
        return self._rpc("object", "execute_kw", self.db, self.uid, self.password,
                         model, method, list(args), kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--login", default="admin")
    parser.add_argument("--password", help="default: ADMIN_INITIAL_PASSWORD from .env")
    parser.add_argument("--subdomain", default="demo1")
    args = parser.parse_args()

    env = load_env(os.path.join(HERE, "..", ".env"))
    args.password = args.password or env.get("ADMIN_INITIAL_PASSWORD") or "admin"
    domain = env["SAAS_DOMAIN"]
    odoo = Odoo("http://127.0.0.1:%s" % env["MASTER_HTTP_PORT"], env["MASTER_DB"],
                args.login, args.password)

    # 1. SaaS server
    servers = odoo.call("saas.server", "search", [("server_domain", "=", domain)])
    if servers:
        server_id = servers[0]
    else:
        server_id = odoo.call("saas.server", "create", {
            "name": "Local Docker host", "host_server": "self", "db_server": "self",
            "server_domain": domain, "db_host": env["DB_HOST"], "db_port": env["DB_PORT"],
            "db_user": env["DB_USER"], "db_pass": env["DB_PASSWORD"], "max_clients": 10,
        })
    state = odoo.call("saas.server", "read", [server_id], ["state"])[0]["state"]
    if state == "draft":
        odoo.call("saas.server", "test_db_connection", [server_id])
    if state != "confirm":
        odoo.call("saas.server", "set_confirm", [server_id])
    print("server   :", odoo.call("saas.server", "read", [server_id], ["name", "state"])[0])

    # 2. Plan + template database (starts the template container on first use)
    plans = odoo.call("saas.plan", "search", [("name", "=", "Smoke Test Plan")])
    plan_id = plans[0] if plans else odoo.call("saas.plan", "create", {
        "name": "Smoke Test Plan", "server_id": server_id, "saas_base_url": domain,
        "recurring_interval": 1})
    if odoo.call("saas.plan", "read", [plan_id], ["state"])[0]["state"] != "confirm":
        print("creating template database, this takes a few minutes...")
        odoo.call("saas.plan", "create_db_template", [plan_id])
    plan = odoo.call("saas.plan", "read", [plan_id], ["state", "db_template", "container_id"])[0]
    print("plan     :", plan)

    # 3. Contract + client instance
    contracts = odoo.call("saas.contract", "search", [("domain_name", "=", args.subdomain)])
    if contracts:
        contract_id = contracts[0]
    else:
        partner_id = odoo.call("res.partner", "create", {
            "name": "Smoke Test Customer", "email": "smoke@example.com"})
        contract_id = odoo.call("saas.contract", "create", {
            "partner_id": partner_id, "plan_id": plan_id, "server_id": server_id,
            "db_template": plan["db_template"], "domain_name": args.subdomain,
            "recurring_interval": 1, "recurring_rule_type": "monthly",
            "total_cycles": 1, "remaining_cycles": 1, "saas_users": 1,
            "start_date": time.strftime("%Y-%m-%d"), "from_backend": True,
        })
    contract = odoo.call("saas.contract", "read", [contract_id], ["state", "saas_client"])[0]
    if not contract["saas_client"] or contract["state"] not in ("open", "confirm"):
        print("creating client instance...")
        odoo.call("saas.contract", "create_saas_client", [contract_id])
        contract = odoo.call("saas.contract", "read", [contract_id], ["state", "saas_client"])[0]
    print("contract :", contract)
    client = odoo.call("saas.client", "read", [contract["saas_client"][0]],
                       ["client_url", "database_name", "container_name", "containter_port", "state"])[0]
    print("client   :", client)

    # 4. The client must answer through nginx on its own host name
    host = "%s.%s" % (args.subdomain, domain)
    req = urllib.request.Request("http://127.0.0.1:%s/web/login" % env["SAAS_HTTP_PORT"],
                                 headers={"Host": host})
    with urllib.request.urlopen(req, timeout=120) as resp:
        body = resp.read().decode(errors="replace")
        ok = resp.status == 200 and "oe_login_form" in body
    print("nginx    : http://%s/web/login -> %s" % (host, "OK" if ok else "unexpected response"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
