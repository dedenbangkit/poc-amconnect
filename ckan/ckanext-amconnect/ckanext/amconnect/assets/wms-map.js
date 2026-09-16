/* CKAN JS module: render one or more WMS layers with OpenLayers.
 *
 * <div data-module="amconnect-wms-map" data-layers='[{"name":..,"url":..,"layer":..}]'>
 *
 * Works for any WMS server.  When the server sends CORS headers (the POC
 * GeoServer does) we additionally:
 *   - read GetCapabilities to zoom to the layer extent
 *   - GetFeatureInfo on click
 *   - "Select area (stats)": drag a rectangle and compute summary statistics
 *     for the top visible layer.  Rasters: a clipped GeoTIFF is fetched via
 *     WCS and reduced in the browser with geotiff.js (no WPS needed).  Vectors:
 *     intersecting features are fetched via WFS.  Only layers served from a
 *     GeoServer-style .../wms endpoint (with sibling /wcs and /wfs) support it.
 * A "#bbox=minlon,minlat,maxlon,maxlat" URL hash runs a selection on load.
 */
ckan.module('amconnect-wms-map', function ($) {
  var DEFAULT_CENTER = [101.0, 13.0]; // lon/lat, roughly Thailand
  var DEFAULT_ZOOM = 5;
  var MAX_PIXELS = 2000000;           // downsample WCS clips above this
  var CRS4326 = 'http://www.opengis.net/def/crs/EPSG/0/4326';

  function esc(v) { return $('<i>').text(v == null ? '' : v).html(); }
  function fmt(n) {
    if (n == null || isNaN(n)) { return '-'; }
    return Math.abs(n) >= 1000 ? Math.round(n).toLocaleString() : (+n.toFixed(3)).toLocaleString();
  }
  function ogcUrl(wmsUrl, service) {      // .../amconnect/wms -> .../amconnect/wcs
    var base = wmsUrl.split('?')[0];
    return /\/wms$/i.test(base) ? base.replace(/\/wms$/i, '/' + service) : null;
  }

  return {
    initialize: function () {
      if (typeof ol === 'undefined') {
        this.el.append('<p class="alert alert-danger">OpenLayers failed to load (CDN blocked?).</p>');
        return;
      }
      var self = this;
      var layerDefs = this.el.data('layers') || [];
      var canvas = this.el.find('.amconnect-wms-map__canvas')[0];
      this.infoEl = this.el.find('.amconnect-wms-map__info');
      this.selectBtn = this.el.find('[data-action=select-area]');
      this.clearBtn = this.el.find('[data-action=clear]');

      this.wmsLayers = layerDefs.map(function (def) {
        return new ol.layer.Tile({
          source: new ol.source.TileWMS({
            url: def.url,
            params: { LAYERS: def.layer, TILED: true, TRANSPARENT: true, FORMAT: 'image/png' },
            crossOrigin: 'anonymous',   // harmless if the server has no CORS; images still render
            serverType: 'geoserver'
          }),
          properties: { def: def }
        });
      });

      this.selectionSource = new ol.source.Vector();
      this.selectionLayer = new ol.layer.Vector({
        source: this.selectionSource,
        style: new ol.style.Style({
          stroke: new ol.style.Stroke({ color: '#d62728', width: 2, lineDash: [6, 4] }),
          fill: new ol.style.Fill({ color: 'rgba(214,39,40,0.08)' })
        })
      });

      this.map = new ol.Map({
        target: canvas,
        layers: [new ol.layer.Tile({ source: new ol.source.OSM() })]
          .concat(this.wmsLayers).concat([this.selectionLayer]),
        view: new ol.View({ center: ol.proj.fromLonLat(DEFAULT_CENTER), zoom: DEFAULT_ZOOM })
      });

      this.el.find('input[data-layer-index]').on('change', function () {
        self.wmsLayers[$(this).data('layer-index')].setVisible(this.checked);
      });

      this.map.on('singleclick', function (evt) {
        if (!self.selecting) { self.featureInfo(evt); }
      });

      this.dragBox = new ol.interaction.DragBox({ condition: ol.events.condition.always });
      this.dragBox.on('boxend', function () {
        self.setSelecting(false);
        self.runStats(self.dragBox.getGeometry().getExtent());
      });
      this.selectBtn.on('click', function () { self.setSelecting(!self.selecting); });
      this.clearBtn.on('click', function () { self.clearSelection(); });

      var hash = /[#&]bbox=([-\d.,]+)/.exec(window.location.hash || '');
      if (hash) {
        var b = hash[1].split(',').map(Number);
        var extent = ol.proj.transformExtent(b, 'EPSG:4326', 'EPSG:3857');
        this.map.getView().fit(extent, { padding: [60, 60, 60, 60], maxZoom: 12 });
        this.runStats(extent);
      } else if (layerDefs.length) {
        this.zoomToLayer(layerDefs[0]);   // best effort, needs CORS
      }
    },

    // ------------------------------------------------------------ selection
    setSelecting: function (on) {
      this.selecting = on;
      this.el.toggleClass('is-selecting', on);
      this.selectBtn.toggleClass('active', on);
      if (on) { this.map.addInteraction(this.dragBox); }
      else { this.map.removeInteraction(this.dragBox); }
    },

    clearSelection: function () {
      this.selectionSource.clear();
      this.infoEl.attr('hidden', true).empty();
      this.clearBtn.attr('hidden', true);
    },

    // Topmost visible layer; with preferSupported, prefer one whose WMS URL has
    // sibling WCS/WFS endpoints (GeoServer style) so statistics can be computed.
    topVisibleLayer: function (preferSupported) {
      var visible = this.wmsLayers.filter(function (l) { return l.getVisible(); });
      if (preferSupported) {
        var supported = visible.filter(function (l) { return !!ogcUrl(l.get('def').url, 'wcs'); });
        if (supported.length) { return supported[supported.length - 1]; }
      }
      return visible.length ? visible[visible.length - 1] : null;
    },

    showInfo: function (title, html) {
      this.infoEl.html('<strong>' + esc(title) + '</strong>' + html).removeAttr('hidden');
      this.clearBtn.removeAttr('hidden');
    },

    runStats: function (extent3857) {
      var self = this;
      this.selectionSource.clear();
      this.selectionSource.addFeature(new ol.Feature(ol.geom.Polygon.fromExtent(extent3857)));
      var bbox = ol.proj.transformExtent(extent3857, 'EPSG:3857', 'EPSG:4326');
      var layer = this.topVisibleLayer(true);
      if (!layer) { return this.showInfo('Statistics', '<p>No visible layer.</p>'); }
      var def = layer.get('def');
      var wcs = ogcUrl(def.url, 'wcs');
      if (!wcs) {
        return this.showInfo(def.name, '<p class="text-muted">Statistics need a WCS/WFS endpoint next to the WMS (GeoServer). Not available for this layer.</p>');
      }
      var b = bbox.map(function (v) { return +v.toFixed(5); });
      var link = window.location.pathname + '#bbox=' + b.join(',');
      this.showInfo(def.name, '<p class="text-muted">Computing statistics for ' + b.join(', ') + ' ...</p>');
      var coverageId = def.layer.replace(':', '__');

      fetch(wcs + '?service=WCS&version=2.0.1&request=DescribeCoverage&coverageId=' + encodeURIComponent(coverageId))
        .then(function (r) { return r.ok ? r.text() : Promise.reject('vector'); })
        .then(function (xml) { return self.rasterStats(wcs, coverageId, bbox, xml); })
        .catch(function (err) {
          if (err !== 'vector') { throw err; }
          return self.vectorStats(ogcUrl(def.url, 'wfs'), def.layer, extent3857);
        })
        .then(function (html) {
          self.showInfo(def.name, html + '<p class="text-muted small">bbox (lon/lat): ' + b.join(', ') +
            ' &middot; <a href="' + link + '">link to this selection</a></p>');
        })
        .catch(function (err) {
          self.showInfo(def.name, '<p class="text-danger">Statistics failed: ' + esc(err && err.message || err) + '</p>');
        });
    },

    // Raster: WCS GetCoverage clipped to the box -> GeoTIFF -> reduce in browser
    rasterStats: function (wcs, coverageId, bbox, describeXml) {
      if (typeof GeoTIFF === 'undefined') { return Promise.reject(new Error('geotiff.js not loaded')); }
      // estimate how many native pixels the box covers, to decide on downsampling
      var doc = new DOMParser().parseFromString(describeXml, 'text/xml');
      var text = function (tag) { var n = doc.getElementsByTagNameNS('*', tag)[0]; return n ? n.textContent.trim().split(/\s+/).map(Number) : null; };
      var lower = text('lowerCorner'), upper = text('upperCorner'), high = text('high');
      var scale = 1;
      if (lower && upper && high) {
        var envArea = Math.abs((upper[0] - lower[0]) * (upper[1] - lower[1]));
        var boxArea = (bbox[2] - bbox[0]) * (bbox[3] - bbox[1]);
        var totalPx = (high[0] + 1) * (high[1] + 1);
        var est = totalPx * boxArea / envArea;
        if (est > MAX_PIXELS) { scale = Math.sqrt(MAX_PIXELS / est); }
      }
      var url = wcs + '?service=WCS&version=2.0.1&request=GetCoverage&coverageId=' + encodeURIComponent(coverageId) +
        '&subset=Long(' + bbox[0] + ',' + bbox[2] + ')&subset=Lat(' + bbox[1] + ',' + bbox[3] + ')' +
        '&subsettingCrs=' + CRS4326 + '&outputCrs=' + CRS4326 + '&format=image/tiff' +
        (scale < 1 ? '&scaleFactor=' + scale.toFixed(4) : '');
      return fetch(url).then(function (r) {
        if (!r.ok) { return r.text().then(function (t) { throw new Error('WCS ' + r.status + ': ' + t.replace(/<[^>]+>/g, ' ').trim().slice(0, 200)); }); }
        return r.arrayBuffer();
      }).then(function (buf) {
        return GeoTIFF.fromArrayBuffer(buf).then(function (tiff) { return tiff.getImage(); });
      }).then(function (image) {
        return image.readRasters({ interleave: false }).then(function (rasters) {
          var band = rasters[0];
          var w = image.getWidth(), h = image.getHeight();
          var fd = image.getFileDirectory();
          var nodata = fd.GDAL_NODATA != null ? parseFloat(fd.GDAL_NODATA) : null;
          var origin = image.getOrigin(), res = image.getResolution();
          var pxW = Math.abs(res[0]), pxH = Math.abs(res[1]);
          var n = 0, sum = 0, sumsq = 0, min = Infinity, max = -Infinity, weighted = 0, area = 0;
          for (var row = 0; row < h; row++) {
            var lat = origin[1] - (row + 0.5) * pxH;                       // outputCrs is EPSG:4326
            var pxArea = (pxW * 111.32 * Math.cos(lat * Math.PI / 180)) * (pxH * 110.57); // km2
            for (var col = 0; col < w; col++) {
              var v = band[row * w + col];
              if (v == null || isNaN(v) || (nodata != null && v === nodata)) { continue; }
              n++; sum += v; sumsq += v * v;
              if (v < min) { min = v; } if (v > max) { max = v; }
              weighted += v * pxArea; area += pxArea;
            }
          }
          var mean = n ? sum / n : NaN;
          var std = n ? Math.sqrt(Math.max(sumsq / n - mean * mean, 0)) : NaN;
          var rows = [
            ['Pixels in box', fmt(w * h) + (scale < 1 ? ' (downsampled x' + scale.toFixed(2) + ')' : '')],
            ['Valid pixels', fmt(n)], ['Min', fmt(min)], ['Max', fmt(max)],
            ['Mean', fmt(mean)], ['Std dev', fmt(std)], ['Sum', fmt(sum)],
            ['Valid area (km²)', fmt(area)],
            ['Σ value × pixel area (km²)', fmt(weighted) + ' <span class="text-muted">(= estimated total when values are per-km² densities)</span>']
          ];
          return '<table class="table table-condensed">' + rows.map(function (r) {
            return '<tr><th>' + r[0] + '</th><td>' + r[1] + '</td></tr>'; }).join('') + '</table>';
        });
      });
    },

    // Vector: WFS GetFeature with BBOX -> count, area, category breakdown
    vectorStats: function (wfs, typeName, extent3857) {
      var url = wfs + '?service=WFS&version=2.0.0&request=GetFeature&typeNames=' + encodeURIComponent(typeName) +
        '&bbox=' + extent3857.join(',') + ',EPSG:3857&outputFormat=application/json&srsName=EPSG:3857';
      return fetch(url).then(function (r) {
        if (!r.ok) { throw new Error('WFS ' + r.status); }
        return r.json();
      }).then(function (json) {
        var feats = new ol.format.GeoJSON().readFeatures(json);
        var area = 0, counts = {};   // counts[field][value] for every text field
        feats.forEach(function (f) {
          var g = f.getGeometry();
          if (g && /Polygon/.test(g.getType())) { area += ol.sphere.getArea(g, { projection: 'EPSG:3857' }); }
          var props = f.getProperties();
          Object.keys(props).forEach(function (k) {
            if (k === 'geometry' || typeof props[k] !== 'string') { return; }
            counts[k] = counts[k] || {};
            counts[k][props[k]] = (counts[k][props[k]] || 0) + 1;
          });
        });
        // the most "categorical" text field: fewest distinct values, but not constant / not unique ids
        var catField = Object.keys(counts).filter(function (k) {
          var n = Object.keys(counts[k]).length; return n > 1 && n < feats.length;
        }).sort(function (a, b) { return Object.keys(counts[a]).length - Object.keys(counts[b]).length; })[0];
        var rows = [['Features intersecting box', fmt(feats.length)],
                    ['Area of those features (km²)', fmt(area / 1e6)]];
        if (catField) {
          var cats = counts[catField];
          var top = Object.keys(cats).sort(function (a, b) { return cats[b] - cats[a]; }).slice(0, 8);
          rows.push(['By ' + esc(catField), top.map(function (k) { return esc(k) + ': ' + cats[k]; }).join('<br>')]);
        }
        return '<table class="table table-condensed">' + rows.map(function (r) {
          return '<tr><th>' + r[0] + '</th><td>' + r[1] + '</td></tr>'; }).join('') + '</table>';
      });
    },

    // ------------------------------------------------------- zoom / identify
    zoomToLayer: function (def) {
      var self = this;
      var capsUrl = def.url + (def.url.indexOf('?') === -1 ? '?' : '&') +
        'SERVICE=WMS&VERSION=1.3.0&REQUEST=GetCapabilities';
      fetch(capsUrl).then(function (r) { return r.text(); }).then(function (text) {
        var caps = new ol.format.WMSCapabilities().read(text);
        var found = null;
        (function walk(layer) {
          if (!layer) { return; }
          if (layer.Name === def.layer || layer.Name === def.layer.split(':').pop()) { found = layer; }
          (layer.Layer || []).forEach(walk);
        })(caps.Capability.Layer);
        var bbox = found && found.EX_GeographicBoundingBox;
        if (bbox) {
          self.map.getView().fit(ol.proj.transformExtent(bbox, 'EPSG:4326', 'EPSG:3857'),
            { padding: [20, 20, 20, 20], maxZoom: 12 });
        }
      }).catch(function () { /* no CORS or not a capabilities doc: keep default view */ });
    },

    featureInfo: function (evt) {
      var self = this;
      var view = this.map.getView();
      var layer = this.topVisibleLayer();
      if (!layer) { return; }
      var url = layer.getSource().getFeatureInfoUrl(evt.coordinate, view.getResolution(),
        view.getProjection(), { INFO_FORMAT: 'application/json', FEATURE_COUNT: 5 });
      if (!url) { return; }
      fetch(url).then(function (r) { return r.json(); }).then(function (json) {
        var feats = json.features || [];
        if (!feats.length) { return; }
        var props = feats[0].properties || {};
        var rows = Object.keys(props).map(function (k) {
          return '<tr><th>' + esc(k) + '</th><td>' + esc(props[k]) + '</td></tr>';
        }).join('');
        self.showInfo(layer.get('def').name, '<table class="table table-condensed">' + rows + '</table>');
      }).catch(function () { /* external server without CORS or JSON info format */ });
    }
  };
});
