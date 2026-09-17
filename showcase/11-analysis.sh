#!/usr/bin/env bash
# Selected-area analysis: what the browser does, using only what CKAN told it.
#
#   frontend -> CKAN API (which services, which capabilities)
#            -> GeoServer WCS (raster clip) / WFS (features in bbox) directly
#            -> statistics computed client-side (geotiff.js / OpenLayers)
# CKAN never touches pixels or features.  Below: the same requests with curl.
source "$(dirname "$0")/_lib.sh"
BBOX="100.3,13.5,100.9,14.0"   # greater Bangkok, WGS84 minx,miny,maxx,maxy

say "1. Ask CKAN which layer supports area_statistics and where its WCS/WFS is"
curl -s "$CKAN_URL/api/amconnect/datasets/thailand-population-density-2020/services" | pp '.result.layers[] | select(.capabilities.area_statistics) | {layer_name, data_kind, wcs: .services.wcs.endpoint}'

say "2. Raster: WCS GetCoverage clipped to the box (what the Analysis tab downloads before reducing it with geotiff.js)"
URL="$GEOSERVER_URL/amconnect/wcs?service=WCS&version=2.0.1&request=GetCoverage&coverageId=amconnect__tha_pd_2020_1km_UNadj&subset=Long(100.3,100.9)&subset=Lat(13.5,14.0)&format=image/tiff"
show "curl '$URL' -o bangkok_clip.tif"
curl -s "$URL" -o /tmp/amconnect_bangkok_clip.tif; file /tmp/amconnect_bangkok_clip.tif 2>/dev/null || ls -la /tmp/amconnect_bangkok_clip.tif
if command -v gdalinfo >/dev/null; then gdalinfo -stats /tmp/amconnect_bangkok_clip.tif | grep -E "Size is|STATISTICS_(MEAN|MAXIMUM|MINIMUM)"; fi

say "2b. Polygon selection: the Analysis tab masks the clipped pixels client-side; vectors use a CQL INTERSECTS filter in EPSG:3857"
URL="$GEOSERVER_URL/amconnect/wfs?service=WFS&version=2.0.0&request=GetFeature&typeNames=amconnect:thailand_geology&outputFormat=application/json"
show "curl -G '$URL' --data-urlencode \"CQL_FILTER=INTERSECTS(geom, SRID=3857;POLYGON((11166000 1518000, 11233000 1518000, 11233000 1575000, 11166000 1575000, 11166000 1518000)))\""
curl -s -G "$URL" --data-urlencode "CQL_FILTER=INTERSECTS(geom, SRID=3857;POLYGON((11166000 1518000, 11233000 1518000, 11233000 1575000, 11166000 1575000, 11166000 1518000)))" | jget '[.numberReturned, [.features[].properties.unit_name]]'
note "the geometry attribute name (geom) comes from DescribeFeatureType&outputFormat=application/json, also used by the query builder"

say "2c. Attribute query (Query features panel): CQL_FILTER on any attribute, results highlighted and downloadable"
show "curl -G '$URL' --data-urlencode \"CQL_FILTER=rock_class = 'Sedimentary'\" | jq .totalFeatures"
curl -s -G "$URL" --data-urlencode "CQL_FILTER=rock_class = 'Sedimentary'" | jget '.totalFeatures'

say "3. Vector: WFS GetFeature with bbox (what the Analysis tab does for the geology layer)"
URL="$GEOSERVER_URL/amconnect/wfs?service=WFS&version=2.0.0&request=GetFeature&typeNames=amconnect:thailand_geology&bbox=13.5,100.3,14.0,100.9,EPSG:4326&outputFormat=application/json"
show "curl '$URL' | jq '{features: (.features|length), rock_class: [.features[].properties.rock_class] | group_by(.) | map({(.[0]): length}) | add}'"
curl -s "$URL" | pp '{features: (.features|length), rock_class: ([.features[].properties.rock_class] | group_by(.) | map({(.[0]): length}) | add)}'

say "4. Where this stops being a browser job (=> future analysis service, see README 'Advanced analysis architecture')"
note "- zonal statistics over polygons (not boxes), multi-layer overlays, anything > a few million pixels"
note "- federated services without CORS / without WCS-WFS (view-only): nothing to compute against"
note "- results that must be stored, shared or audited; GeoServer WPS or a small Python service would sit next to GeoServer"
note "The deep link '$CKAN_URL/dataset/thailand-population-density-2020/map/embed?tab=analysis&bbox=$BBOX' reproduces the UI run."
