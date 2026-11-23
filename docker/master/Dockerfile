# SaaS master: Odoo 17 running odoo_saas_kit. It drives the host Docker daemon
# through the mounted socket to create the template and client containers.
ARG ODOO_BASE=odoo:17.0
FROM ${ODOO_BASE}

USER root
RUN pip3 install --no-cache-dir \
        "docker>=7.1,<8" \
        "ERPpeek==1.7.1" \
        "paramiko>=3.4,<4" \
        "python-crontab>=3,<4"

# The kit shells out to `sudo nginx -t` / `sudo nginx -s reload`; nginx lives in
# its own container, so both commands are forwarded there.
COPY bin/sudo bin/nginx /usr/local/bin/
RUN chmod 755 /usr/local/bin/sudo /usr/local/bin/nginx

USER odoo
