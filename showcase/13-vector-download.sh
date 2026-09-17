#!/usr/bin/env bash
# Vector download: from CKAN resource -> WFS capabilities -> concrete GetFeature URLs -> files.
source "$(dirname "$0")/_lib.sh"
OUT="${OUT:-/tmp/amconnect-downloads}"; mkdir -p "$OUT"

say "1. Which CKAN resource: the WFS resource of thailand-geological-map (format=WFS, url=endpoint, layer_name=type name)"
RID=$(curl -s "$CKAN_URL/api/3/action/package_show?id=thailand-geological-map" | jget '[.result.resources[] | select(.format=="WFS")][0].id')
curl -s "$CKAN_URL/api/3/action/resource_show?id=$RID" | pp '.result | {id, format, url, layer_name}'

say "2. Downloads CKAN derives for it (only formats the WFS advertises in GetCapabilities)"
show "curl $CKAN_URL/api/amconnect/resources/$RID | jq '.result.downloads'"
curl -s "$CKAN_URL/api/amconnect/resources/$RID" | pp '.result.downloads'

say "3. How a URL is constructed:  <endpoint>?service=WFS&version=2.0.0&request=GetFeature&typeNames=<layer_name>&outputFormat=<advertised format>"
note "GeoJSON      outputFormat=application/json"
note "GML 3.2      outputFormat=gml32"
note "CSV          outputFormat=csv"
note "Shapefile    outputFormat=SHAPE-ZIP"
note "add &bbox=minx,miny,maxx,maxy,EPSG:4326 to download a selection (the Analysis tab does this)"

say "4. Fetch each one and show what comes back"
curl -s "$CKAN_URL/api/amconnect/resources/$RID" | python3 -c 'import json,sys; [print(d["extension"] or "bin", d["url"]) for d in json.load(sys.stdin)["result"]["downloads"]]' | while read -r ext url; do
  f="$OUT/thailand_geology.$ext"
  code=$(curl -s -o "$f" -w '%{http_code} %{content_type}' "$url")
  printf '%-8s %s -> %s (%s bytes)\n' "$ext" "$code" "$f" "$(stat -c %s "$f")"
done
[ -f "$OUT/thailand_geology.geojson" ] && python3 -c "import json; d=json.load(open('$OUT/thailand_geology.geojson')); print('GeoJSON features:', len(d['features']), 'first props:', list(d['features'][0]['properties'])[:5])"
[ -f "$OUT/thailand_geology.zip" ] && (command -v unzip >/dev/null && unzip -l "$OUT/thailand_geology.zip" | tail -n +2 | head -8 || true)

say "5. Contrast: a WMS-only resource has no vector download (view only), and the UI must not pretend otherwise"
RID2=$(curl -s "$CKAN_URL/api/3/action/package_show?id=malaysia-mineral-occurrences-mock" | jget '[.result.resources[] | select(.format=="WMS")][0].id')
curl -s "$CKAN_URL/api/amconnect/resources/$RID2" | pp '.result | {format, origin, status, capabilities: (.capabilities | {view, download_vector, federated}), downloads, export_map_image: (.export_map_image != null)}'
