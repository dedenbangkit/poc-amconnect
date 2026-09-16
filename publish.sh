#!/usr/bin/env bash
# Publish a spatial file end to end: GeoServer (WMS) + CKAN dataset with map preview.
#
#   ./publish.sh <file.tif|file.geojson|file.gpkg> [--title "Dataset title"] [--force]
#
# Steps: copy the file (and a <name>.sld next to it, if any) into geoserver/data,
# write a metadata sidecar geoserver/data/<name>.json if none exists, then run the
# GeoServer seed job and the CKAN seed command.  Both are idempotent, so re-running
# after editing the sidecar or the SLD just updates things in place.
set -euo pipefail
cd "$(dirname "$0")"

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

FILE="" TITLE="" FORCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --title) TITLE="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage ;;
    *) FILE="$1"; shift ;;
  esac
done
[ -n "$FILE" ] && [ -f "$FILE" ] || usage

BASE=$(basename "$FILE")
case "${BASE,,}" in
  *.tif|*.tiff|*.geojson|*.gpkg) ;;
  *) echo "unsupported extension: $BASE (use .tif/.tiff/.geojson/.gpkg)"; exit 1 ;;
esac
NAME="${BASE%.*}"
if ! [[ "$NAME" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
  echo "layer name '$NAME' must be letters/digits/underscore and start with a letter (rename the file)"; exit 1
fi

mkdir -p geoserver/data geoserver/styles
if [ "$(realpath "$FILE")" != "$(realpath -m "geoserver/data/$BASE")" ]; then
  cp -f "$FILE" "geoserver/data/$BASE"
  echo "copied $BASE -> geoserver/data/"
fi
SLD="$(dirname "$FILE")/$NAME.sld"
if [ -f "$SLD" ] && [ "$(realpath "$SLD")" != "$(realpath -m "geoserver/styles/$NAME.sld")" ]; then
  cp -f "$SLD" "geoserver/styles/$NAME.sld"; echo "copied $NAME.sld -> geoserver/styles/"
fi

SIDECAR="geoserver/data/$NAME.json"
if [ ! -f "$SIDECAR" ]; then
  python3 - "$SIDECAR" "$NAME" "${TITLE:-$NAME}" <<'PY'
import json, sys
path, name, title = sys.argv[1:4]
json.dump({
    "title": title,
    "notes": f"Layer amconnect:{name} published by the AMConnect POC GeoServer.",
    "country": "Thailand", "commodity": "", "data_type": "geospatial",
    "access_level": "public-view", "tags": ["wms"],
}, open(path, "w"), indent=2)
PY
  echo "wrote metadata sidecar $SIDECAR (edit it and re-run to update CKAN)"
elif [ -n "$TITLE" ]; then
  echo "note: $SIDECAR exists; --title ignored (edit the sidecar instead)"
fi

echo "== GeoServer: publishing geoserver/data/* (layer amconnect:$NAME)"
docker compose run --rm ${FORCE:+-e FORCE=1} geoserver-seed
echo "== CKAN: creating/updating datasets"
docker compose exec ckan ckan -c /srv/app/ckan.ini amconnect seed 2>&1 | grep -vE "INFO|WARNI"

SLUG=$(python3 -c "import json,re,sys; m=json.load(open(sys.argv[1])); print(m.get('name') or re.sub(r'[^a-z0-9-]+','-',sys.argv[2].lower()).strip('-'))" "$SIDECAR" "$NAME")
PORT=$(grep -E '^CKAN_PORT=' .env | cut -d= -f2); PORT=${PORT:-5000}
echo "== done: http://localhost:$PORT/dataset/$SLUG/map"
