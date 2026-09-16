"""WMS provider helpers.

This module is the only place that knows how a CKAN resource maps onto a WMS
GetMap request.  Both the local GeoServer and arbitrary external WMS servers
go through the same code path: a resource is "WMS" when its format is WMS (or
its URL obviously is a WMS endpoint) and the layer name is stored in the
``wms_layer`` resource field (falling back to ``LAYERS=`` in the URL).

A later GeoNode phase would still expose layers over WMS, so no changes here
would be required; GeoNode would simply be another WMS base URL.
"""
from urllib.parse import parse_qs, urlsplit, urlunsplit


def is_wms_resource(resource):
    fmt = (resource.get("format") or "").strip().lower()
    if fmt == "wms":
        return True
    url = (resource.get("url") or "").lower()
    return "service=wms" in url


def wms_base_url(url):
    """Strip WMS query parameters that OpenLayers will set itself."""
    parts = urlsplit(url or "")
    keep = []
    for key, values in parse_qs(parts.query, keep_blank_values=True).items():
        if key.lower() in ("service", "request", "version", "layers", "styles",
                           "format", "bbox", "width", "height", "srs", "crs",
                           "transparent"):
            continue
        for v in values:
            keep.append(f"{key}={v}")
    return urlunsplit((parts.scheme, parts.netloc, parts.path, "&".join(keep), ""))


def layer_for(resource, override=None):
    if override:
        return override
    if resource.get("wms_layer"):
        return resource["wms_layer"]
    qs = parse_qs(urlsplit(resource.get("url") or "").query)
    for key, values in qs.items():
        if key.lower() == "layers" and values:
            return values[0]
    return ""
