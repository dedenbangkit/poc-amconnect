#!/usr/bin/env bash
# ckanext-spatial's CSW harvester: ISO 19139 federation (the realistic path for SDIs / CCOP).
#
# Source: the pycsw container (harvest-sources/pycsw) serves two ISO 19139 records over CSW 2.0.2.
# Source type "amconnect_csw" = ckanext-spatial's csw harvester + a 6-line fetch fix + the
# ISpatialHarvester.get_package_dict mapping (harvesters.py).
source "$(dirname "$0")/_lib.sh"

say "1. What the remote CSW exposes"
show "curl 'http://localhost:8001/csw?service=CSW&version=2.0.2&request=GetRecords&typenames=csw:Record&elementsetname=brief&resulttype=results'"
curl -s "http://localhost:8001/csw?service=CSW&version=2.0.2&request=GetRecords&typenames=csw:Record&elementsetname=brief&resulttype=results&outputschema=http://www.isotc211.org/2005/gmd" | grep -o 'numberOfRecordsMatched="[0-9]*"\|<gco:CharacterString>mock-sdi[^<]*' 
show "curl 'http://localhost:8001/csw?service=CSW&version=2.0.2&request=GetRecordById&id=mock-sdi-thailand-geology-service&outputschema=http://www.isotc211.org/2005/gmd'  (online resources = the services)"
curl -s "http://localhost:8001/csw?service=CSW&version=2.0.2&request=GetRecordById&id=mock-sdi-thailand-geology-service&outputschema=http://www.isotc211.org/2005/gmd&elementsetname=full" | grep -o '<gmd:URL>[^<]*</gmd:URL>\|codeListValue="[a-z]*"\|OGC:W[A-Z]S'

say "2. Run the harvest (gather = GetRecords ids, fetch = GetRecordById per id, import = ISO -> CKAN dataset)"
show "ckan amconnect harvest mock-external-sdi-csw"
ckan_cli amconnect harvest mock-external-sdi-csw

say "3. Result: datasets with ISO-derived extras (bbox -> spatial, keywords -> tags, constraints, contacts...) and WMS/WFS resources"
show "curl $CKAN_URL/api/3/action/package_show?id=thailand-geological-units-via-partner-geoserver-mock-sdi-record"
curl -s "$CKAN_URL/api/3/action/package_search?fq=harvest_source_title:*SDI*&rows=5" | pp '[.result.results[] | {name, spatial: (.spatial|fromjson|.type), extras: [.extras[] | select(.key|test("^(guid|metadata-date|spatial-reference-system|responsible-party|harvest_source_title)$")) | {key, value: (.value|tostring|.[0:60])}], resources: [.resources[] | {format, layer_name, url, resource_locator_protocol}]}]'

say "4. The capability layer sees the harvested services like any other: hosted vs federated is decided per URL"
curl -s "$CKAN_URL/api/amconnect/search?q=mock+SDI&origin=federated" | pp '[.result[] | {name, origin, service_types, capabilities: [.capabilities | to_entries[] | select(.value) | .key]}]'
