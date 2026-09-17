#!/usr/bin/env bash
# ckanext-spatial, part 2: spatial discovery.
#
# Backend: ckanext.spatial.search_backend = solr-spatial-field (Solr image ckan-solr:2.11-solr9-spatial).
# The geometry is indexed as WKT in Solr field spatial_geom (JTS RPT); a search with ext_bbox
# becomes  fq = {!field f=spatial_geom}Intersects(ENVELOPE(minx, maxx, maxy, miny)).
# Only bbox queries are exposed (ext_bbox); the intersection test itself is against the real polygon.
source "$(dirname "$0")/_lib.sh"

q() { curl -s "$CKAN_URL/api/3/action/package_search?rows=10&$1" | jget '[.result.count, [.result.results[].name]]'; }

say "1. Standard CKAN API: package_search with ext_bbox=minx,miny,maxx,maxy (WGS84)"
show "greater Bangkok  ext_bbox=100.3,13.5,100.9,14.0";   q "ext_bbox=100.3,13.5,100.9,14.0"
show "Malaysia only    ext_bbox=101,2,103,4";             q "ext_bbox=101,2,103,4"
show "Atlantic ocean   ext_bbox=-40,-10,-30,0 (only the world-wide mock record matches)"; q "ext_bbox=-40,-10,-30,0"
show "combined with text + facets:  q=geology&ext_bbox=97,5,106,21&fq=country:Thailand"
q "q=geology&ext_bbox=97,5,106,21&fq=country:Thailand"

say "2. The AMConnect facade: /api/amconnect/spatial-search?bbox=... (same query, simpler JSON, facets included)"
show "curl '$CKAN_URL/api/amconnect/spatial-search?bbox=100.3,13.5,100.9,14.0'"
curl -s "$CKAN_URL/api/amconnect/spatial-search?bbox=100.3,13.5,100.9,14.0" | pp '{count, results: [.result[] | {name, origin, bbox, service_types}], facets: (.facets | keys)}'

say "3. Filter hosted vs federated (derived from harvest_source_id in the index)"
show "curl '$CKAN_URL/api/amconnect/spatial-search?bbox=90,-10,130,25&origin=federated'"
curl -s "$CKAN_URL/api/amconnect/spatial-search?bbox=90,-10,130,25&origin=federated" | pp '[.result[] | {name, origin, organization: .organization.title}]'

say "4. What the UI adds (secondary): dataset extent map in the sidebar and a draw-a-box filter on /dataset"
note "$CKAN_URL/dataset/thailand-geological-map  (sidebar map)   $CKAN_URL/dataset?ext_bbox=100,13,101,14"
