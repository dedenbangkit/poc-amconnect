#!/usr/bin/env bash
# CKAN as API hub, part 1: the standard action API vs the AMConnect facade for one dataset.
source "$(dirname "$0")/_lib.sh"

say "1. Standard CKAN: package_show (complete, CKAN-shaped: extras list, 25 keys per resource, harvest info in extras)"
show "curl $CKAN_URL/api/3/action/package_show?id=thailand-population-density-2020 | jq '.result | keys'"
curl -s "$CKAN_URL/api/3/action/package_show?id=thailand-population-density-2020" | jget '.result | keys'

say "2. AMConnect facade: /api/amconnect/datasets/<id> (flat metadata + layers grouped by service + capabilities + links)"
show "curl $CKAN_URL/api/amconnect/datasets/thailand-population-density-2020"
curl -s "$CKAN_URL/api/amconnect/datasets/thailand-population-density-2020" | pp '.result | del(.resources) | del(.spatial)'

say "3. ?probe=false skips the live GetCapabilities checks (fast; capabilities then come from CKAN metadata only)"
show "curl '$CKAN_URL/api/amconnect/datasets/thailand-population-density-2020?probe=false' | jq '.result.layers[0] | {status, capabilities, downloads}'"
curl -s "$CKAN_URL/api/amconnect/datasets/thailand-population-density-2020?probe=false" | pp '.result.layers[0] | {status, capabilities, downloads}'

say "4. Access control is CKAN's: a private dataset returns 404 to anonymous callers exactly like /api/3"
show "curl -s -o /dev/null -w '%{http_code}' $CKAN_URL/api/amconnect/datasets/does-not-exist"; curl -s -o /dev/null -w '%{http_code}\n' "$CKAN_URL/api/amconnect/datasets/does-not-exist"
