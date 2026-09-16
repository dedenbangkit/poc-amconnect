from ckanext.amconnect import wms


def wms_layers_for_package(pkg_dict):
    """Return [{name, url, layer, resource_id}] for every WMS resource."""
    layers = []
    for res in pkg_dict.get("resources", []):
        if not wms.is_wms_resource(res):
            continue
        layers.append({
            "resource_id": res["id"],
            "name": res.get("name") or res["id"],
            "url": wms.wms_base_url(res.get("url")),
            "layer": wms.layer_for(res),
        })
    return layers
