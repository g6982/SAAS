#!/usr/bin/env bash
# Prepare and start the Odoo SaaS Kit stack. Safe to re-run: existing secrets,
# client data and the master database are kept.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd .. && pwd)"
ODOO_UID=101   # uid/gid of the odoo user in the official odoo image
ODOO_GID=101

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

rand() { python3 -c 'import secrets; print(secrets.token_hex(16))'; }

set_env() { # set_env KEY VALUE : fill KEY in .env only when it is empty
    local key="$1" value="$2"
    if grep -qE "^${key}=.+" .env; then return; fi
    if grep -qE "^${key}=" .env; then
        sed -i "s|^${key}=.*|${key}=${value}|" .env
    else
        printf '%s=%s\n' "$key" "$value" >> .env
    fi
}

# --- 1. .env ---------------------------------------------------------------
[ -f .env ] || cp .env.example .env
for key in MASTER_ADMIN_PASSWD DB_PASSWORD SAAS_TEMPLATE_MASTER SAAS_CONTAINER_MASTER SAAS_CONTAINER_PASSWD; do
    set_env "$key" "$(rand)"
done
set_env DOCKER_GID "$(stat -c %g /var/run/docker.sock)"
chmod 600 .env
set -a; . ./.env; set +a

# --- 2. host directories ----------------------------------------------------
DATA_DIR="${SAAS_ROOT}/Odoo-SAAS-Data"
COMMON_ADDONS="${SAAS_ROOT}/common-addons_v17"
$SUDO mkdir -p "$DATA_DIR/docker_vhosts" "$COMMON_ADDONS" "${SAAS_ROOT}/master/data"

# conf templates the kit copies for the template/client containers
$SUDO cp "$REPO_ROOT"/Odoo-SAAS-Data/*.conf "$DATA_DIR/"
$SUDO cp "$REPO_ROOT"/Odoo-SAAS-Data/docker_vhosts/*.txt "$DATA_DIR/docker_vhosts/"
$SUDO cp "$REPO_ROOT"/SAAS-addons/odoo_saas_kit/models/lib/vhosts/*.txt "$DATA_DIR/docker_vhosts/"
if [ "$SAAS_HTTP_PORT" != "80" ]; then
    $SUDO sed -i "s/listen 80;/listen ${SAAS_HTTP_PORT};/" "$DATA_DIR"/docker_vhosts/*.txt
fi
# module installed in every client; the kit refers to it as wk_saas_tool
$SUDO rm -rf "$COMMON_ADDONS/wk_saas_tool"
$SUDO cp -r "$REPO_ROOT/common-addons_V17/saas_tool" "$COMMON_ADDONS/wk_saas_tool"

# --- 3. generated configuration ----------------------------------------------
# saas.conf: the repo copy with this deployment's paths and secrets
$SUDO env SAAS_ROOT="$SAAS_ROOT" \
    SAAS_TEMPLATE_MASTER="$SAAS_TEMPLATE_MASTER" SAAS_CONTAINER_MASTER="$SAAS_CONTAINER_MASTER" \
    SAAS_CONTAINER_USER="$SAAS_CONTAINER_USER" SAAS_CONTAINER_PASSWD="$SAAS_CONTAINER_PASSWD" \
    python3 - "$REPO_ROOT/SAAS-addons/odoo_saas_kit/models/lib/saas.conf" "${SAAS_ROOT}/saas.conf" <<'PY'
import os, re, sys
src, dst = sys.argv[1:3]
root = os.environ["SAAS_ROOT"].rstrip("/")
values = {
    "template_master": os.environ["SAAS_TEMPLATE_MASTER"],
    "container_master": os.environ["SAAS_CONTAINER_MASTER"],
    "container_user": os.environ["SAAS_CONTAINER_USER"],
    "container_passwd": os.environ["SAAS_CONTAINER_PASSWD"],
    "nginx_vhosts": root + "/Odoo-SAAS-Data/docker_vhosts/",
    "odoo_saas_data": root + "/Odoo-SAAS-Data/",
}
out = []
for line in open(src):
    m = re.match(r"\s*([A-Za-z0-9_]+)\s*=", line)
    key = m.group(1) if m else None
    if key in values:
        line = "%s = %s\n" % (key, values[key])
    elif key and key.startswith("common_addons_v"):
        line = "%s = %s/common-addons_v%s\n" % (key, root, key[len("common_addons_v"):])
    out.append(line)
open(dst, "w").writelines(out)
PY

$SUDO tee "${SAAS_ROOT}/master/odoo.conf" >/dev/null <<CONF
[options]
addons_path = /usr/lib/python3/dist-packages/odoo/addons,/mnt/extra-addons
data_dir = /var/lib/odoo
admin_passwd = ${MASTER_ADMIN_PASSWD}
db_host = ${DB_HOST}
db_port = ${DB_PORT}
db_user = ${DB_USER}
db_password = ${DB_PASSWORD}
db_name = ${MASTER_DB}
dbfilter = ^${MASTER_DB}\$
list_db = False
proxy_mode = True
http_port = ${MASTER_HTTP_PORT}
gevent_port = ${MASTER_GEVENT_PORT}
workers = ${MASTER_WORKERS}
max_cron_threads = 1
; creating a template database installs modules inside one request
limit_time_cpu = 1800
limit_time_real = 3600
CONF

$SUDO chown -R "${ODOO_UID}:${ODOO_GID}" "$SAAS_ROOT"
$SUDO chmod 640 "${SAAS_ROOT}/saas.conf" "${SAAS_ROOT}/master/odoo.conf"

# --- 4. images ----------------------------------------------------------------
docker build -t odoobywebkul:17.0 ./client
docker compose build master

# --- 5. start, then create the master database on first run --------------------
docker compose up -d db
until docker compose exec -T db pg_isready -U "$DB_USER" -d postgres >/dev/null 2>&1; do sleep 2; done

kit_state() {
    docker compose exec -T db psql -U "$DB_USER" -d "$MASTER_DB" -tAc \
        "SELECT state FROM ir_module_module WHERE name='odoo_saas_kit'" 2>/dev/null || true
}
if [ "$(kit_state)" != "installed" ]; then
    echo "Initialising master database ${MASTER_DB} with odoo_saas_kit (takes a few minutes)..."
    docker compose run --rm --no-deps master \
        odoo -c /etc/odoo/odoo.conf -d "$MASTER_DB" -i odoo_saas_kit \
        --without-demo=all --stop-after-init --workers=0 --no-http
    if [ "$(kit_state)" != "installed" ]; then
        echo "odoo_saas_kit failed to install, see the log above." >&2
        exit 1
    fi
fi

docker compose up -d

PORT_SUFFIX=""
[ "$SAAS_HTTP_PORT" = "80" ] || PORT_SUFFIX=":${SAAS_HTTP_PORT}"
cat <<MSG

SaaS master is starting: http://${SAAS_DOMAIN}${PORT_SUFFIX}  (login admin / admin, change it now)

SaaS server record values (SaaS Kit > Configuration > SaaS Servers):
  Host Server / Database Host Server : Self
  Server Domain                      : ${SAAS_DOMAIN}
  Database Host / Port               : ${DB_HOST} / ${DB_PORT}
  Database Username                  : ${DB_USER}
  Database Password                  : DB_PASSWORD in docker/.env
MSG
