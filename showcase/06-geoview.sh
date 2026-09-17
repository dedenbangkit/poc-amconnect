#!/usr/bin/env bash
# ckanext-geoview as a reference implementation: what it needs, what it detects.
#
# geo_view (OpenLayers 2-era "ol_preview") and geojson_view (Leaflet) are enabled.  They are
# NOT attached automatically (ckan.views.default_views keeps our own view); this script adds a
# geo_view to each OGC resource so both viewers can be compared side by side on the resource page.
# Convention geoview needs: the WMS/WFS layer name goes in the URL *fragment*: .../wms#amconnect:thailand_geology
source "$(dirname "$0")/_lib.sh"

TOKEN="${CKAN_TOKEN:-$(ckan_cli user token add admin showcase 2>/dev/null | tail -1 | tr -d '[:space:]')}"
api() { curl -s -H "Authorization: $TOKEN" -H "Content-Type: application/json" "$CKAN_URL/api/3/action/$1" -d "$2"; }

say "1. Formats geoview offers itself for (config ckanext.geoview.ol_viewer.formats), and the proxy requirement"
note "GEOVIEW_FORMATS = kml geojson gml wms wfs esrigeojson gft arcgis_rest wmts 'esri rest'; can_view() also needs resource_proxy enabled OR the URL on the CKAN domain"
curl -s "$CKAN_URL/api/3/action/status_show" | jget '.result.extensions'

say "2. Create geo_view views on the seeded service resources (idempotent)"
for ds in thailand-geological-map thailand-population-density-2020; do
  curl -s "$CKAN_URL/api/3/action/package_show?id=$ds" | python3 -c '
import json,sys
for r in json.load(sys.stdin)["result"]["resources"]:
    if r["format"].lower() in ("wms","wfs"): print(r["id"], r["format"], r.get("layer_name",""), r["url"])' | while read -r rid fmt layer url; do
    existing=$(curl -s "$CKAN_URL/api/3/action/resource_view_list?id=$rid" | jget '[.result[] | select(.view_type=="geo_view")] | length')
    if [ "$existing" = "0" ]; then
      # geoview reads the layer from the URL fragment; we set it on the *view* only through a resource patch of the URL? No:
      # geoview has no layer field, so the resource URL itself must carry "#layer".  Patch the URL (our code ignores fragments).
      api resource_patch "{\"id\":\"$rid\",\"url\":\"${url%%#*}#$layer\"}" >/dev/null
      api resource_view_create "{\"resource_id\":\"$rid\",\"view_type\":\"geo_view\",\"title\":\"geoview (reference)\"}" | jget '.success'
    else
      echo "geo_view exists on $rid ($fmt)"
    fi
  done
done

say "3. Open a resource page: both views are listed (AMConnect GIS view, geoview)"
curl -s "$CKAN_URL/api/3/action/package_show?id=thailand-geological-map" | python3 -c '
import json,sys; d=json.load(sys.stdin)["result"]
for r in d["resources"]: print("'"$CKAN_URL"'/dataset/%s/resource/%s   (%s)" % (d["name"], r["id"], r["format"]))'

say "4. What geoview does with a WMS resource (from ckanext/geoview/public/js/ol_preview.js + ol-helpers.js)"
note "- reads GetCapabilities through CKAN's resource_proxy (/dataset/<id>/resource/<rid>/proxy) => no CORS needed for capabilities"
note "- adds ALL layers of the service unless the URL fragment names one; zooms to the layer bbox from capabilities"
note "- GetMap tiles go straight to the server (no proxy); GetFeatureInfo: only via the proxy, only for same-domain/proxy servers"
note "- no legend, no opacity/ordering UI beyond a layer switcher, no download links, no WCS at all, no analysis"
