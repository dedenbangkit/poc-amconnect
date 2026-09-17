#!/usr/bin/env bash
# ckanext-spatial, part 1: how the spatial extent is stored and exposed.
#
# The extent is a plain GeoJSON geometry in the dataset extra "spatial" (this is the
# ckanext-spatial convention; the extension does NOT define the field itself, our
# IDatasetForm declares it).  For hosted layers `ckan amconnect seed` derives it from
# GeoServer's WMS GetCapabilities; harvested datasets bring their own.
source "$(dirname "$0")/_lib.sh"

say "1. The extent as stored in CKAN: dataset extra 'spatial' (GeoJSON Polygon), exposed as a root key by our schema"
show "curl $CKAN_URL/api/3/action/package_show?id=thailand-geological-map | jq .result.spatial"
curl -s "$CKAN_URL/api/3/action/package_show?id=thailand-geological-map" | jget '.result.spatial'

say "2. Where it came from: GeoServer's WMS GetCapabilities advertises the layer bbox (EX_GeographicBoundingBox)"
show "ckan amconnect extent amconnect:thailand_geology   (same OWSLib call the seed uses)"
ckan_cli amconnect extent amconnect:thailand_geology

say "3. The AMConnect API returns it parsed, plus a bbox and the per-layer extents from the live services"
show "curl $CKAN_URL/api/amconnect/datasets/thailand-population-density-2020 | jq '{spatial: .result.spatial.type, bbox: .result.bbox, layers: [.result.layers[] | {layer_name, extent}]}'"
curl -s "$CKAN_URL/api/amconnect/datasets/thailand-population-density-2020" | pp '{spatial: .result.spatial.type, bbox: .result.bbox, layers: [.result.layers[] | {layer_name, extent}]}'

say "4. Validation: ckanext-spatial rejects invalid GeoJSON at package_create/update (spatial_metadata plugin)"
note "Try it (needs an API token):  curl -H 'Authorization: \$TOKEN' -d '{\"id\":\"thailand-geological-map\",\"spatial\":\"{not json\"}' $CKAN_URL/api/3/action/package_patch"
note "-> {\"error\": {\"spatial\": [\"Error decoding JSON object: ...\"]}}"

say "5. Raster and vector alike: the field is dataset-level, independent of the service type"
for d in thailand-geological-map thailand-population-density-2020 malaysia-mineral-occurrences-mock; do
  printf '%-40s ' "$d"; curl -s "$CKAN_URL/api/amconnect/datasets/$d?probe=false" | jget '.result.bbox'
done
note "A MultiPolygon or any GeoJSON geometry is accepted; Solr indexes the real geometry (solr-spatial-field backend)."
