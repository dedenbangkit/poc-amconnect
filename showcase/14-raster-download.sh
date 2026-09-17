#!/usr/bin/env bash
# Raster download: from CKAN resource -> WCS capabilities -> GetCoverage URLs -> GeoTIFF.
source "$(dirname "$0")/_lib.sh"
OUT="${OUT:-/tmp/amconnect-downloads}"; mkdir -p "$OUT"

say "1. Which CKAN resource: the WCS resource of thailand-population-density-2020 (format=WCS, layer_name=coverage)"
RID=$(curl -s "$CKAN_URL/api/3/action/package_show?id=thailand-population-density-2020" | jget '[.result.resources[] | select(.format=="WCS")][0].id')
curl -s "$CKAN_URL/api/3/action/resource_show?id=$RID" | pp '.result | {id, format, url, layer_name}'

say "2. Downloads CKAN derives for it (formats from wcs:formatSupported in GetCapabilities; coverageId = layer_name with ':' -> '__')"
show "curl $CKAN_URL/api/amconnect/resources/$RID | jq '{formats: .result.formats, downloads: .result.downloads}'"
curl -s "$CKAN_URL/api/amconnect/resources/$RID" | pp '{formats: .result.formats, downloads: .result.downloads}'

say "3. How a URL is constructed:  <endpoint>?service=WCS&version=2.0.1&request=GetCoverage&coverageId=<ws__layer>[&format=image/tiff][&subset=Long(a,b)&subset=Lat(c,d)]"
note "no format parameter  -> native format of the coverage (GeoTIFF here) = 'original/native'"
note "format=image/tiff     -> GeoTIFF (explicit); image/png -> rendered pixels, NOT data"
note "subset=...            -> clipped download (the Analysis tab's 'Download this selection')"

say "4. Fetch the GeoTIFF (full) and a clip"
URL=$(curl -s "$CKAN_URL/api/amconnect/resources/$RID" | jget '[.result.downloads[] | select(.format=="GeoTIFF")][0].url')
show "curl '$URL' -o $OUT/tha_pd_2020.tif"
curl -s -o "$OUT/tha_pd_2020.tif" -w 'full: %{http_code} %{content_type} %{size_download} bytes\n' "$URL"
CLIP="${URL}&subset=Long(100.3,100.9)&subset=Lat(13.5,14.0)"
curl -s -o "$OUT/tha_pd_2020_bangkok.tif" -w 'clip: %{http_code} %{content_type} %{size_download} bytes\n' "$CLIP"
if command -v gdalinfo >/dev/null; then gdalinfo "$OUT/tha_pd_2020_bangkok.tif" | grep -E "Size is|Pixel Size|NoData"; else file "$OUT/tha_pd_2020_bangkok.tif" 2>/dev/null || true; fi

say "5. Contrast: 'Export map image' (WMS GetMap) is offered separately and is a picture, not the data"
curl -s "$CKAN_URL/api/amconnect/datasets/thailand-population-density-2020/services" | jget '.result.layers[0].export_map_image'
