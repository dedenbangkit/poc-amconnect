# Shared helpers for the showcase scripts. Source this file; do not run it.
#   CKAN_URL       CKAN base URL as seen from this machine   (default http://localhost:5000)
#   GEOSERVER_URL  GeoServer base URL as seen from a browser (default http://localhost:8080/geoserver)
set -euo pipefail
CKAN_URL="${CKAN_URL:-http://localhost:5000}"
GEOSERVER_URL="${GEOSERVER_URL:-http://localhost:8080/geoserver}"
COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

have_jq() { command -v jq >/dev/null 2>&1; }
# pretty-print JSON with jq if present, else python
pp() { if have_jq; then jq "$@"; else python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), indent=2))'; fi; }
# pick a value out of JSON with a jq filter (jq required for the fancier filters; python fallback covers dotted paths)
jget() {
  local filter="$1"
  if have_jq; then jq -rc "$filter"; else
    python3 -c '
import json,sys
doc=json.load(sys.stdin); f=sys.argv[1].lstrip(".")
for part in [p for p in f.split(".") if p]:
    if part.endswith("]"):
        name, idx = part[:-1].split("["); doc = (doc[name] if name else doc)[int(idx)]
    else:
        doc = doc[part]
print(doc if not isinstance(doc,(dict,list)) else json.dumps(doc))' "$filter"
  fi
}
say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
note() { printf '\033[0;33m   %s\033[0m\n' "$*"; }
show() { printf '\033[0;32m$ %s\033[0m\n' "$*"; }
ckan_cli() { (cd "$COMPOSE_DIR" && docker compose exec -T ckan ckan -c /srv/app/ckan.ini "$@") 2>&1 | grep -vE '^\S+ \S+ (INFO|WARNI|DEBUG) ' || true; }
