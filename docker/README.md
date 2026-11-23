# Docker deployment (Odoo 17)

Runs the SaaS Kit master with Docker Compose on one Linux host. The master
then starts one Odoo container per template / client through the Docker socket.

| Container | Image | Role |
|---|---|---|
| `saas-db` | `postgres:15` | PostgreSQL for the master and every client database |
| `saas-master` | `odoo-saas-master:17.0` (built from `master/`) | Odoo 17 with `odoo_saas_kit` |
| `saas-nginx` | `nginx:1.27-alpine` | Reverse proxy for the master and client vhosts |
| `odoo17_template_cont`, `<client domain>` | `odoobywebkul:17.0` (built from `client/`) | Created by the SaaS Kit |

## Requirements

- Linux host with Docker Engine and the Compose plugin, run as a user that can use `sudo` and Docker.
- Free ports: 80, 8069, 8072, 5432 (on the Docker bridge address), 8817/8827 (template) and 8000+ (clients).
- DNS: `SAAS_DOMAIN` and `*.SAAS_DOMAIN` must resolve to the host. The default `saas.localhost` works in browsers on the host itself without any DNS setup.

## Install

```sh
cd docker
cp .env.example .env      # optional: edit SAAS_DOMAIN, ports, SAAS_ROOT
./setup.sh
```

`setup.sh` is safe to re-run. It:

1. fills empty passwords in `.env` with random values,
2. creates `SAAS_ROOT` (default `/opt/odoo17`) with the config templates, nginx vhost templates and `wk_saas_tool`,
3. writes `SAAS_ROOT/saas.conf` (bind-mounted over `odoo_saas_kit/models/lib/saas.conf`) and `SAAS_ROOT/master/odoo.conf`,
4. builds both images, initialises the `MASTER_DB` database with `odoo_saas_kit`, and starts the stack.

Open `http://SAAS_DOMAIN` and log in with `admin` / `admin`, then change the password.

## Create a client

1. **SaaS Kit > Configuration > SaaS Servers**: create a server with the values printed by `setup.sh`, test the connection and confirm it.
2. **SaaS Plans**: create a plan on that server and click *Create DB Template*.
3. **Contracts**: create a contract for the plan, set a domain name and click *Create Client*.

The client is then reachable at `http://<domain name>.SAAS_DOMAIN`.

`python3 scripts/smoke_test.py` performs the same steps over RPC and checks the client login page through nginx.

## Notes

- `saas-master` and `saas-nginx` use host networking, because the SaaS Kit reaches client containers on `localhost:<port>`.
- The SaaS Kit calls `sudo nginx -t` / `sudo nginx -s reload`; inside the master those are small wrappers (`master/bin`) that run the command in `saas-nginx`.
- `SAAS_ROOT` is mounted at the same path in the master, because the paths in `saas.conf` are used as bind mounts on the host.
- The master has access to the Docker socket, which is root-equivalent on the host. Do not expose port 8069 or the database manager publicly.
- Client vhosts are HTTP only. Put TLS in front of nginx or adapt `vhosttemplatehttps.txt` for production.
- Stop: `docker compose down`. Client containers are managed by the SaaS Kit and keep running.
