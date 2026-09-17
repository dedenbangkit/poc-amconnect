#!/usr/bin/env bash
# CKAN as API hub, part 3: discovery.  /api/amconnect/search wraps package_search and returns
# AMConnect-shaped results with facets; the frontend never sees Solr syntax.
source "$(dirname "$0")/_lib.sh"

say "1. Free text"
show "curl '$CKAN_URL/api/amconnect/search?q=population'"
curl -s "$CKAN_URL/api/amconnect/search?q=population" | pp '{count, results: [.result[] | {name, title, origin, service_types, layer_count}]}'

say "2. AMConnect facets: country / commodity / data_type / access_level / organization / tags / origin"
show "curl '$CKAN_URL/api/amconnect/search?country=Thailand&access_level=public-view'"
curl -s "$CKAN_URL/api/amconnect/search?country=Thailand&access_level=public-view" | pp '{count, names: [.result[].name], facet_country: .facets.country.items, facet_origin_hint: "use origin=hosted|federated"}'

say "3. Federated only, with the facets the UI would render"
curl -s "$CKAN_URL/api/amconnect/search?origin=federated" | pp '{count, names: [.result[].name], organizations: [.facets.organization.items[] | {name, count}]}'

say "4. Paging and sorting map 1:1 to package_search (limit/offset/sort); the query echo shows the Solr fq that was used"
curl -s "$CKAN_URL/api/amconnect/search?limit=2&offset=1&sort=title_string+asc" | pp '{count, page: [.result[].name], query}'

say "5. The same through plain CKAN, for comparison (what the facade hides)"
show "curl '$CKAN_URL/api/3/action/package_search?q=population&fq=country:Thailand+-dataset_type:harvest&facet.field=[\"country\"]'"
curl -s "$CKAN_URL/api/3/action/package_search?q=population&fq=country:Thailand%20-dataset_type:harvest" | jget '[.result.count, [.result.results[].name]]'
