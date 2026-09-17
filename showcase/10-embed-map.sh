#!/usr/bin/env bash
# The GIS view: inside CKAN and standalone (embeddable), driven only by the AMConnect API.
source "$(dirname "$0")/_lib.sh"

say "1. Routes"
cat <<TXT
  $CKAN_URL/dataset/thailand-geological-map/map                        CKAN page: Overview / Map / Resources / Analysis tabs
  $CKAN_URL/dataset/thailand-geological-map/map/embed                  bare page for <iframe>, same component
  $CKAN_URL/dataset/thailand-population-density-2020/map/embed?tab=analysis&bbox=100.3,13.5,100.9,14.0
                                                                       deep link: open Analysis with greater Bangkok selected
  $CKAN_URL/dataset/thailand-geological-map/map/embed?layers=<resource id>   only some layers
  $CKAN_URL/amconnect/map?datasets=thailand-geological-map,thailand-population-density-2020
                                                                       several datasets on one map (hosted + federated side by side)
  URL hash = shareable state (the Share button builds it):
    #view=lon,lat,zoom&base=osm|light|dark|topo|satellite|none&layers=<name>:<visible>:<opacity>,...
    #sel=w,s,e,n                       box statistics on load
    #poly=lon,lat;lon,lat;lon,lat      polygon statistics on load (raster pixels masked, WFS INTERSECTS)
    #q=attr:op:value                   attribute query on load, e.g. #q=rock_class:=:Sedimentary
    #datasets=name,name                extra datasets added from the catalogue
  e.g. $CKAN_URL/dataset/thailand-population-density-2020/map/embed#poly=100.2,13.4;101.0,13.3;101.1,14.2;100.4,14.3&base=satellite
TXT

say "2. The page is an empty shell; everything is built in the browser from one API call"
show "curl $CKAN_URL/dataset/thailand-geological-map/map/embed | grep -o 'new AmconnectGIS.*'"
curl -s "$CKAN_URL/dataset/thailand-geological-map/map/embed" | grep -o 'new AmconnectGIS[^;]*' | head -1
note "-> fetch(/api/amconnect/datasets/<id>) => layers, hosted/federated, capabilities, legend URLs, download URLs, extent"

say "3. Embedding in another site"
cat <<'HTML'
  <iframe src="http://localhost:5000/dataset/thailand-geological-map/map/embed?tab=map"
          style="width:100%;height:640px;border:0"></iframe>
HTML
note "or reuse the component without CKAN's page at all:"
cat <<'HTML'
  <link rel="stylesheet" href="http://localhost:5000/amconnect/amconnect-gis.css">
  <script src="https://cdn.jsdelivr.net/npm/ol@v10.2.1/dist/ol.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/geotiff@2.1.3/dist-browser/geotiff.js"></script>
  <script src="http://localhost:5000/amconnect/amconnect-gis.js"></script>
  <div id="gis"></div>
  <script>new AmconnectGIS(document.getElementById('gis'), {api: 'http://localhost:5000/api/amconnect/datasets/thailand-geological-map', tab: 'map'});</script>
HTML
note "(cross-origin use of the API needs CORS on CKAN: ckan.cors.origin_allow_all / origin_whitelist)"

say "4. Static files served by CKAN (copy them into the future frontend, or rewrite against the same JSON)"
for f in amconnect-gis.js amconnect-gis.css; do printf '%s -> ' "$f"; curl -s -o /dev/null -w '%{http_code} %{size_download} bytes\n' "$CKAN_URL/amconnect/$f"; done
