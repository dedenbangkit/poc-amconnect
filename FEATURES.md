# AMConnect POC: feature summary

Everything the POC does today, grouped by component, with the API and the deep links you
need to reproduce each feature. The evaluation and reasoning behind it are in
[README.md](README.md); this file is the inventory.

Stack: CKAN 2.11.6 + ckanext-spatial 2.3.2 + ckanext-harvest 1.6.2 + ckanext-geoview 0.3.1 +
ckanext-amconnect (custom), GeoServer 2.26 + PostGIS, Solr (spatial image), Redis, two mock
federation sources (mock CKAN API, pycsw CSW). `docker compose up -d --build` starts all of it.

---

## 1. Who serves what

| Feature | Served by | Notes |
|---|---|---|
| Dataset catalogue, organisations, tags, licences, users, search UI, action API (`/api/3`) | **CKAN core** | unchanged |
| AMConnect dataset fields: `country`, `commodity`, `data_type`, `access_level`, `spatial` | **ckanext-amconnect** (`plugin.py`, IDatasetForm) | stored as extras, exposed as root keys |
| `layer_name` resource field (OGC layer / feature type / coverage id) | **ckanext-amconnect** | fallbacks: legacy `wms_layer`, `url#layer`, `LAYERS=` param, `ws:name` resource name |
| Spatial extent validation (GeoJSON in `spatial`) | **ckanext-spatial** `spatial_metadata` | rejects invalid GeoJSON on create/update |
| Spatial index + `ext_bbox` search | **ckanext-spatial** `spatial_query` (backend `solr-spatial-field`) | Solr image `ckan-solr:2.11-solr9-spatial` |
| Dataset extent map in the sidebar, draw-a-box filter on `/dataset` | **ckanext-spatial** templates | wired in by our `read_base.html` |
| Extent derived from GeoServer at publish time | **ckanext-amconnect** `cli.py` (`ckan amconnect seed`, `ckan amconnect extent`) | reads WMS GetCapabilities bbox |
| Harvest sources, jobs, objects, queue, scheduling (`frequency`), `/harvest` admin UI | **ckanext-harvest** | `ckan db upgrade -p harvest`, redis queue |
| CKAN-to-CKAN harvesting | **ckanext-harvest** CKAN harvester, subclassed as `amconnect_ckan` | subclass keeps AMConnect extras and normalises service resources |
| CSW / ISO 19139 harvesting | **ckanext-spatial** CSW harvester, subclassed as `amconnect_csw` | subclass strips the XML declaration pycsw returns; `ISpatialHarvester` hook maps ISO to our fields |
| Synchronous harvest run for demos | **ckanext-amconnect** `ckan amconnect harvest` | production: `ckan harvester run` + gather/fetch consumers |
| Generic OGC/GeoJSON resource previews inside CKAN | **ckanext-geoview** `geo_view`, `geojson_view` | reference only; the seed attaches a `geo_view` to hosted WMS/WFS resources; needs `resource_proxy`, layer name as `url#layer` (the seed writes hosted URLs that way) |
| Resource -> service/capability model, live GetCapabilities probes, download URL builders | **ckanext-amconnect** `services.py` | OWSLib, 5-minute cache, internal GeoServer URL for probes |
| `/api/amconnect/*` facade | **ckanext-amconnect** `api.py` | thin wrapper over `package_show` / `package_search` |
| GIS view (Map tab, embed page, multi-dataset map, resource view) | **ckanext-amconnect** `public/amconnect/amconnect-gis.js` + `.css`, `views.py`, templates | vanilla JS, OpenLayers 10, geotiff.js, no CKAN JS |
| Capability-aware buttons on CKAN resource pages and dataset resource lists | **ckanext-amconnect** templates (`resource_read.html`, `resource_item.html`, `snippets/resource_actions.html`) | |
| WMS rendering, GetFeatureInfo, legends (PNG + JSON), alternate styles | **GeoServer** | styles from `geoserver/styles/*.sld` |
| WFS queries (bbox, CQL), vector downloads (GeoJSON, GML, CSV, Shapefile, KML), DescribeFeatureType | **GeoServer** | |
| WCS raster download, clip (`subset=`), scaling | **GeoServer** | coverage id = `ws__layer` |
| Vector storage | **PostGIS** | rasters stay as files in GeoServer's data dir |
| Publishing files: vector -> PostGIS + feature type, raster -> coverage store, styles, alternate styles | **geoserver-seed** (`geoserver/seed/seed.py`) + `publish.sh` | drop folder `geoserver/data/` |

---

## 2. Data model

**Dataset** (CKAN package) = the catalogue record. Custom fields: `country`, `commodity`,
`data_type` (geospatial / tabular / document / other), `access_level` (public-view /
public-download / restricted / internal), `spatial` (GeoJSON geometry). Everything else is
standard CKAN (title, notes, tags, organisation, licence, `private`).

**Resource** = one service or file:

| Field | Meaning |
|---|---|
| `format` | `WMS` / `WFS` / `WCS` / `WMTS` = OGC service; `GeoJSON`, `GeoTIFF`, `CSV`, `PDF`, ... = downloadable file; anything else = link / API |
| `url` | service endpoint (base URL) or file URL |
| `layer_name` | OGC layer, feature type or coverage name (service resources only) |

Derived, never stored: `service_type`, `origin` (hosted = URL on our GeoServer, federated =
anything else or harvested), `data_kind` (WCS -> raster, WFS -> vector, WMS only -> unknown),
`view_only`, `capabilities`, `downloads`, `styles`, `extent`, `legend_url`, `status`
(ok / unreachable / layer_not_found / not_probed).

**Layer** (API-level grouping) = all resources of a dataset that name the same layer on the
same host, e.g. WMS + WFS of `amconnect:thailand_geology`, with merged capabilities.

**Capability keys**: `view`, `identify`, `query`, `download_vector`, `download_raster`,
`area_statistics`, `feature_query`, `export_map_image`, `federated`.

Seeded example data:

| Dataset | Kind | Services | Styles ("Show as") |
|---|---|---|---|
| `thailand-geological-map` | synthetic polygons (+ external OSM WMS) | WMS + WFS | rock class, age |
| `thailand-population-density-2020` | WorldPop raster | WMS + WCS | continuous ramp, 5 classes |
| `thailand-mineral-sites` | 200 synthetic points | WMS + WFS | commodity, status, grade (graduated) |
| `world-countries-natural-earth`, `malaysia-mineral-occurrences-mock` | harvested from mock CKAN | WMS+WFS (partner blocks probes), WMS-only + PDF | |
| `openstreetmap-basemap-...`, `thailand-geological-units-via-partner-geoserver-...` | harvested from mock CSW | WMS-only, WMS+WFS | |
| `lao-mineral-map-ccop` | catalogue-only record for a real partner service (CCOP GSi MapServer WMS, Lao PDR mineral map) | WMS only (queryable, legend, no CORS) | |

---

## 3. API

### Standard CKAN (unchanged)

```
GET /api/3/action/package_show?id=<name>
GET /api/3/action/package_search?q=...&fq=country:Thailand&ext_bbox=minx,miny,maxx,maxy
GET /api/3/action/resource_show?id=<id>
GET /api/3/action/harvest_source_list / harvest_job_list ...   (ckanext-harvest, auth needed)
```

### AMConnect facade (`ckanext-amconnect/api.py`)

| Endpoint | Returns |
|---|---|
| `GET /api/amconnect/` | endpoint list and capability keys |
| `GET /api/amconnect/datasets/<id>` | flat metadata, `origin`, `harvest` block, `spatial` + `bbox`, `layers[]` (grouped services, capabilities, downloads, styles, legend, extent), `resources[]`, `capabilities` (merged), `links` |
| `GET /api/amconnect/datasets/<id>/services` | just `layers[]`, `resources[]`, `capabilities`, `bbox` |
| `GET /api/amconnect/resources/<id>` | one resource's service description |
| `GET /api/amconnect/search?q=&country=&commodity=&data_type=&access_level=&organization=&tags=&origin=hosted\|federated&limit=&offset=&sort=` | simplified results + facets + the Solr `fq` used |
| `GET /api/amconnect/spatial-search?bbox=minx,miny,maxx,maxy` (+ the same filters) | same shape, filtered with ckanext-spatial's `ext_bbox` |

Options: `?probe=false` skips the live GetCapabilities checks on single-dataset calls (lists
skip them by default, `?probe=true` enables). Auth is CKAN's: private datasets are invisible to
anonymous callers.

Layer JSON, abridged:

```json
{"layer_name": "amconnect:thailand_mineral_sites", "title": "Mineral sites (WMS)",
 "origin": "hosted", "data_kind": "vector", "status": "ok", "view_only": false,
 "extent": [97.5, 5.9, 105.5, 20.4],
 "legend_url": "http://localhost:8080/geoserver/amconnect/ows?...GetLegendGraphic...",
 "styles": [{"name": "thailand_mineral_sites", "title": "Mineral sites by commodity", "legend_url": "..."},
            {"name": "thailand_mineral_sites_status", "title": "Mineral sites by status", "legend_url": "..."}],
 "services": {"wms": {"endpoint": "http://localhost:8080/geoserver/amconnect/wms", "status": "ok"},
              "wfs": {"endpoint": "http://localhost:8080/geoserver/amconnect/wfs", "formats": ["application/json", "SHAPE-ZIP", "csv", "..."]}},
 "capabilities": {"view": true, "identify": true, "query": true, "download_vector": true, "area_statistics": true,
                  "feature_query": true, "export_map_image": true, "download_raster": false, "federated": false},
 "downloads": [{"label": "GeoJSON", "url": ".../wfs?...&outputFormat=application/json"}, {"label": "Shapefile (zip)", "url": "..."}]}
```

---

## 4. GIS view

Component: `ckan/ckanext-amconnect/ckanext/amconnect/public/amconnect/amconnect-gis.js` (+ `.css`).
Vanilla JS; only OpenLayers 10 and geotiff.js (CDN). It fetches the AMConnect API and builds
everything from that JSON. Reusable by a non-CKAN frontend:
`new AmconnectGIS(el, {api: '/api/amconnect/datasets/<id>'})` or `{datasets: ['a', 'b']}`.

### Routes

| Route | What |
|---|---|
| `/dataset/<id>/map` | inside CKAN, full width, tabs Overview / Map / Resources / Analysis |
| `/dataset/<id>/map/embed` | bare page for `<iframe>` (query: `tab=`, `bbox=`, `layers=<resource ids>`, `datasets=name,name`) |
| `/amconnect/map?datasets=name1,name2` | several datasets on one map |
| resource page "Map preview" view (`amconnect_wms_view`) | compact mode, that resource's layer only |

### Tabs

- **Overview**: description, organisation, origin (hosted / federated + harvest source),
  country, commodity, data type, access level, licence, extent, last modified, tags,
  capability chips.
- **Map**: layers panel + map (below).
- **Resources**: every resource with capability-aware buttons (View on map, Query features,
  Area statistics, Download <format>, Export map image, View source, Open) and badges
  (hosted/federated, view only, unreachable, layer not found).
- **Analysis**: same map, analysis panel (below).

### Layers panel

- Visibility toggle, order (up/down), opacity slider, zoom to layer extent, remove (for
  added datasets).
- Badges: Hosted / Federated, Vector / Raster / WMS only, Identify (queryable), service
  status; dataset attribution when several datasets are loaded.
- Per-layer download menu (only formats the service advertises); "View only" otherwise.
- **Show as**: symbology dropdown when the WMS advertises several styles (sets WMS `STYLES`,
  refreshes the legend).
- **+ Add layer**: `spatial-search` on the current map view (re-runs on pan), adds any
  listed dataset's layers.

### Map tools (toolbar)

- Basemap: OpenStreetMap, Esri light gray, dark gray, topographic, satellite, none.
- Extent (zoom to dataset), Identify toggle, Box / Polygon selection, Compare (swipe slider
  clipping the top layer), Share, Fullscreen, Clear.
- Identify: WMS GetFeatureInfo (JSON) -> popup at the click with attributes, feature outline
  highlighted; rasters show the pixel value; servers without CORS/JSON get a raw-response link.
- Legend panel: dropdown to choose which layer's legend (or all); hosted layers rendered from
  GeoServer's JSON legend (swatches, colour ramp or classified rows, transparent entries
  dropped, marker shapes kept), other servers via PNG; collapsible.
- Scale bar, cursor coordinates, per-layer loading spinner and tile-error badge.

### Analysis panel

- Target layer selector + **Show as** style dropdown for it.
- **Box or polygon selection**:
  - raster: WCS clip by bbox, polygon mask client-side, downsampling above 2 M pixels;
    pixels, valid pixels, min/max, mean/median, std, sum, valid area, Σ value×area, 16-bin
    histogram, "download this selection" GeoTIFF link;
  - vector: WFS `bbox` or `CQL_FILTER=INTERSECTS(<geom>, SRID=3857;POLYGON(...))`; feature
    count, area (polygons), Σ/mean of numeric fields (ids and years skipped), category bar
    chart, GeoJSON download of the selection, "highlight on map".
- **Query features**: attribute / operator / value builder (attributes and types from
  DescribeFeatureType JSON), "only in current view", WFS `CQL_FILTER`, result highlighted and
  zoomed, downloads as GeoJSON / Shapefile / CSV of that filter.

### Share

- Permalink: state in the URL hash: `view=lon,lat,zoom`, `base=`, `layers=<name>:<visible>:<opacity>[:<style>],...`,
  `datasets=`, `sel=w,s,e,n` (box), `poly=lon,lat;...` (polygon), `q=attr:op:value`, `tab=`.
- Copy-able iframe embed code.
- PNG export of the current map (fails, with an explanation, when a layer without CORS is visible).

Deep links that exercise the features:

```
/dataset/thailand-population-density-2020/map/embed?tab=analysis&bbox=100.3,13.5,100.9,14.0
/dataset/thailand-population-density-2020/map/embed#poly=100.2,13.4;101.0,13.3;101.1,14.2;100.4,14.3&base=satellite
/dataset/thailand-geological-map/map/embed#q=rock_class:=:Sedimentary&layers=OSM-WMS:0:100,amconnect%3Athailand_geology:1:100
/dataset/thailand-mineral-sites/map/embed?tab=analysis&bbox=99,12,102,16#layers=amconnect%3Athailand_mineral_sites:1:100:thailand_mineral_sites_grade
/amconnect/map?datasets=thailand-mineral-sites,thailand-population-density-2020#base=light&layers=amconnect%3Athailand_mineral_sites:1:100:thailand_mineral_sites_status,amconnect%3Atha_pd_2020_1km_UNadj:1:80:tha_pd_2020_1km_UNadj_classes
```

---

## 5. Downloads and capability detection

Per resource, `services.describe_resource` combines CKAN metadata (format, endpoint,
`layer_name`, origin) with a cached GetCapabilities probe:

| Resource | Probe checks | Offered |
|---|---|---|
| WFS | type exists, `outputFormat` values, CORS | GeoJSON, GML 3.2, CSV, Shapefile zip, KML (only if advertised); query, feature_query, area_statistics |
| WCS | coverage exists, `formatSupported` | GeoTIFF, native, PNG; area_statistics; clip via `subset=` |
| WMS | layer exists, queryable, bbox, legend, styles | View, Identify, Export map image (GetMap, a picture), View source; "View only" when no sibling WFS/WCS |
| file | none | Download |
| unreachable / missing layer | probe failed | status badge, no download buttons |

A WMS resource page shows the downloads of its sibling WFS/WCS. URLs are built from the
registered endpoint + layer name (`wfs_download_url`, `wcs_download_url`), never from file paths.

---

## 6. Spatial (ckanext-spatial)

- Storage: dataset extra `spatial` (GeoJSON), declared by our schema, validated by the extension.
- Derivation: seed reads the layer bbox from GeoServer WMS GetCapabilities (sidecar `spatial`
  overrides). `ckan amconnect extent amconnect:<layer>` prints it.
- Index/query: Solr `spatial_geom` (JTS), `package_search?ext_bbox=...`, wrapped by
  `/api/amconnect/spatial-search`. Bbox input only; intersection against the real polygon.
- UI: sidebar extent map on dataset pages, box filter on `/dataset`.

## 7. Harvesting (ckanext-harvest + ckanext-spatial harvesters)

- Sources registered by the seed: `mock-asean-ckan` (type `amconnect_ckan`, container
  `mock-ckan`, edit `harvest-sources/mock-ckan/datasets.json`) and `mock-external-sdi-csw`
  (type `amconnect_csw`, container `pycsw`, records in `harvest-sources/pycsw/records/`).
- Run: `docker compose exec ckan ckan -c /srv/app/ckan.ini amconnect harvest [source]`
  (gather -> fetch -> import inline). Also runs once at container start.
- Behaviour: CKAN source updates changed records (by `metadata_modified`), does not delete;
  CSW source updates changed records (by `metadata-date`) and deletes removed ones.
- Mapping: extras (`spatial`, `country`, ...) surface as root fields; resources keep
  `format`/`url`/`layer_name`; ISO online resources become WMS/WFS resources with
  `resource_locator_protocol`; remote organisations are created (`remote_orgs: create`).
- Harvested datasets are `origin: federated` and carry a `harvest` block in the API.

## 8. Publishing and CLI

```
./publish.sh <file.tif|.geojson|.gpkg> [--title ...] [--force]   # copy to drop folder, GeoServer seed, CKAN seed
geoserver/data/<name>.json         sidecar: name, title, notes, country, commodity, data_type, access_level, spatial, tags, resource_name, extra_resources
geoserver/styles/<name>.sld        default style
geoserver/styles/<name>__<v>.sld   alternate style "<name>_<v>" (WMS STYLES), shows up in "Show as"
geoserver/data/external/<slug>.json  catalogue-only federated record: same keys + "resources" list (partner WMS etc.)

ckan amconnect seed [--no-harvest-sources]   datasets from the drop folder + harvest sources
ckan amconnect harvest [source]              run harvest sources synchronously
ckan amconnect extent <ws:layer>             extent GeoServer reports
ckan harvester sources | jobs | source clear <id> | run | gather-consumer | fetch-consumer
```

## 9. Showcase scripts (`showcase/`)

01 spatial extent · 02 spatial search · 03 CKAN harvest · 04 CSW harvest · 05 harvest
lifecycle (update/delete) · 06 geoview reference · 07 API dataset · 08 API services ·
09 API search · 10 embed/deep links · 11 analysis with curl (WCS clip, WFS bbox, CQL polygon,
attribute query) · 12 resource capabilities · 13 vector download · 14 raster download.

## 10. Known limitations (short)

- Bbox-only spatial queries; no per-resource extent.
- Browser-side analysis: bbox clip + polygon mask, vector areas not clipped; large rasters
  downsampled; federated view-only services cannot be analysed.
- `harvest_source_reindex` KeyError on ckanext-harvest 1.6.2 + CKAN 2.11 (jobs still finish).
- geoview needs service URLs reachable from the CKAN container (hosted `localhost:8080` is not).
- Public basemap tile services (OSM, Esri) and CDN scripts; PNG export needs CORS on every
  visible layer.
- Not hardened: default credentials, HTTP, public GeoServer, `access_level` is descriptive only.
