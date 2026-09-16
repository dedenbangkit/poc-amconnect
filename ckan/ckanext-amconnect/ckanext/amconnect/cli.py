"""``ckan amconnect seed``: create one CKAN dataset per layer in the drop folder.

Mirrors geoserver/seed/seed.py: every ``<name>.geojson|gpkg|shp|tif`` in the
drop folder (mounted at ``ckanext.amconnect.data_dir``, default /amconnect-data)
is published by GeoServer as ``amconnect:<name>``.  This command creates or
updates the matching CKAN dataset, with metadata from the optional
``<name>.json`` sidecar:

    name                dataset slug (default: derived from <name>)
    title, notes        dataset title / description
    country, commodity, data_type, access_level   AMConnect fields
    tags                list of tag names
    resource_name, resource_description           the WMS resource of this layer
    extra_resources     list of {name, description, url, wms_layer} (external WMS)

Idempotent: re-running updates in place and keeps resource ids (matched by name).

Config:
    ckanext.amconnect.geoserver_wms_url  browser-reachable GeoServer WMS URL
    ckanext.amconnect.data_dir           drop folder inside the CKAN container
    ckanext.amconnect.owner_org          organisation slug (default amconnect)
"""
import glob
import json
import os
import re

import click

import ckan.plugins.toolkit as tk

DATA_EXT = (".geojson", ".gpkg", ".shp", ".tif", ".tiff")

ORG = {"name": "amconnect", "title": "AMConnect",
       "description": "Example organisation for the AMConnect POC"}


def _sysadmin_name():
    import ckan.model as model
    admin = model.Session.query(model.User).filter_by(sysadmin=True, state="active").first()
    if not admin:
        raise click.ClickException("No sysadmin user exists yet; create one first")
    return admin.name


def _upsert(action_get, action_create, action_update, new_context, data):
    """new_context is a callable: CKAN needs a fresh context dict per action call."""
    try:
        existing = tk.get_action(action_get)(new_context(), {"id": data["name"]})
    except tk.ObjectNotFound:
        existing = None
    if existing:
        data["id"] = existing["id"]
        # keep resource ids stable (matched by name) so their views survive
        by_name = {r["name"]: r["id"] for r in existing.get("resources", [])}
        for res in data.get("resources", []):
            if res["name"] in by_name:
                res["id"] = by_name[res["name"]]
        return tk.get_action(action_update)(new_context(), data), "updated"
    return tk.get_action(action_create)(new_context(), data), "created"


def _slug(text):
    return re.sub(r"[^a-z0-9-]+", "-", text.lower()).strip("-")[:100]


def _discover(data_dir):
    """Return [(layer_name, sidecar_dict)] for every data file in the folder."""
    found = {}
    for path in sorted(glob.glob(os.path.join(data_dir, "*"))):
        low = path.lower()
        ext = next((e for e in DATA_EXT if low.endswith(e)), None)
        if not ext:
            continue
        name = os.path.basename(path)[:-len(ext)]
        meta = {}
        side = os.path.join(data_dir, name + ".json")
        if os.path.exists(side):
            with open(side) as fh:
                meta = json.load(fh)
        found[name] = meta
    return list(found.items())


def _dataset_dict(layer, meta, wms_url, owner_org):
    # Resource order = map layer order (first at the bottom), so external
    # (often opaque, basemap-like) WMS resources go first, the local layer on top.
    resources = []
    for extra in meta.get("extra_resources", []):
        resources.append({
            "name": extra["name"], "description": extra.get("description", ""),
            "url": extra["url"], "format": "WMS", "wms_layer": extra.get("wms_layer", ""),
        })
    resources.append({
        "name": meta.get("resource_name", f"{layer} (local GeoServer WMS)"),
        "description": meta.get("resource_description",
                                f"Layer amconnect:{layer} published by the POC GeoServer."),
        "url": wms_url,
        "format": "WMS",
        "wms_layer": f"amconnect:{layer}",
    })
    return {
        "name": meta.get("name") or _slug(layer),
        "title": meta.get("title") or layer,
        "owner_org": owner_org,
        "notes": meta.get("notes", ""),
        "license_id": meta.get("license_id", "cc-by"),
        "country": meta.get("country", ""),
        "commodity": meta.get("commodity", ""),
        "data_type": meta.get("data_type", "geospatial"),
        "access_level": meta.get("access_level", "public-view"),
        "tags": [{"name": t} for t in meta.get("tags", [])],
        "resources": resources,
    }


def _ensure_views(pkg, ctx):
    """package_update does not add default views for pre-existing resources."""
    for res in pkg["resources"]:
        views = tk.get_action("resource_view_list")(ctx(), {"id": res["id"]})
        if any(v["view_type"] == "amconnect_wms_view" for v in views):
            continue
        tk.get_action("resource_view_create")(ctx(), {
            "resource_id": res["id"], "view_type": "amconnect_wms_view", "title": "Map preview"})
        click.echo(f"  added WMS view to resource '{res['name']}'")


@click.group(short_help="AMConnect POC commands")
def amconnect():
    pass


@amconnect.command()
@click.option("--data-dir", default=None, help="Drop folder (default from config)")
def seed(data_dir):
    """Create/update one CKAN dataset per layer in the drop folder."""
    config = tk.config
    wms_url = config.get("ckanext.amconnect.geoserver_wms_url",
                         "http://localhost:8080/geoserver/amconnect/wms")
    data_dir = data_dir or config.get("ckanext.amconnect.data_dir", "/amconnect-data")
    owner_org = config.get("ckanext.amconnect.owner_org", ORG["name"])

    sysadmin = _sysadmin_name()

    def ctx():
        return {"user": sysadmin, "ignore_auth": True}

    _, state = _upsert("organization_show", "organization_create",
                       "organization_update", ctx, dict(ORG))
    click.echo(f"organization {ORG['name']}: {state}")

    layers = _discover(data_dir)
    if not layers:
        click.echo(f"no data files found in {data_dir}; nothing to seed")
        return
    for layer, meta in layers:
        pkg, state = _upsert("package_show", "package_create", "package_update",
                             ctx, _dataset_dict(layer, meta, wms_url, owner_org))
        click.echo(f"dataset {pkg['name']}: {state} ({len(pkg['resources'])} resources, layer amconnect:{layer})")
        _ensure_views(pkg, ctx)
