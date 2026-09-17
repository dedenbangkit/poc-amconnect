#!/usr/bin/env bash
# CKAN as API hub, part 2: services + capabilities per dataset and per resource.
#
# /api/amconnect/datasets/<id>/services groups the CKAN resources of a dataset into *layers*
# (same layer name on the same host => one layer with several services: wms/wfs/wcs) and
# merges their capabilities.  Each capability is true only if CKAN metadata says the service
# exists AND the live GetCapabilities probe confirmed layer + feature (queryable, formats...).
source "$(dirname "$0")/_lib.sh"

say "1. Hosted vector dataset: one layer, WMS + WFS => view, identify, query, download_vector, area_statistics"
show "curl $CKAN_URL/api/amconnect/datasets/thailand-geological-map/services"
curl -s "$CKAN_URL/api/amconnect/datasets/thailand-geological-map/services" | pp '.result.layers[] | {layer_name, origin, data_kind, status, view_only, capabilities, downloads: [.downloads[] | .label], services: (.services | keys)}'

say "2. Hosted raster dataset: WMS + WCS => view, identify, download_raster, area_statistics"
curl -s "$CKAN_URL/api/amconnect/datasets/thailand-population-density-2020/services" | pp '.result.layers[] | {layer_name, data_kind, capabilities, downloads: [.downloads[] | {label: .label, url: .url}]}'

say "3. Federated WMS-only (harvested): view + identify only, federated=true, view_only=true, no download entries"
curl -s "$CKAN_URL/api/amconnect/datasets/malaysia-mineral-occurrences-mock/services" | pp '.result.layers[] | {layer_name, origin, data_kind, status, view_only, capabilities, downloads}'

say "4. Federated WMS+WFS whose server rejects server-side probes: status=unreachable, downloads withheld rather than guessed"
curl -s "$CKAN_URL/api/amconnect/datasets/world-countries-natural-earth/services" | pp '.result | {layers: [.layers[] | {layer_name, status, capabilities}], resources: [.resources[] | {format, status, status_detail}]}'

say "5. Single resource: /api/amconnect/resources/<id>"
RID=$(curl -s "$CKAN_URL/api/3/action/package_show?id=thailand-geological-map" | jget '[.result.resources[] | select(.format=="WFS")][0].id')
show "curl $CKAN_URL/api/amconnect/resources/$RID"
curl -s "$CKAN_URL/api/amconnect/resources/$RID" | pp '.result | {service_type, endpoint, layer_name, origin, status, formats, capabilities, downloads: [.downloads[] | .label]}'
