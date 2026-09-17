#!/usr/bin/env bash
# Resource capabilities: how AMConnect decides which buttons to show for a resource.
#
# Two sources of truth, combined per resource by ckanext-amconnect (services.py):
#   CKAN metadata           format (WMS/WFS/WCS/GeoJSON/...), url (endpoint), layer_name, dataset origin
#   live GetCapabilities    does the layer exist, is it queryable, which output formats, CORS header, bbox
# => capabilities {view, identify, query, download_vector, download_raster, area_statistics, feature_query,
#    export_map_image, federated} and a concrete "downloads" list.  Nothing is offered that the
#    service did not advertise, so no dead "Download" buttons.
source "$(dirname "$0")/_lib.sh"

say "1. Which CKAN resources are inspected (dataset thailand-geological-map)"
curl -s "$CKAN_URL/api/3/action/package_show?id=thailand-geological-map" | pp '[.result.resources[] | {id, name, format, url, layer_name}]'

say "2. How available services are discovered: the probe = one GetCapabilities per endpoint (cached 5 min), parsed with OWSLib"
show "curl '$GEOSERVER_URL/amconnect/wfs?service=WFS&version=2.0.0&request=GetCapabilities' | grep -o '<ows:Value>[^<]*</ows:Value>' | sort -u   (outputFormat values)"
curl -s "$GEOSERVER_URL/amconnect/wfs?service=WFS&version=2.0.0&request=GetCapabilities" | grep -o '<ows:Value>[^<]*</ows:Value>' | sed 's/<[^>]*>//g' | sort -u | grep -iE "json|csv|shape|gml|kml" | tr '\n' ' '; echo
show "curl '$GEOSERVER_URL/amconnect/wcs?service=WCS&version=2.0.1&request=GetCapabilities' | grep -o '<wcs:formatSupported>[^<]*'"
curl -s "$GEOSERVER_URL/amconnect/wcs?service=WCS&version=2.0.1&request=GetCapabilities" | grep -o '<wcs:formatSupported>[^<]*' | sed 's/<[^>]*>//g' | tr '\n' ' '; echo

say "3. The combined answer per resource"
for ds in thailand-geological-map thailand-population-density-2020 malaysia-mineral-occurrences-mock; do
  show "curl $CKAN_URL/api/amconnect/datasets/$ds/services  (resources)"
  curl -s "$CKAN_URL/api/amconnect/datasets/$ds/services" | pp '[.result.resources[] | {name, service_type, origin, status, capabilities: [.capabilities | to_entries[] | select(.value) | .key], downloads: [.downloads[] | .label]}]'
done

say "4. Why this matters for the future frontend"
note "The frontend renders buttons from 'capabilities' + 'downloads' and never builds OGC URLs itself. A GeoNode-backed layer,"
note "a partner GeoServer or a WMS-only SDI all come through the same JSON shape; only the flags differ."
