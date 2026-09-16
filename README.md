# AMConnect POC: CKAN portal + GeoServer/PostGIS WebGIS

Proof of concept for the AMConnect architecture. The question it answers:

> Can CKAN act as the unified, user-facing data portal while GeoServer (on
> PostGIS) provides the WebGIS capability, with map previews rendered
> inside CKAN straight from WMS?

The flow that works end to end:

```
CKAN dataset  ->  click "Map" tab (or open the WMS resource)  ->  map appears
                                                                   |
                                     tiles come from GeoServer WMS  (local layer)
                                     and from an external WMS       (federated layer)
```

This is **not** production-ready. GeoNode is deliberately left out (see the last section).

## Stack

| Service          | Image                              | Role                                                       |
|------------------|------------------------------------|------------------------------------------------------------|
| `ckan`           | built from `ckan/ckan-base:2.11`   | Data portal + `ckanext-amconnect`                          |
| `db`             | `postgres:16-alpine`               | CKAN database                                              |
| `solr`           | `ckan/ckan-solr:2.11-solr9`        | CKAN search index (required by CKAN 2.11)                  |
| `redis`          | `redis:7-alpine`                   | CKAN job queue / cache (required by CKAN 2.11)             |
| `geoserver`      | `docker.osgeo.org/geoserver:2.26.2`| OGC WMS/WFS server                                         |
| `postgis`        | `postgis/postgis:16-3.4`           | GeoServer's spatial database                               |
| `geoserver-seed` | built from `ghcr.io/osgeo/gdal`    | One-shot job: publishes every file in `geoserver/data/` (vector -> PostGIS, raster -> GeoServer) |

```
poc-amconnect/
├── docker-compose.yml
├── .env                         # ports, credentials, WMS URLs
├── publish.sh                   # publish one file end to end (GeoServer + CKAN)
├── ckan/
│   ├── Dockerfile               # ckan-base + ckanext-amconnect
│   ├── docker-entrypoint.d/     # runs `ckan amconnect seed` on start
│   └── ckanext-amconnect/       # the CKAN extension (see below)
└── geoserver/
    ├── data/                    # DROP FOLDER: <name>.geojson|gpkg|shp|tif + <name>.json sidecar
    │   ├── thailand_geology.geojson / .json      # example vector (synthetic, illustrative)
    │   └── tha_pd_2020_1km_UNadj.tif / .json     # example raster (WorldPop population density)
    ├── styles/<name>.sld        # optional style per layer, applied as default
    └── seed/seed.py             # publishes the drop folder via GeoServer REST
```

## Run it

Requirements: Docker with Compose v2, roughly 4 GB RAM free, ports 5000 and 8080 free.

```bash
cp .env.example .env        # ports, credentials, public WMS URL; edit if needed
docker compose up -d --build
```

First start takes a few minutes: CKAN initialises its DB and Solr, GeoServer
boots, then the two seed jobs run. Watch progress with:

```bash
docker compose logs -f ckan geoserver-seed
```

You are done when you see `dataset thailand-geological-map: created` in the
CKAN log and `[seed] done` in the geoserver-seed log.

Reset everything (drops all volumes):

```bash
docker compose down -v
```

## Service URLs

| What                         | URL                                                                          |
|------------------------------|------------------------------------------------------------------------------|
| CKAN portal                  | http://localhost:5000                                                        |
| Example dataset              | http://localhost:5000/dataset/thailand-geological-map                        |
| Example dataset, Map tab     | http://localhost:5000/dataset/thailand-geological-map/map                    |
| Raster example, Map tab      | http://localhost:5000/dataset/thailand-population-density-2020/map           |
| CKAN API                     | http://localhost:5000/api/3/action/package_show?id=thailand-geological-map   |
| GeoServer admin UI           | http://localhost:8080/geoserver/web/                                         |
| GeoServer WMS (local layer)  | http://localhost:8080/geoserver/amconnect/wms                                |
| GeoServer Layer Preview      | http://localhost:8080/geoserver/amconnect/wms?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=amconnect:thailand_geology&SRS=EPSG:4326&BBOX=97,5,106,21&WIDTH=512&HEIGHT=768&FORMAT=image/png |
| External WMS (federated)     | https://ows.terrestris.de/osm/service (layer `OSM-WMS`)                      |

PostgreSQL and PostGIS are not published on the host. Reach them with
`docker compose exec db psql -U ckan` or `docker compose exec postgis psql -U gis`.

## Default credentials

All of these live in `.env` (copied from `.env.example`).

| Service    | User    | Password     |
|------------|---------|--------------|
| CKAN       | `admin` | `admin12345` |
| GeoServer  | `admin` | `geoserver`  |
| CKAN DB    | `ckan`  | `ckan`       |
| PostGIS    | `gis`   | `gis`        |

## What is seeded

Everything in `geoserver/data/` becomes a GeoServer layer `amconnect:<name>` and a
CKAN dataset (see "Publishing your own data" for the convention). Two examples ship:

**Dataset `thailand-geological-map`** in organisation `AMConnect`:

| Field          | Value             |
|----------------|-------------------|
| `country`      | Thailand          |
| `commodity`    | General Geology   |
| `data_type`    | geospatial        |
| `access_level` | public-view       |

Two resources, both with format `WMS`:

1. **Geological units (local GeoServer WMS)**: `http://localhost:8080/geoserver/amconnect/wms`,
   layer `amconnect:thailand_geology`. Served by GeoServer from the PostGIS table
   `thailand_geology`, styled by `rock_class`.
2. **OpenStreetMap (external WMS, terrestris)**: `https://ows.terrestris.de/osm/service`,
   layer `OSM-WMS`. A third-party server, nothing in this stack hosts it. This is the
   federated-data example.

The GeoJSON is **synthetic**: a Voronoi tessellation clipped to a rough Thailand
outline, with plausible unit names and ages attached. It demonstrates the pipeline,
not real geology.

**Dataset `thailand-population-density-2020`**: WorldPop 2020 population density,
1 km, UN adjusted (`tha_pd_2020_1km_UNadj.tif`, Float32, nodata -99999). Served by
GeoServer as coverage `amconnect:tha_pd_2020_1km_UNadj` with a log-like colour ramp
(`geoserver/styles/tha_pd_2020_1km_UNadj.sld`). Rasters stay as files in GeoServer's
data directory; only vectors go into PostGIS.

## Publishing your own data

```bash
./publish.sh path/to/my_layer.tif --title "My layer"      # GeoTIFF
./publish.sh path/to/my_layer.geojson                     # GeoJSON / GeoPackage
```

What it does:

1. Copies the file into `geoserver/data/` (and `my_layer.sld` next to it into
   `geoserver/styles/`, if present).
2. Writes `geoserver/data/my_layer.json` if it does not exist yet. Edit it and re-run
   to change the CKAN metadata.
3. Runs the GeoServer seed job (`docker compose run --rm geoserver-seed`), which
   publishes every file in the folder: vectors through ogr2ogr into PostGIS and a
   feature type, rasters uploaded through the REST API into a coverage store. Layers
   that already exist are updated; raster uploads are skipped unless `--force`.
4. Runs `ckan amconnect seed`, which creates or updates one dataset per file using
   the sidecar, with a WMS resource pointing at `amconnect:<name>`.

The same two seeds run automatically at `docker compose up`, so files you drop
into `geoserver/data/` before starting are published on first boot.

Sidecar `<name>.json` keys (all optional):

| Key | Meaning |
|---|---|
| `name` | dataset slug (default derived from the file name) |
| `title`, `notes` | dataset title and description; also GeoServer title/abstract |
| `country`, `commodity`, `data_type`, `access_level` | AMConnect fields |
| `tags` | list of tag names |
| `resource_name`, `resource_description` | the WMS resource for this layer |
| `extra_resources` | list of `{name, description, url, wms_layer}` for external WMS servers |

Layer names must be letters, digits and underscores, starting with a letter. The
file name is the layer name, so rename before publishing if needed.

Raster tips: the GeoTIFF must carry a CRS (`gdal_translate -a_srs EPSG:4326` if
not). Float rasters render black without a style; copy
`geoserver/styles/tha_pd_2020_1km_UNadj.sld`, adjust the `ColorMapEntry`
quantities to your value range, and save it as `geoserver/styles/<name>.sld`.
Large rasters benefit from `gdaladdo -r average file.tif 2 4 8 16` or converting
to a Cloud Optimized GeoTIFF first.

## The CKAN extension: `ckanext-amconnect`

Two plugins, both enabled in `CKAN__PLUGINS`:

- `amconnect`: dataset fields, resource field, template overrides, Map tab, CLI.
- `amconnect_wms_view`: the OpenLayers resource view (`IResourceView`). It is a
  separate class only because `IDatasetForm` and `IResourceView` both define
  `setup_template_variables`.

| Piece                          | File                                             |
|--------------------------------|--------------------------------------------------|
| Custom dataset fields          | `plugin.py` (`DATASET_FIELDS`, `IDatasetForm`)   |
| `wms_layer` resource field     | `plugin.py` schema, `templates/package/snippets/resource_form.html` |
| WMS resource detection         | `wms.py` (`is_wms_resource`, `layer_for`)        |
| OpenLayers map (CKAN JS module)| `assets/wms-map.js`, `assets/wms-map.css`        |
| Resource view template         | `templates/amconnect/wms_view.html`              |
| Dataset "Map" tab              | `views.py` (blueprint), `templates/amconnect/dataset_map.html`, `templates/package/read_base.html` |
| Seed command                   | `cli.py` (`ckan amconnect seed`, one dataset per drop-folder file) |

The four custom fields are stored as CKAN extras and exposed as top-level keys in
the API (`convert_to_extras` / `convert_from_extras`). `data_type` and `access_level`
are constrained to a small choice list; `country` and `commodity` are free text.

The extension source is bind-mounted into the container, so edits to templates,
JS and Python are picked up with `docker compose restart ckan` (no rebuild).

## How the CKAN-to-WMS preview works

1. A resource is treated as WMS when its `format` is `WMS` (or its URL contains
   `service=wms`). The layer name comes from the resource's `wms_layer` field, or,
   if absent, from a `LAYERS=` parameter in the URL.
2. `ckan.views.default_views` includes `amconnect_wms_view`, so CKAN attaches the
   map view automatically to every new WMS resource (`can_view` decides).
3. The view template outputs a `<div data-module="amconnect-wms-map" data-layers='[...]'>`
   plus OpenLayers from the jsDelivr CDN. The Map tab outputs the same snippet
   with every WMS resource of the dataset.
4. `wms-map.js` builds an `ol.Map` with an OSM base layer and one
   `ol.source.TileWMS` per resource. The browser requests GetMap tiles
   **directly from the WMS server**; CKAN's backend is never in the tile path and
   never needs to reach GeoServer.
5. Best effort extras when the WMS server sends CORS headers (the POC GeoServer
   does, `CORS_ENABLED=true`): the map reads GetCapabilities to zoom to the layer's
   extent, and a click issues GetFeatureInfo and shows the attributes. Servers
   without CORS (most external ones) still render fine; only these extras are skipped.

### Area selection and summary statistics

The map has a **Select area (stats)** button. Click it, drag a rectangle, and the
map computes summary statistics for the topmost visible layer that supports it:

- **Raster layers** (e.g. population density): the browser requests the box as a
  clipped GeoTIFF from GeoServer's WCS (`GetCoverage` with `subset=Long/Lat`,
  output in EPSG:4326) and reduces it with geotiff.js: pixel count, valid pixels,
  min, max, mean, standard deviation, sum, valid area in km², and
  "Σ value × pixel area", which is the estimated total when the values are
  per-km² densities (people in the box, for the WorldPop layer). Boxes covering more
  than 2 million native pixels are requested downsampled via `scaleFactor`, and the
  panel says so.
- **Vector layers** (e.g. geology): the browser requests the intersecting features
  from WFS (`GetFeature` with `bbox`) and reports feature count, total area of those
  features, and a breakdown by the first text attribute (e.g. `rock_class`).
- **External WMS-only layers**: not supported, the panel says why. Statistics need
  WCS/WFS next to the WMS and CORS, which the POC GeoServer has and most third-party
  WMS servers do not. No WPS extension is needed on GeoServer.

The result panel includes a link with `#bbox=minlon,minlat,maxlon,maxlat`, which
reopens the map with the same selection, e.g.
http://localhost:5000/dataset/thailand-population-density-2020/map#bbox=100.3,13.5,100.9,14.0
(greater Bangkok: about 4,200 km² and 20 million people in the 2020 WorldPop layer).

Layer order on the map follows resource order, first at the bottom. The seed puts
external resources first so a local thematic layer draws on top of an opaque
external basemap.

Because the browser fetches tiles, the WMS URL stored in CKAN must be reachable
from the browser. That is why the seeded resource uses `http://localhost:8080/...`
(`GEOSERVER_PUBLIC_WMS_URL` in `.env`) rather than the internal `http://geoserver:8080/...`.

To add your own WMS: create a resource, set Format to `WMS`, put the server's base
URL in URL and the layer name in the "WMS layer" field. Works with any WMS 1.1/1.3
server, local or remote.

## Known limitations

- **Not hardened**: default passwords, HTTP only, no TLS, CKAN debug-level defaults,
  no backups, everything on one host.
- **Anonymous view only**: CKAN's `access_level` field is descriptive metadata. It
  does not enforce anything, and GeoServer's WMS is fully public. Access control
  across CKAN and GeoServer is not wired together.
- **No self-service upload**: publishing a layer is `./publish.sh` run by an
  operator on the host. CKAN file uploads do not reach GeoServer, and there is no
  web upload wizard.
- **No metadata sync**: CKAN and GeoServer each hold their own title/abstract for
  the layer; nothing keeps them in step.
- **Browser reachability**: WMS URLs must resolve from the user's browser. Behind a
  reverse proxy, set `GEOSERVER_PUBLIC_WMS_URL` accordingly and re-run the seed.
- **OpenLayers from CDN**: the map needs internet access to jsDelivr. Vendor `ol.js`
  into `assets/` for an offline deployment.
- **External WMS extras need CORS**: zoom-to-extent and click-to-identify only work
  against servers that allow cross-origin requests. Tiles always work.
- **Synthetic example vector layer**: see above.
- **Rasters are uploaded over HTTP**: fine for megabytes, slow for multi-gigabyte
  files (a shared volume plus `external.geotiff` would be the next step).
- **CKAN datastore/datapusher disabled**: not needed for this POC.
- **Legend**: no GetLegendGraphic rendering yet; the style is only visible on the map.
- **Statistics are computed in the browser**: the clipped raster is downloaded to
  the client, so very large selections are downsampled (approximate) and rely on
  GeoServer's WCS output limits. Server-side zonal statistics (GeoServer WPS or a
  small API) would be the production approach. Vector statistics count features
  that intersect the box; areas are not clipped to the box.

## Where GeoNode would fit (later phase)

Nothing in the CKAN side depends on GeoServer specifically. CKAN stores a WMS URL
and a layer name; the map module speaks plain WMS. GeoNode publishes layers through
its own GeoServer, so a GeoNode-backed layer is just another WMS resource in CKAN.
Structurally, GeoNode would be a third tier in `docker-compose.yml` next to the
current "GIS tier", and `GEOSERVER_PUBLIC_WMS_URL` would point at GeoNode's
GeoServer.

Functionality that this POC lacks and that GeoNode provides out of the box, which
is the case for introducing it:

| Need                                             | POC today                                  | With GeoNode                                          |
|--------------------------------------------------|--------------------------------------------|-------------------------------------------------------|
| Self-service **upload** of shapefile/GeoPackage/GeoTIFF | `./publish.sh` on the host (operator only) | Web upload wizard for end users, automatic PostGIS import + publish |
| **Metadata** editing for layers (ISO 19115, INSPIRE) | Free text in CKAN, separate from GeoServer | Layer metadata editor, CSW endpoint, harvestable into CKAN (e.g. ckanext-spatial harvester) |
| **Styling** by end users                          | Hand-written SLD in `geoserver/styles/`     | In-browser style editor, per-layer default/alternate styles |
| **Permissions** per layer/user/group             | GeoServer is public; CKAN `access_level` is a label | Per-resource view/download/edit permissions, synced to GeoServer security |
| **GIS administration** (raster support, layer groups, users, thumbnails, monitoring) | GeoServer admin UI only                    | GeoNode admin + GeoServer, plus REST API              |
| Maps composed of several layers, saved and shared | Dataset "Map" tab only                     | Saved maps, map viewer, embeddable                    |
| Download in other formats (WFS/WCS, zipped shp)  | WFS is available but not exposed in CKAN   | Download links per layer, format conversion           |

If the requirements stay at "publish a handful of curated layers and preview them
in CKAN", GeoServer + a small publishing script (what this POC does) is enough.
If users must upload, style, describe and share layers themselves with permissions,
GeoNode is the natural next step, and CKAN keeps its role as the unified portal by
pointing at GeoNode's WMS (and optionally harvesting GeoNode's CSW for metadata).
