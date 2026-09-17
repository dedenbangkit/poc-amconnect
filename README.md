# AMConnect POC: CKAN as data/API hub + GeoServer/PostGIS WebGIS

Proof of concept for the AMConnect backend. Phase 1 proved that CKAN can catalogue
datasets and that GeoServer/PostGIS can serve them as WMS/WFS/WCS with a map preview in
CKAN. Phase 2 (this version) asks the real question:

> Can CKAN, with its standard geospatial extensions, be the **data catalogue, metadata
> registry, federation layer and API hub** behind a separate AMConnect web application,
> and how small can the custom code stay?

Feature inventory (API, GIS view, which extension serves what): [FEATURES.md](FEATURES.md).

Short answer, detailed in [AMConnect Backend Architecture Evaluation](#amconnect-backend-architecture-evaluation):
**yes, as backend/API hub (option b)**. ckanext-spatial and ckanext-harvest take over spatial
metadata, spatial search and federation; ckanext-geoview is a useful reference but not the
AMConnect viewer; `ckanext-amconnect` stays small (schema, service/capability model, a thin
API facade, harvest glue, the GIS view).

```
AMConnect frontend (future, separate app)          this POC: the CKAN "Map" tab and /map/embed
        |  /api/amconnect/...  (or /api/3/action/...)        play the frontend's role
        v
CKAN 2.11  = catalogue + metadata + spatial index + harvesting + API
        |      ckanext-spatial, ckanext-harvest, (ckanext-geoview), ckanext-amconnect
        |  stores WHERE the data is and WHAT each service can do
        v
GeoServer + PostGIS = WMS (view) / WFS (query, vector download) / WCS (raster download, clip)
        ^
        |  harvested records point at partner services instead (federated)
mock CKAN (ASEAN member state)   pycsw CSW (external SDI, ISO 19139)
```

This is **not** production-ready. GeoNode is deliberately left out (see the last section).

## Stack

| Service          | Image                                     | Role |
|------------------|-------------------------------------------|------|
| `ckan`           | built from `ckan/ckan-base:2.11`          | Catalogue / API hub: ckanext-spatial 2.3.2, ckanext-harvest 1.6.2, ckanext-geoview 0.3.1, ckanext-amconnect |
| `db`             | `postgres:16-alpine`                      | CKAN database |
| `solr`           | `ckan/ckan-solr:2.11-solr9-spatial`       | Search index with the `spatial_geom` (JTS) field for ckanext-spatial |
| `redis`          | `redis:7-alpine`                          | CKAN cache + ckanext-harvest job queue |
| `geoserver`      | `docker.osgeo.org/geoserver:2.26.2`       | WMS / WFS / WCS |
| `postgis`        | `postgis/postgis:16-3.4`                  | GeoServer's vector store |
| `geoserver-seed` | built from `ghcr.io/osgeo/gdal`           | One-shot: publishes `geoserver/data/` (vector -> PostGIS, raster -> GeoServer) |
| `mock-ckan`      | `python:3.12-alpine`                      | Federation test source: a fake remote CKAN API (2 datasets) |
| `pycsw`          | `geopython/pycsw`                         | Federation test source: CSW 2.0.2 catalogue with 2 ISO 19139 records |

```
poc-amconnect/
├── docker-compose.yml
├── .env                          # ports, credentials, public GeoServer URL
├── publish.sh                    # publish one file end to end (GeoServer + CKAN)
├── showcase/                     # 14 curl walkthroughs, one per evaluation topic (see below)
├── harvest-sources/
│   ├── mock-ckan/                # server.py + datasets.json  (edit -> re-harvest)
│   └── pycsw/                    # pycsw.yml + records/*.xml (ISO 19139)
├── ckan/
│   ├── Dockerfile                # ckan-base + the 3 standard extensions + ckanext-amconnect
│   ├── docker-entrypoint.d/      # harvest migrations, `ckan amconnect seed`, `ckan amconnect harvest`
│   └── ckanext-amconnect/        # the custom extension (see "What stays custom")
└── geoserver/
    ├── data/                     # DROP FOLDER: <name>.geojson|gpkg|shp|tif + <name>.json sidecar
    ├── styles/<name>.sld         # optional default style per layer; <name>__<variant>.sld = alternate styles
    └── seed/seed.py              # publishes the drop folder via GeoServer REST
```

## Run it

Requirements: Docker with Compose v2, roughly 5 GB RAM free, ports 5000, 5001, 8001 and 8080 free.

```bash
cp .env.example .env
docker compose up -d --build
docker compose logs -f ckan          # done when you see "[amconnect] harvesting demo sources ... Finished"
```

First start takes a few minutes: CKAN initialises DB and Solr, GeoServer boots, the seed jobs
publish the two example layers, then CKAN registers and runs the two harvest sources. Reset
everything with `docker compose down -v`.

Then run the showcase scripts (they only need `curl`, `python3`, ideally `jq`):

```bash
./showcase/02-spatial-search.sh
./showcase/08-api-services.sh
./showcase/13-vector-download.sh
```

## Service URLs

| What | URL |
|---|---|
| CKAN portal | http://localhost:5000 |
| GIS view (in CKAN) | http://localhost:5000/dataset/thailand-geological-map/map |
| GIS view, standalone/embed | http://localhost:5000/dataset/thailand-geological-map/map/embed |
| Analysis deep link | http://localhost:5000/dataset/thailand-population-density-2020/map/embed?tab=analysis&bbox=100.3,13.5,100.9,14.0 |
| Multi-dataset map | http://localhost:5000/amconnect/map?datasets=thailand-geological-map,thailand-population-density-2020 |
| AMConnect API | http://localhost:5000/api/amconnect/datasets/thailand-geological-map |
| CKAN action API | http://localhost:5000/api/3/action/package_show?id=thailand-geological-map |
| Harvest admin (login admin/admin12345) | http://localhost:5000/harvest |
| GeoServer admin | http://localhost:8080/geoserver/web/ |
| GeoServer WMS / WFS / WCS | http://localhost:8080/geoserver/amconnect/{wms,wfs,wcs} |
| Mock remote CKAN | http://localhost:5001/api/3/action/package_search |
| Mock CSW (pycsw) | http://localhost:8001/csw?service=CSW&version=2.0.2&request=GetCapabilities |

Credentials (all in `.env`): CKAN `admin`/`admin12345`, GeoServer `admin`/`geoserver`,
CKAN DB `ckan`/`ckan`, PostGIS `gis`/`gis`.

## What is seeded

**Hosted** (organisation `AMConnect`, from `geoserver/data/`):

| Dataset | Layer | Resources | Capabilities |
|---|---|---|---|
| `thailand-geological-map` | `amconnect:thailand_geology` (synthetic vector) | WMS + WFS, plus an external OSM WMS (terrestris) | view, identify, query, download_vector, area_statistics |
| `thailand-population-density-2020` | `amconnect:tha_pd_2020_1km_UNadj` (WorldPop raster) | WMS + WCS | view, identify, download_raster, area_statistics |
| `thailand-mineral-sites` | `amconnect:thailand_mineral_sites` (200 synthetic points; styles by commodity, status, grade) | WMS + WFS | view, identify, query, download_vector, area_statistics |

**Federated, catalogue-only** (from `geoserver/data/external/*.json`, no local file):

| Dataset | Service | Capabilities |
|---|---|---|
| `lao-mineral-map-ccop` | CCOP GSi dynamic WMS (MapServer), Lao PDR 1:1M mineral map, queryable, legend, no CORS, no WFS/WCS | view, identify (via link, no CORS/JSON), export_map_image, federated; view-only |

**Federated** (harvested at start, re-run any time with `docker compose exec ckan ckan -c /srv/app/ckan.ini amconnect harvest`):

| Source | Type | Datasets |
|---|---|---|
| `mock-asean-ckan` (container `mock-ckan`) | `amconnect_ckan` (CKAN-to-CKAN) | `world-countries-natural-earth` (WMS+WFS on a partner GeoServer that blocks server-side probes), `malaysia-mineral-occurrences-mock` (WMS-only + PDF) |
| `mock-external-sdi-csw` (container `pycsw`) | `amconnect_csw` (CSW / ISO 19139) | an OSM basemap record (view-only WMS) and a record whose WMS+WFS happen to point at the POC GeoServer |

The vector examples are synthetic (Voronoi cells over a Thailand outline; 200 random mineral
sites with commodity / status / grade / year) and illustrate the pipeline, not real geology.
The raster is WorldPop 2020 population density (1 km, UN adjusted).

**Point-layer performance** (200 points in PostGIS, 64 kB table, measured with curl on the POC
host, warm GeoServer):

| Request | Time | Size |
|---|---|---|
| WMS GetMap 512x768, all points | 17 ms | 61 kB |
| WMS 256px tile | 11 ms | 23 kB |
| WFS GetFeature GeoJSON (200 features) | 10 ms | 67 kB |
| WFS GetFeature CSV / Shapefile zip / GML 3.2 | 18 ms / 108 ms / 644 ms | 23 / 12 / 237 kB |
| WFS bbox query, CQL `commodity='Gold'` (38 features) | 5 ms / 6 ms | |
| GetFeatureInfo (JSON) | 7 ms | |
| `/api/amconnect/datasets/<id>` (probe cached / probing) | 10 ms / 80 ms | 9 kB |

The GIS view renders the layer, its legend and a box selection with category chart in about
1.4 s of headless-browser wall time including CDN scripts. At this size everything is
network-bound; points become interesting for the browser-side analysis only in the tens of
thousands (then use WFS `count`/paging or move the summary server-side).

## Publishing your own data

```bash
./publish.sh path/to/my_layer.tif --title "My layer"      # GeoTIFF
./publish.sh path/to/my_layer.geojson                     # GeoJSON / GeoPackage
```

Copies the file into `geoserver/data/`, writes a `<name>.json` sidecar if missing, runs the
GeoServer seed (vector -> PostGIS + feature type, raster -> coverage store) and
`ckan amconnect seed`, which creates/updates the CKAN dataset with **WMS + WFS** (vector) or
**WMS + WCS** (raster) resources and a `spatial` extent read from GeoServer's GetCapabilities.

A record for a partner service without a local file goes in `geoserver/data/external/<slug>.json`
with the same keys plus a `resources` list (`name`, `description`, `url`, `format`, `layer_name`);
the seed creates a catalogue-only, federated dataset (example: the CCOP Lao mineral map WMS).

Sidecar keys (all optional): `name`, `title`, `notes`, `country`, `commodity`, `data_type`,
`access_level`, `spatial` (GeoJSON, overrides the derived extent), `tags`, `resource_name`,
`resource_description`, `extra_resources` (list of `{name, description, url, format, layer_name}`
for external services or files). Layer names must be letters, digits and underscores.
Raster tips: the GeoTIFF must carry a CRS; float rasters need an SLD (copy
`geoserver/styles/tha_pd_2020_1km_UNadj.sld`).

---

# AMConnect Backend Architecture Evaluation

Everything in this section was exercised against the running stack; each claim has a
showcase script next to it.

| # | Script | Topic |
|---|---|---|
| 01 | `showcase/01-spatial-extent.sh` | how `spatial` is stored, derived from GeoServer, exposed |
| 02 | `showcase/02-spatial-search.sh` | `ext_bbox` search, `/api/amconnect/spatial-search` |
| 03 | `showcase/03-harvest-ckan.sh` | CKAN-to-CKAN harvesting (source, job, mapping) |
| 04 | `showcase/04-harvest-csw.sh` | CSW / ISO 19139 harvesting through ckanext-spatial |
| 05 | `showcase/05-harvest-lifecycle.sh` | re-harvest: unchanged / changed / deleted records, scheduling |
| 06 | `showcase/06-geoview.sh` | ckanext-geoview as reference viewer |
| 07 | `showcase/07-api-dataset.sh` | `package_show` vs `/api/amconnect/datasets/<id>` |
| 08 | `showcase/08-api-services.sh` | grouped services + capabilities |
| 09 | `showcase/09-api-search.sh` | `/api/amconnect/search` |
| 10 | `showcase/10-embed-map.sh` | GIS view routes, embedding |
| 11 | `showcase/11-analysis.sh` | selected-area analysis with curl (WCS clip, WFS bbox) |
| 12 | `showcase/12-resource-capabilities.sh` | how capabilities are derived |
| 13 | `showcase/13-vector-download.sh` | WFS downloads (GeoJSON, GML, CSV, Shapefile, KML) |
| 14 | `showcase/14-raster-download.sh` | WCS downloads (GeoTIFF, native, clip) |

## Proposed architecture

```
                    +--------------------------------------------------------------+
                    |  AMConnect website (separate app: landing, auth, AMVest,     |
                    |  WebGIS UI, analysis views)                                  |
                    +------+------------------------+--------------------+---------+
                           |                        |                    |
             discovery / metadata /          tiles, features,       heavier processing
             capabilities (JSON)             coverages (OGC)        (later)
                           |                        |                    |
  +------------------------v-----------+   +--------v---------+   +------v-----------+
  |  CKAN 2.11  (catalogue / API hub)  |   | GeoServer 2.26   |   | Analysis service |
  |  /api/3/action/*                   |   |  WMS  view       |   | (future: WPS or  |
  |  /api/amconnect/*  (thin facade)   |   |  WFS  query/dl   |   |  small Python    |
  |                                    |   |  WCS  raster dl  |   |  API next to     |
  |  ckanext-spatial  extent + search  |   +--------+---------+   |  GeoServer)      |
  |  ckanext-harvest  federation       |            |             +------------------+
  |  ckanext-amconnect schema, caps,   |   +--------v---------+
  |     API facade, harvest glue, view |   | PostGIS          |
  +---+---------------------+----------+   | vector tables    |
      |                     |              +------------------+
  +---v--------+   +--------v----------+
  | remote CKAN|   | CSW / ISO (SDI,   |     ... other partner GeoServers / WMS / WFS
  | (member    |   | CCOP, GeoNetwork, |         referenced by harvested records
  | state)     |   | pycsw, GeoNode)   |
  +------------+   +-------------------+
```

CKAN never touches pixels or features. It knows **where** each service is and **what** it can
do; the frontend talks to GeoServer (or a partner's server) directly for the data.

## Responsibility boundaries

| Component | Responsible for | Explicitly not |
|---|---|---|
| **ckanext-spatial** | `spatial` extent validation, Solr geometry index, `ext_bbox` search, CSW/WAF harvesters (ISO 19139 -> dataset), sidebar extent map, search-page map | defining the `spatial` field (the site schema must), polygon-shaped queries (only bbox), resource-level extents |
| **ckanext-harvest** | harvest sources/jobs/objects model, CKAN-to-CKAN harvester, queue + consumers, scheduling by frequency, admin UI, `harvest_*` extras on harvested datasets | deleting datasets removed at a CKAN source, mapping remote fields to a custom schema (needs a subclass hook) |
| **ckanext-geoview** | quick previews of WMS/WFS/GeoJSON/KML/GML/WMTS resources inside CKAN via a proxy | legends, downloads, WCS, analysis, embedding outside CKAN, servers CKAN cannot reach |
| **ckanext-amconnect** | 5 dataset fields, `layer_name` resource field, resource -> service/capability model (`services.py`), `/api/amconnect/*`, GIS view (in-page + embed + resource view), harvest glue (2 tiny subclasses + `ISpatialHarvester`), `ckan amconnect seed/harvest` | anything a standard extension already does |
| **GeoServer** | WMS rendering + legends + GetFeatureInfo, WFS queries and vector export, WCS raster export and clipping, styles, layer metadata (title/abstract/bbox as service metadata) | being the catalogue, access control across systems (public in the POC) |
| **PostGIS** | vector storage for hosted layers, spatial SQL behind WFS | raster storage (files in GeoServer's data dir), CKAN's own DB (plain PostgreSQL) |
| **AMConnect frontend** | landing/auth/AMVest, map UI, choosing buttons from `capabilities`, calling OGC services directly, rendering analysis results | knowing CKAN internals (extras lists, Solr syntax), building OGC URLs by hand |
| **Future analysis service** | zonal statistics over polygons, multi-layer overlays, large rasters, stored/shared results | duplicating GeoServer's WFS/WCS (bbox stats already work client-side) |

## Extension comparison

| | ckanext-spatial 2.3.2 | ckanext-harvest 1.6.2 | ckanext-geoview 0.3.1 |
|---|---|---|---|
| CKAN 2.11 install | pip from tag + its `requirements.txt` (OWSLib, Shapely, pyproj, geojson, lxml) | pip from tag; **needs `pika` installed even with redis** because ckanext-spatial imports `ckanext.harvest.queue` | pip from tag; needs core `resource_proxy` plugin |
| Config used | `search_backend = solr-spatial-field`, `common_map.*` for its Leaflet widgets | `mq.type = redis`, `mq.hostname = redis`, `ckan db upgrade -p harvest` | `ol_viewer.formats = wms wfs geojson kml gml` |
| Solves | extent storage/validation, spatial index, bbox search, ISO/CSW ingest, extent widgets | source registry, job lifecycle, incremental CKAN sync, ISO ingest plumbing, scheduling, admin UI | zero-code previews for common formats, proxy pattern for cross-origin capabilities |
| Does not solve | polygon queries, per-resource extents, mapping ISO to a custom schema (hook provided) | CKAN-source deletions, custom-schema mapping (hook provided), source reindex bug on 2.11 | legend/download/WCS/analysis/embed, servers not reachable from CKAN's network, layer name must be in the URL fragment |
| Compatibility notes | works; `csw_client` leaves an XML declaration in unicode content with pycsw 3 (6-line subclass fix); `harvester run-test` needs pytest/factory-boy (dev extras), replaced by `ckan amconnect harvest` | works; `harvest_source_reindex` raises `KeyError ('extras', 0, 'id')` on CKAN 2.11.6 (`default_extras_schema.id` gained `ignore_not_sysadmin`); jobs still finish, only the source's own index entry is stale | works; nothing patched |
| Verdict | **keep** | **keep** | **reference only** (keep enabled, not the AMConnect viewer) |

Two CKAN facts learned the hard way, both documented in code:

* Harvesters do **not** use the site's `IDatasetForm` schema. `HarvesterBase` builds
  datasets with CKAN's default create schema plus `__junk = ignore`, so root-level custom
  fields are dropped silently, while `extras` pass through. Our schema reads the AMConnect
  fields back from extras (`convert_from_extras`), so harvest glue only has to keep values
  *in* extras. (`harvesters.py`)
* Subclassing a `SingletonPlugin` harvester and enabling both base and subclass makes CKAN
  hand the subclass the base instance; the subclass' `info()['name']` never registers. Enable
  only the subclass (`amconnect_ckan_harvester`, `amconnect_csw_harvester`).

## 1. ckanext-spatial as the spatial metadata and discovery layer

**Storage.** One dataset extra `spatial` holding a GeoJSON geometry (Polygon, MultiPolygon,
Point, GeometryCollection). The extension validates it on create/update; our `IDatasetForm`
declares the field so it is a root key in the API and a textarea in the form:

```bash
curl -s localhost:5000/api/3/action/package_show?id=thailand-geological-map | jq -r .result.spatial
# {"type": "Polygon", "coordinates": [[[97.349998, 5.65], [105.600006, 5.65], [105.600006, 20.450001], ...]]}
```

**Derivation.** `ckan amconnect seed` reads the layer's `EX_GeographicBoundingBox` from
GeoServer's WMS GetCapabilities (OWSLib, internal URL) and stores it as a Polygon unless the
sidecar provides `spatial`. `ckan amconnect extent amconnect:thailand_geology` prints it.
So yes, extents can be derived automatically from existing GeoServer layers; polygons
tighter than the bbox would need a footprint computed in PostGIS (`ST_ConvexHull`) or GDAL.

**Indexing.** `solr-spatial-field` backend: the geometry is indexed as WKT in Solr's
`spatial_geom` (JTS recursive prefix tree). The plain `solr-bbox` backend only needs the
standard Solr image but indexes the envelope. No PostGIS in CKAN's database anymore
(removed in ckanext-spatial 2.0).

**Queries.** `package_search` gets an `ext_bbox` parameter; the backend turns it into
`fq={!field f=spatial_geom}Intersects(ENVELOPE(minx,maxx,maxy,miny))`, combinable with `q`
and `fq`. Only bbox input is supported; the intersection is evaluated against the real polygon.

```bash
curl -s 'localhost:5000/api/3/action/package_search?ext_bbox=100.3,13.5,100.9,14.0'      # greater Bangkok -> the 2 Thai datasets
curl -s 'localhost:5000/api/3/action/package_search?ext_bbox=101,2,103,4'                 # -> malaysia-mineral-occurrences-mock only
curl -s 'localhost:5000/api/amconnect/spatial-search?bbox=100.3,13.5,100.9,14.0&origin=hosted'
```

**Vector and raster.** The field is dataset-level, so it works for both; layer-level extents
additionally come from the live capability probe (`layers[].extent`).

**UI.** Dataset sidebar extent map (`spatial/snippets/dataset_map.html`, wired in our
`read_base.html`) and a draw-a-box filter on `/dataset` (`spatial_query` snippet, standard).

**Does it make our metadata implementation unnecessary?** For the spatial part, yes: no custom
extent field, index or query code. It does not provide a form field, resource-level
extents, or AMConnect's own fields (country, commodity, access level), which stay in
`ckanext-amconnect` (or would move to ckanext-scheming in production).

## 2. ckanext-harvest as the federation hub

**Registering a source** (done by the seed; equivalent CLI):

```bash
ckan harvester source create mock-asean-ckan http://mock-ckan:5001 amconnect_ckan \
  'Mock ASEAN member-state CKAN' true asean-partner-catalogues MANUAL \
  '{"remote_orgs":"create","default_tags":[{"name":"harvested"}]}'
ckan harvester source create mock-external-sdi-csw http://pycsw:8000/csw amconnect_csw \
  'Mock external SDI (CSW)' true mock-sdi MANUAL
```

A source is itself a CKAN dataset of type `harvest` (hidden from `/api/amconnect/search`),
with `url`, `source_type`, `frequency` (MANUAL, DAILY, WEEKLY, BIWEEKLY, MONTHLY, ALWAYS),
`config` (JSON) and an owner organisation. The admin UI is at `/harvest`.

**Lifecycle.** `harvest_job_create` -> gather (list remote ids, one `HarvestObject` per
record) -> fetch (get the record; the CKAN harvester already has it from the search) ->
import (`package_create`/`package_update`) -> `harvest_jobs_run` marks the job finished.
In production `ckan harvester run` (cron) creates jobs for due sources and two consumer
processes (`gather-consumer`, `fetch-consumer`) work the redis queue. For the demo,
`ckan amconnect harvest` runs the stages inline (the stock `harvester run-test` needs the
test extras pytest/factory-boy).

**Synchronisation (showcase 05).** CKAN harvester: after the first error-free job it asks the
remote only for `metadata_modified` since the last run; unchanged records are reported
"not modified", newer ones "updated" in place (same dataset id). **Deleted remote datasets
are not deleted locally** (the harvester only sees what the remote search returns). CSW
harvester: gather diffs the guid set (new / change / delete), unchanged documents (same
`metadata-date`) are skipped, **deleted records delete the local dataset**.

**Mapping.** CKAN harvester: the remote dict is imported almost as-is: tags, licence,
resources (`url_type` cleared), extras (including `spatial`, `country` ... which surface as
root fields through our show schema), organisation = the source's, or the remote one with
`remote_orgs: create`. CSW harvester: title/abstract, bbox -> `spatial`, keywords -> tags,
constraints, contacts, dates etc. as extras (`guid`, `metadata-date`, `responsible-party`,
`bbox-*`), and one resource per `CI_OnlineResource` with `resource_locator_protocol`
(`OGC:WMS` -> format `wms`, uppercased by our glue) and `resource_locator_function`.
The service URL is kept verbatim; the **layer name has no ISO home**, so our records carry
it as a URL fragment (`.../wms#amconnect:thailand_geology`, the ckanext-geoview convention)
and the glue copies it to `layer_name`.

**WMS/WFS/WCS resources in harvested datasets:** yes; both mock sources deliver them and the
capability layer treats them like any other resource (hosted vs federated decided per URL).

**A GeoServer harvester later?** Straightforward: `IHarvester` needs `gather_stage` (list
layers from GeoServer REST or WMS GetCapabilities), `fetch_stage` (no-op) and
`import_stage` (build the same dataset dict the seed builds). ~100 lines; `cli.py` already
contains the dict builder and `services.py` the capability probe.

## 3. ckanext-geoview as reference implementation

Tested on the hosted WMS/WFS resources and the external OSM WMS (the seed adds a `geo_view`
next to our view on every hosted WMS/WFS resource; both show as tabs on the resource page).

* **Detection:** by resource `format` (`wms wfs geojson kml gml ...`, configurable) or file
  extension; `can_view` also requires `resource_proxy` or a same-domain URL.
* **Resource structure:** `url` is the service endpoint; the WMS layer / WFS type name goes in
  the **URL fragment** (`url#layer`). Without it, geoview adds *all* layers of the service.
* **GetCapabilities:** read automatically through CKAN's proxy
  (`/dataset/<id>/resource/<rid>/service_proxy`), so no CORS is needed on the server, but the
  **server must be reachable from the CKAN process**: the hosted layer fails (502) in this
  Docker setup because CKAN cannot reach `localhost:8080`, while the external terrestris WMS
  works. GetMap tiles go straight to the server.
* **Feature inspection:** GetFeatureInfo via the proxy only; **extent:** zooms to the layer bbox
  from capabilities; **legend / opacity / ordering / downloads / WCS / analysis:** none.
* **What it taught us and we kept:** the `url#layer` convention as a fallback for
  `layer_name`, and the proxy idea (we probe server-side with OWSLib instead, on the internal
  URL). **What replaced it:** everything the AMConnect view needs (legend, capabilities,
  downloads, analysis, embedding). Nothing from the custom viewer could be removed; the custom
  viewer was rewritten as an API-driven component.

## 4. Resource / service model

No new schema beyond one resource field. A CKAN **resource is one service or file**:

| Field | Meaning |
|---|---|
| `format` | `WMS` / `WFS` / `WCS` / `WMTS` = service type; `GeoJSON`, `GeoTIFF`, `CSV`, `PDF` ... = downloadable file; anything else = link/API |
| `url` | service endpoint (base URL, OGC params stripped) or file URL |
| `layer_name` (extra) | OGC layer / feature type / coverage id. Fallbacks: legacy `wms_layer`, `url#layer`, `LAYERS=` in the URL, a `ws:name` resource name |

Derived, never stored: **service_type**, **hosted vs federated** (URL under our GeoServer or
not; harvested datasets are federated by definition), **downloadable vs view-only**
(from the live capability probe), **data kind** (WCS present -> raster, WFS -> vector,
WMS only -> unknown). Existing CKAN fields carry the rest: **source organisation** =
`organization` (harvested datasets keep their remote org), **access restrictions** = the
`access_level` extra (descriptive) plus CKAN's `private` flag (enforced), **licence**.

**One dataset, several services:** resources naming the same layer on the same host are
grouped into one *layer* by the API (`layers[]`, with `services.wms/wfs/wcs`). A dataset may
also carry unrelated resources (a PDF report, an external basemap WMS).

## 5. CKAN as API hub

Standard API stays available (`package_show`, `package_search` with `ext_bbox`), and a thin
facade hides CKAN's shape (`api.py`, ~150 lines, no storage):

```
GET /api/amconnect/datasets/<id>              dataset + layers + capabilities + links
GET /api/amconnect/datasets/<id>/services     layers / resources only
GET /api/amconnect/resources/<id>             one resource's service description
GET /api/amconnect/search?q=&country=&commodity=&data_type=&access_level=&organization=&tags=&origin=hosted|federated&limit=&offset=
GET /api/amconnect/spatial-search?bbox=minx,miny,maxx,maxy   (+ the same filters)
```

`?probe=false` skips the live GetCapabilities checks (lists do that by default). Access
control is CKAN's (actions run as the calling user). Dataset/service JSON, abridged:

```json
{
  "name": "thailand-geological-map", "title": "Thailand Geological Map",
  "organization": {"name": "amconnect", "title": "AMConnect"},
  "country": "Thailand", "commodity": "General Geology", "access_level": "public-view",
  "origin": "hosted", "mixed_origin": true, "harvest": null,
  "bbox": [97.35, 5.65, 105.6, 20.45], "spatial": {"type": "Polygon", "coordinates": [...]},
  "layers": [
    {"layer_name": "amconnect:thailand_geology", "title": "Geological units (local GeoServer WMS)",
     "origin": "hosted", "data_kind": "vector", "status": "ok", "view_only": false,
     "extent": [97.35, 5.65, 105.6, 20.45],
     "legend_url": "http://localhost:8080/geoserver/amconnect/ows?...GetLegendGraphic...",
     "services": {"wms": {"endpoint": "http://localhost:8080/geoserver/amconnect/wms", "status": "ok"},
                  "wfs": {"endpoint": "http://localhost:8080/geoserver/amconnect/wfs", "status": "ok",
                          "formats": ["application/json", "SHAPE-ZIP", "csv", "gml32", "KML", ...]}},
     "capabilities": {"view": true, "identify": true, "query": true, "download_vector": true,
                      "download_raster": false, "area_statistics": true, "feature_query": true,
                      "export_map_image": true, "federated": false},
     "downloads": [{"label": "GeoJSON", "url": ".../wfs?service=WFS&version=2.0.0&request=GetFeature&typeNames=amconnect:thailand_geology&outputFormat=application/json"},
                   {"label": "Shapefile (zip)", "url": "...&outputFormat=SHAPE-ZIP"}, "..."]},
    {"layer_name": "OSM-WMS", "origin": "federated", "data_kind": "unknown", "view_only": true,
     "capabilities": {"view": true, "identify": true, "federated": true, "export_map_image": true, "download_vector": false, "...": false},
     "downloads": []}
  ],
  "links": {"map": ".../dataset/thailand-geological-map/map", "embed": ".../map/embed", "services_api": "..."}
}
```

Hosted vs federated examples: `thailand-population-density-2020` (hosted raster: WMS+WCS,
`download_raster`, `area_statistics`), `malaysia-mineral-occurrences-mock` (harvested,
WMS-only: `view`, `identify`, `federated`, `view_only: true`), `world-countries-natural-earth`
(harvested WMS+WFS whose server returns 403 to server-side probes: `status: unreachable`,
downloads withheld rather than guessed).

## 6. Advanced analysis architecture

Flow exercised by the Analysis tab and showcase 11:

```
frontend --(1)--> CKAN  /api/amconnect/datasets/<id>/services   which layers, wcs/wfs endpoints, area_statistics flag
frontend --(2)--> GeoServer WCS GetCoverage&subset=Long()&subset=Lat()  (raster clip, GeoTIFF)  -> geotiff.js reduce
         --(2')-> GeoServer WFS GetFeature&bbox=...&outputFormat=json     (vector features)     -> count/area/breakdown
frontend --(3)--> renders table + "download this selection" links (same WCS/WFS URLs with subset/bbox)
```

* **Call GeoServer directly:** bbox statistics on one layer (what the POC does), feature
  queries (WFS filters/CQL), map exports, legend graphics, clip downloads.
* **Separate analysis service later:** polygon zonal statistics, cross-layer overlays,
  rasters beyond a few million pixels, analyses on federated view-only services (nothing to
  compute against), anything that must be stored, shared or audited. GeoServer WPS (with the
  `gs:RasterZonalStatistics`-style processes) or a small Python service (rasterio/shapely)
  next to GeoServer are the candidates; results would be published back as CKAN resources.
* **What CKAN needs to store:** nothing new. The capability model already answers
  "which analytical actions are available": `area_statistics` today; an analysis service
  would register itself as a resource (`format: API`, `url`) or as extra capability keys
  (`zonal_statistics`, `raster_summary`) derived from its own capabilities document.

## 7. Metadata synchronisation / ownership (recommended source-of-truth model)

| Item | Authoritative | Notes |
|---|---|---|
| Title, description, tags, ownership, country/commodity, access level, licence | **CKAN** | edited in CKAN (or arrives by harvest); the seed pushes title/abstract to GeoServer as convenience only |
| Spatial extent | **derived from GeoServer** into CKAN's `spatial` on publish; CKAN may override with a tighter polygon | harvested datasets: from the remote record |
| Service endpoints, layer names | **GeoServer** (facts) recorded in CKAN resources at publish time | the capability probe detects drift (`layer_not_found`, `unreachable`) |
| Styles, legends, queryable, output formats, native format | **GeoServer**, read live via GetCapabilities (cached 5 min) | never copied into CKAN |
| Existence of a layer | GeoServer | a GeoServer harvester (or `publish.sh` re-run) keeps CKAN in step |

CKAN remains the canonical **catalogue**; GeoServer is canonical for **service facts**. Changes
in GeoServer reach CKAN either by re-running the seed (`./publish.sh`), by the live probe
(status flags), or, later, by a GeoServer harvester on a schedule. Harvested external
datasets differ in that CKAN is *not* authoritative for anything: they are read-only copies
refreshed by the harvester (`harvest` block in the API says where from and when), and their
services are federated unless the URL happens to be ours.

## 8. Extension responsibility boundaries (assessment)

**ckanext-spatial**: solves extent storage, validation, spatial indexing, bbox discovery and
ISO/CSW ingest. Does not solve polygon queries, per-resource extents, schema mapping (hook
provided). **Keep.**

**ckanext-harvest**: solves the federation plumbing (sources, jobs, incremental CKAN sync,
scheduling, UI) and is the base every other harvester (CSW, future GeoServer) builds on. Does
not solve CKAN-source deletions or custom-schema mapping without a subclass; has a reindex bug
on 2.11 that does not affect harvested data. **Keep.**

**ckanext-geoview**: solves quick previews and shows the proxy pattern. Not usable as the
AMConnect viewer (no legend/downloads/WCS/analysis/embed, needs CKAN-reachable servers).
**Reference only** (harmless to keep enabled for admins).

**ckanext-amconnect** should remain custom: the five dataset fields and `layer_name`
(scheming could replace the form/schema part), `services.py` (capability model + probes),
`api.py` (facade), `harvesters.py` (~60 lines of glue), the GIS view, the seed/harvest CLI.
Removed in favour of standard extensions: the hand-rolled WMS detection module, the
CKAN-module map, any custom extent field or spatial query.

**GeoServer**: WMS/WFS/WCS, styles, legends, identify, clip/export. **PostGIS**: vector
storage and spatial SQL for hosted layers. **AMConnect frontend**: UX, auth, AMVest, map and
analysis UI driven by `capabilities`, direct OGC calls. **Future analysis service**: polygon
zonal stats, overlays, large rasters, stored results; registers as a resource/capability.

## Recommendation

**(b) CKAN as backend/API hub.** The experiments support it: spatial metadata and discovery,
federation from CKAN and CSW sources, and a frontend-oriented JSON facade all work with
standard extensions plus a small custom extension, and the GIS view in this POC already
consumes CKAN purely through that API. **Not (a)** main application: AMVest, registration
flows and a branded WebGIS would fight CKAN's page model and template overrides, and the
harvest/spatial UIs are admin-grade. **More than (c)** catalogue only: the capability model and
facade give the frontend something a bare catalogue does not (what can I do with this
resource), at very little code. Caveat: every extension needed a small compatibility fix on
CKAN 2.11 (listed above); budget for tracking upstream releases.

---

# The GIS view

One vanilla-JS component, `ckan/ckanext-amconnect/ckanext/amconnect/public/amconnect/amconnect-gis.js`
(+ `.css`), with OpenLayers 10 and geotiff.js from a CDN and **no CKAN dependency**. It is
mounted in four places:

| Where | Route / template | Notes |
|---|---|---|
| Dataset page "Map" tab | `/dataset/<id>/map` (`dataset_map.html`) | full-width page inside CKAN, tabs Overview / Map / Resources / Analysis |
| Standalone / embed | `/dataset/<id>/map/embed` (`embed.html`) | bare HTML shell; query `tab=`, `bbox=w,s,e,n`, `layers=<resource ids>`, `datasets=name,name` |
| Multi-dataset map | `/amconnect/map?datasets=name1,name2` | several catalogue datasets on one map (hosted and federated layers side by side) |
| Resource page view | `amconnect_wms_view` (`wms_view.html`) | compact mode, only that resource's layer |

The page contains nothing but a container; the component fetches
`/api/amconnect/datasets/<id>` (one call per dataset) and builds everything from that JSON.

**Visual style.** The view is styled as a survey map sheet: a dark "sheet margin" header with
a condensed title, stamped metadata and graticule ticks, paper-white panels with hairline
rules, monospaced coordinates and values. Tokens live at the top of `amconnect-gis.css`
(ink, paper, survey blue for actions, malachite for hosted/downloads, ochre for federated,
hematite for errors); fonts are Barlow Condensed, IBM Plex Sans and IBM Plex Mono from Google
Fonts with system fallbacks. Layer cards carry a coloured left edge for hosted (green) or
federated (ochre) origin.

**WebGIS features**

- **Layers panel**: visibility, ordering (up/down), opacity, hosted/federated and
  vector/raster/WMS-only badges, per-layer download menu, loading spinner and tile-error badge,
  dataset attribution when several datasets are loaded, remove.
- **Add layer from the catalogue**: "+ Add layer" calls `/api/amconnect/spatial-search` with the
  current map view (re-runs as you pan) and adds any listed dataset's layers to the map. This is
  the CKAN-as-hub story on one screen.
- **Basemaps**: OpenStreetMap, Esri light/dark gray, Esri topographic, Esri satellite, none.
- **Legend panel**: for hosted layers the legend is built from GeoServer's JSON
  `GetLegendGraphic` (rule swatches for polygons/lines/points, a colour ramp for rasters with
  transparent "nodata" entries dropped); other servers show their PNG legend. A dropdown picks
  which layer's legend is shown (or all). Plus scale bar, cursor coordinates, fullscreen, zoom
  to dataset extent.
- **Symbology switching ("Show as")**: when the WMS advertises several styles for a layer, the
  layer card offers a dropdown; switching sets the WMS `STYLES` parameter and re-reads the legend.
  Alternate styles are published by the seed from `geoserver/styles/<layer>__<variant>.sld`
  (mineral sites by commodity / status / grade, population density as ramp / 5 classes, geology
  by rock class / age). The API lists them under `layers[].styles[]` with titles and legend URLs,
  and the permalink keeps the chosen style per layer.
- **Identify**: click → WMS GetFeatureInfo (JSON) → popup at the click point with the attributes,
  the feature outline highlighted from the returned geometry; rasters show the pixel value.
  Servers without CORS/JSON get a link to the raw response instead.
- **Compare**: swipe slider clipping the top visible layer against the layers below.
- **Analysis tab** (same map, different side panel): target layer, **box or polygon selection**.
  Rasters: WCS clip (bbox) then pixels outside the polygon are masked client-side; count, min/max,
  mean/median, std, sum, valid area, Σ value×area, a 16-bin **histogram**, and a "download this
  selection" GeoTIFF link. Vectors: WFS `bbox` or `CQL_FILTER=INTERSECTS(<geom>, SRID=3857;POLYGON(...))`
  (the geometry attribute comes from DescribeFeatureType JSON); count, area, Σ of numeric fields,
  a **category bar chart**, GeoJSON download of the selection, "highlight on map".
- **Query features**: attribute / operator / value builder (attributes and types from
  DescribeFeatureType), optional "only in current view", runs a WFS `CQL_FILTER`, highlights the
  result, zooms to it and offers GeoJSON / Shapefile / CSV downloads of exactly that filter.
- **Share**: permalink with the whole state in the URL hash (`view`, `base`, `layers` with
  visibility and opacity, `datasets`, `sel` box, `poly` polygon, `q` query, `tab`), copy-able
  iframe embed code, and **PNG export** of the current map (canvas export; a federated layer
  without CORS makes the browser refuse, which the UI explains).

Deep links used in the demo:

```
/dataset/thailand-population-density-2020/map/embed?tab=analysis&bbox=100.3,13.5,100.9,14.0
/dataset/thailand-population-density-2020/map/embed#poly=100.2,13.4;101.0,13.3;101.1,14.2;100.4,14.3&base=satellite
/dataset/thailand-geological-map/map/embed#q=rock_class:=:Sedimentary&layers=OSM-WMS:0:100,amconnect%3Athailand_geology:1:100
/amconnect/map?datasets=thailand-geological-map,thailand-population-density-2020#base=light
```

**Embedding.** `<iframe src=".../map/embed?tab=map">` for the demo, or include the two static
files and call `new AmconnectGIS(el, {api: '.../api/amconnect/datasets/<id>'})` (or
`{datasets: ['a', 'b']}`) from any page (enable CORS on CKAN for cross-origin API calls). The
future frontend can copy the component or reimplement it against the same JSON; nothing couples
it to iframes. Showcase 10 prints the snippets.

**Hosted vs federated layers** are distinguished by the `origin` badge, derived from the
service URL (our GeoServer or not) and harvest provenance; federated layers load without
`crossOrigin` unless the server advertises CORS, get identify only if their WMS says
`queryable`, and never get downloads unless a reachable WFS/WCS advertises formats.

# Download / resource access

The old single "Download" button is gone. For every resource `services.describe_resource`
combines **CKAN metadata** (format, endpoint, `layer_name`, dataset origin) with a **live,
cached GetCapabilities probe** (OWSLib, on the internal URL for our GeoServer):

| Resource | Probe checks | Offered |
|---|---|---|
| WFS | type exists, `outputFormat` values, CORS header | Download GeoJSON / GML 3.2 / CSV / Shapefile (zip) / KML, each only if advertised; `query`, `feature_query`, `area_statistics` |
| WCS | coverage exists (`ws__layer`), `formatSupported` | Download GeoTIFF (`format=image/tiff`), native (no format param), PNG; `area_statistics`; clip via `subset=` |
| WMS | layer exists, `queryable`, bbox, legend | View on map, Identify, Export map image (GetMap of the extent, clearly a picture), View source; **"View only"** badge when no sibling WFS/WCS exists |
| file (GeoJSON, GeoTIFF, CSV, PDF ...) | none | Download |
| unreachable / layer missing | probe failed | status badge, no download buttons |

URLs are built from the resource's registered endpoint and layer name, never from file
paths (`wfs_download_url`, `wcs_download_url` in `services.py`). The CKAN resource page and
the dataset resource list use the same helper (`amconnect/snippets/resource_actions.html`,
`resource_item.html`); a WMS resource shows the downloads of its sibling WFS/WCS.
Actions from **CKAN metadata**: which services exist, hosted/federated, view. Actions from
**GeoServer capabilities**: identify, download formats, area statistics, extent, legend.
A GeoNode deployment keeps the abstraction: CKAN describes the services, the frontend renders
from `capabilities`.

# Known limitations

- Not hardened: default passwords, HTTP, one host, public GeoServer; `access_level` is a label,
  only CKAN's `private` flag is enforced, and nothing propagates to GeoServer security.
- Spatial queries are bbox-only (ckanext-spatial exposes `ext_bbox`); no per-resource extent.
- Capability probes are server-side with an 8 s timeout and a 5 min in-memory cache per
  process; some public servers refuse non-browser clients (ahocevar.com: 403), which the API
  reports as `unreachable` instead of guessing.
- `harvest_source_reindex` fails with `KeyError ('extras', 0, 'id')` on ckanext-harvest 1.6.2 +
  CKAN 2.11.6 (jobs finish; the `/harvest` listing counts may be stale). `ckan harvester run`
  from cron would log the same error each cycle until fixed upstream.
- The CKAN harvester does not delete datasets removed at the source; the CSW harvester does.
  A CSW second run reports unchanged records as "added" (cosmetic: the previous object is
  reused).
- ISO 19139 has no field for the layer name; our records use the `url#layer` fragment.
- geoview's proxy needs service URLs reachable from the CKAN container; the hosted layer's
  public URL (`localhost:8080`) is not, so geoview only works for external services here.
- Statistics are computed in the browser: rasters are clipped by bbox and masked by the polygon
  client-side (downsampled above 2 M pixels), vector areas are those of the intersecting
  features, not clipped to the shape; a server-side analysis service is the production path.
- Basemaps come from public tile services (OSM, Esri); check their terms before a public
  deployment. PNG export fails when a layer without CORS is visible.
- The CKAN page is not full-width (Bootstrap container); the embed page is.
- OpenLayers/geotiff.js from a CDN; vendor them for offline use. Browser must reach the
  service URLs (set `GEOSERVER_PUBLIC_URL` behind a proxy and re-run the seed).
- Synthetic example vector; rasters uploaded over HTTP (fine for MBs).

# The CKAN extension: `ckanext-amconnect`

| Piece | File |
|---|---|
| Dataset fields (country, commodity, data_type, access_level, spatial), `layer_name` resource field | `plugin.py`, `templates/package/snippets/*` |
| Service/capability model, probes, download URL builders | `services.py` |
| `/api/amconnect/*` | `api.py` |
| GIS view routes (`/map`, `/map/embed`) | `views.py`, `templates/amconnect/*` |
| GIS component | `public/amconnect/amconnect-gis.js`, `.css` |
| Capability-aware buttons on resource pages | `templates/amconnect/snippets/resource_actions.html`, `templates/package/resource_read.html`, `templates/package/snippets/resource_item.html` |
| Harvest glue: `amconnect_ckan`, `amconnect_csw` source types, `ISpatialHarvester` mapping | `harvesters.py` |
| `ckan amconnect seed | harvest | extent` | `cli.py` |

Plugins enabled: `spatial_metadata spatial_query harvest geo_view geojson_view resource_proxy
amconnect amconnect_wms_view amconnect_ckan_harvester amconnect_csw_harvester`. The extension
source is bind-mounted: templates/JS/Python changes need `docker compose restart ckan`,
Dockerfile or entry-point changes need `docker compose build ckan`. Configuration:
`ckanext.amconnect.geoserver_public_url`, `geoserver_internal_url`, `geoserver_workspace`,
`data_dir` (see `docker-compose.yml`).

# Where GeoNode would fit (later phase)

Nothing here depends on GeoServer specifically: CKAN stores service endpoints and layer names,
the capability probe speaks plain OGC, and the harvest glue already ingests ISO records.
A GeoNode-backed layer is a WMS/WFS/WCS resource on GeoNode's GeoServer, and GeoNode's CSW
would be one more `amconnect_csw` harvest source. GeoNode adds what this POC lacks
operationally: self-service upload, layer metadata editing, in-browser styling, per-layer
permissions synced to GeoServer, saved maps. If those are required, add GeoNode as a third
tier; CKAN keeps its role as catalogue/API hub.
