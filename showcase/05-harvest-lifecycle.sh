#!/usr/bin/env bash
# ckanext-harvest: synchronisation on subsequent runs (update / delete behaviour).
#
# Demonstrates with the mock CKAN source:
#   - an unchanged remote dataset is skipped ("not modified", compared on metadata_modified)
#   - a changed remote dataset (newer metadata_modified) is updated in place
#   - a dataset removed from the remote is NOT deleted by the CKAN harvester (it only sees
#     what the remote search returns); the CSW harvester DOES delete (it diffs guids).
# Every step edits harvest-sources/mock-ckan/datasets.json and re-runs the harvest.
source "$(dirname "$0")/_lib.sh"
DATA="$COMPOSE_DIR/harvest-sources/mock-ckan/datasets.json"
cp "$DATA" "$DATA.bak"; trap 'mv "$DATA.bak" "$DATA"; echo; note "restored $DATA"' EXIT

title() { curl -s "$CKAN_URL/api/3/action/package_show?id=malaysia-mineral-occurrences-mock" | jget '.result.title'; }

say "1. Run once more without changes: objects are reported 'not modified'"
ckan_cli amconnect harvest mock-asean-ckan

say "2. Change the remote record (title + newer metadata_modified) and run again: 'updated'"
python3 - "$DATA" <<'PY'
import json, sys, datetime
p = sys.argv[1]; d = json.load(open(p))
for ds in d["datasets"]:
    if ds["name"] == "malaysia-mineral-occurrences-mock":
        ds["title"] = ds["title"] + " [edited at source]"
        ds["metadata_modified"] = datetime.datetime.utcnow().isoformat()
json.dump(d, open(p, "w"), indent=2)
PY
ckan_cli amconnect harvest mock-asean-ckan
show "local title now:"; title

say "3. Remove the record at the source and run again: the CKAN harvester leaves the local copy in place"
python3 - "$DATA" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["datasets"] = [ds for ds in d["datasets"] if ds["name"] != "malaysia-mineral-occurrences-mock"]
json.dump(d, open(p, "w"), indent=2)
PY
ckan_cli amconnect harvest mock-asean-ckan
show "local dataset still exists:"; curl -s "$CKAN_URL/api/3/action/package_show?id=malaysia-mineral-occurrences-mock" | jget '.result.state'
note "-> deletions must be handled by policy: 'ckan harvester source clear <id>' (drops all its datasets) or a custom gather_stage that diffs guids like the CSW harvester."

say "4. Scheduling: the source has a 'frequency' (MANUAL, DAILY, WEEKLY, BIWEEKLY, MONTHLY, ALWAYS)."
note "'ckan harvester run' (cron, e.g. every 15 min) creates jobs for sources whose frequency is due, and marks finished jobs;"
note "the actual work happens in 'ckan harvester gather-consumer' and 'fetch-consumer' processes reading the redis queue."
show "ckan harvester sources"
ckan_cli harvester sources
