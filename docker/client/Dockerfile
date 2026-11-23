# Image used by the SaaS Kit for the template container and every client
# container (saas.conf: odoo_image_v17 = odoobywebkul:17.0).
ARG ODOO_BASE=odoo:17.0
FROM ${ODOO_BASE}

USER root
# The kit's conf files expect the Odoo source under /opt/odoo, the data dir at
# /opt/data-dir and the config at /etc/odoo/odoo-server.conf.
RUN mkdir -p /opt/odoo/addons /opt/data-dir /mnt/extra-addons /var/log/odoo \
    && ln -s /usr/lib/python3/dist-packages/odoo /opt/odoo/odoo \
    && chown -R odoo:odoo /opt/data-dir /mnt/extra-addons /var/log/odoo

USER odoo
EXPOSE 8069 8071
ENTRYPOINT []
CMD ["odoo", "-c", "/etc/odoo/odoo-server.conf"]
