#!/usr/bin/env bash
# ckanext-harvest: CKAN-to-CKAN federation.
#
# Source: the mock-ckan container (harvest-sources/mock-ckan) plays an ASEAN member-state
# catalogue and answers the two API calls the CKAN harvester needs.  Source type
# "amconnect_ckan" = the stock ckan harvester + ~20 lines of AMConnect glue (harvesters.py).
source "$(dirname "$0")/_lib.sh"

say "1. What the remote catalogue exposes (this is all the harvester reads)"
show "curl 'http://localhost:5001/api/3/action/package_search?rows=100&start=0&sort=id+asc'"
curl -s "http://localhost:5001/api/3/action/package_search?rows=100&start=0&sort=id+asc" | pp '[.result.results[] | {id, name, owner_org, resources: [.resources[] | {format, layer_name, url}]}]'

say "2. How the source is registered (done by 'ckan amconnect seed'; equivalent CLI shown)"
note "ckan harvester source create mock-asean-ckan http://mock-ckan:5001 amconnect_ckan 'Mock ASEAN member-state CKAN' true asean-partner-catalogues MANUAL '{\"remote_orgs\":\"create\",\"default_tags\":[{\"name\":\"harvested\"}]}'"
show "ckan harvester sources"
ckan_cli harvester sources

say "3. Trigger a job and run the three stages (gather -> fetch -> import) synchronously"
note "production: 'ckan harvester run' from cron + 'ckan harvester gather-consumer' / 'fetch-consumer' workers on the redis queue"
show "ckan amconnect harvest mock-asean-ckan"
ckan_cli amconnect harvest mock-asean-ckan

say "4. Result: the datasets exist locally, owned by the *remote* organisation (remote_orgs=create), tagged 'harvested'"
show "curl '$CKAN_URL/api/amconnect/search?origin=federated'"
curl -s "$CKAN_URL/api/amconnect/search?origin=federated" | pp '[.result[] | {name, origin, organization: .organization.title, tags, bbox, service_types}]'

say "5. Mapping: spatial/country/commodity/access_level arrive as extras and surface as root fields; resources keep format/url/layer_name"
show "curl $CKAN_URL/api/amconnect/datasets/malaysia-mineral-occurrences-mock"
curl -s "$CKAN_URL/api/amconnect/datasets/malaysia-mineral-occurrences-mock" | pp '.result | {origin, harvest, country, commodity, access_level, spatial: .spatial.type, layers: [.layers[] | {layer_name, origin, data_kind, view_only, capabilities}]}'
