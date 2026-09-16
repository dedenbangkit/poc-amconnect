FROM ckan/ckan-base:2.11

# Install the POC extension (editable so bind-mounting it during development works)
USER root
COPY --chown=ckan:ckan-sys ckanext-amconnect ${SRC_DIR}/ckanext-amconnect
RUN pip install --no-cache-dir -e ${SRC_DIR}/ckanext-amconnect

# Bake the plugin list into ckan.ini.  The base image's prerun.py runs `ckan db init`
# *before* it applies CKAN__PLUGINS, so the default ini (which enables `datastore`)
# would otherwise try to reach a datastore DB we do not run.
RUN ckan config-tool ${CKAN_INI} "ckan.plugins = image_view text_view envvars amconnect amconnect_wms_view" && \
    ckan config-tool ${CKAN_INI} "ckan.views.default_views = image_view text_view amconnect_wms_view"

# Startup hooks run by start_ckan.sh after db init / sysadmin creation
COPY --chown=ckan:ckan-sys docker-entrypoint.d/ /docker-entrypoint.d/
USER ckan
