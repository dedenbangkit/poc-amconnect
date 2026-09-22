#!/usr/bin/env python3
"""Turn scraped ACMDP records into ONE point layer for the AMConnect drop folder.

    python external-data/acmdp_to_layer.py [external-data/data/acmdp_all.json]
    ./publish.sh geoserver/data/acmdp_mineral_sites.geojson

Why one layer and not one CKAN dataset per record: 4,000+ occurrences are features of a
single dataset ("ACMDP mineral occurrences"). As a GeoServer layer they get WMS rendering,
WFS queries/downloads, the query builder, area statistics and styles for free; CKAN holds
one catalogue record pointing at it. Each feature keeps its ACMDP page URL and record ids.

Writes:
    geoserver/data/acmdp_mineral_sites.geojson   points, flattened attributes
    geoserver/data/acmdp_mineral_sites.json      CKAN sidecar (title, notes, tags, extent)
    geoserver/styles/acmdp_mineral_sites.sld     default style: by commodity type
    geoserver/styles/acmdp_mineral_sites__country.sld, __status.sld, __deposit_type.sld
Only the standard library is needed.
"""
import json
import os
import re
import sys
from collections import Counter
from xml.sax.saxutils import escape

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LAYER = "acmdp_mineral_sites"

# ACMDP metadata key -> attribute name (PostGIS-friendly: lowercase, <= 63 chars)
FIELDS = {
    "General Information > Commodity Type": "commodity_type",
    "General Information > Mine Name(Ore Deposit Name)": "deposit_name",
    "General Information > Country": "country",
    "General Information > Location Name": "location_name",
    "General Information > Company Name": "company",
    "General Information > License Type": "license_type",
    "General Information > Status": "status",
    "Geology(Country Rock) > Geotectonics": "geotectonics",
    "Geology(Country Rock) > Stratum Name": "stratum_name",
    "Geology(Country Rock) > Lithology": "lithology",
    "Geology(Country Rock) > Age": "host_rock_age",
    "Metallogenic Belt Name > Metallogenic Belt Name": "metallogenic_belt",
    "Related Igneous Rock > Type of Related Igneous Rock": "igneous_rock_type",
    "Related Igneous Rock > Age of Related Igneous Rock": "igneous_rock_age",
    "Ore Deposit > Type of Ore Deposit": "deposit_type",
    "Ore Deposit > Ore Body Type": "ore_body_type",
    "Ore Deposit > Ore Body Scale(Depth)": "ore_body_scale",
    "Ore Deposit > Main Ore Deposit": "main_ore",
    "Ore Deposit > Minor Ore Deposit": "minor_ore",
    "Ore Deposit > Main Mineral": "main_mineral",
    "Ore Deposit > Minor Mineral": "minor_mineral",
    "Ore Deposit > Mineralizaed Age": "mineralized_age",
    "Ore Deposit > Alteration Properties": "alteration",
    "Ore Deposit > Grade of Resources": "grade",
    "Ore Deposit > Resources": "resources",
    "Ore Deposit > Reserves": "reserves",
    "Ore Deposit > Grade of Reserves": "grade_of_reserves",
    "Ore Deposit > Ore Body Direction": "ore_body_direction",
    "Ore Deposit > Ore Body Scale(Length)": "ore_body_length",
    "Ore Deposit > Ore Body Scale(Width)": "ore_body_width",
    "File Data > Type of Map & Report": "map_report_type",
    "File Data > Content Type": "file_content_type",
    "File Data > Title": "file_title",
    "File Data > Publishing Agency": "publishing_agency",
    "File Data > Publication Year": "publication_year",
    "File Data > Data File": "data_file",
    "File Data > File Public setting": "file_public_setting",
    "URL Reference > URL": "reference_url",
    "URL Reference > URL Type": "reference_url_type",
    "URL Reference > URL Description": "reference_desc",
    "Security Level > Security Level": "security_level",
    "License & Copyright > Public settings": "public_settings",
    "License & Copyright > CC License": "cc_license",
    "License & Copyright > Copyright": "copyright",
    "License & Copyright > Data Registrant": "registrant",
    "License & Copyright > Registration Date": "registration_date",
    "License & Copyright > Phrases used in citation": "citation_phrases",
    "Comments > Comments": "comments",
}
PALETTE = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b", "#e377c2",
           "#17becf", "#bcbd22", "#7f7f7f", "#aec7e8", "#ffbb78", "#98df8a", "#ff9896", "#c5b0d5"]


def slug(text):
    return re.sub(r"[^a-z0-9]+", "_", (text or "").lower()).strip("_")[:60] or "field"


def parse_point(wkt):
    m = re.match(r"\s*POINT\s*\(\s*([-\d.]+)\s+([-\d.]+)\s*\)", wkt or "")
    if not m:
        return None
    x, y = float(m.group(1)), float(m.group(2))
    if not (-180 <= x <= 180 and -90 <= y <= 90):
        return None
    return [round(x, 6), round(y, 6)]


def convert(records):
    features, skipped, extra_keys = [], Counter(), Counter()
    seen = set()
    for r in records:
        uuid = r.get("uuid") or ""
        if uuid in seen:
            skipped["duplicate"] += 1
            continue
        seen.add(uuid)
        geo = r.get("geodata") or {}
        pt = parse_point(geo.get("wkt_point")) or next(
            (parse_point(w) for w in geo.get("wkt_detail") or [] if parse_point(w)), None)
        if not pt:
            skipped["no point"] += 1
            continue
        meta = r.get("metadata") or {}
        props = {"uuid": uuid, "title": r.get("title") or "", "commodity_code": r.get("commodity_code") or "",
                 "description": r.get("description") or "", "source_url": r.get("url") or ""}
        cats = r.get("categories") or []
        props["asean_id"] = next((c for c in cats if c.startswith("ASEAN-")), "")
        props["national_id"] = next((c for c in cats if re.match(r"^[A-Z]{2}-\d+$", c)), "")
        props["category"] = next((c for c in cats if not c.startswith("ASEAN-") and not re.match(r"^[A-Z]{2}-\d+$", c)), "")
        for key, name in FIELDS.items():
            props[name] = meta.get(key, "") or ""
        for key in meta:
            if key not in FIELDS:
                extra_keys[key] += 1
                props.setdefault("x_" + slug(key.split(">")[-1]), meta[key])
        if not props["commodity_type"] and props["title"].startswith("["):
            props["commodity_type"] = props["title"][1:].split("]")[0]
        props["commodity_type"] = props["commodity_type"] or "Unknown"
        features.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": pt}, "properties": props})
    return features, skipped, extra_keys


def rule(title, prop, value, color, shape="circle", size=8):
    return f'''
      <Rule><Name>{escape(title)}</Name><Title>{escape(title)}</Title>
        <ogc:Filter><ogc:PropertyIsEqualTo><ogc:PropertyName>{prop}</ogc:PropertyName><ogc:Literal>{escape(value)}</ogc:Literal></ogc:PropertyIsEqualTo></ogc:Filter>
        <PointSymbolizer><Graphic><Mark><WellKnownName>{shape}</WellKnownName>
          <Fill><CssParameter name="fill">{color}</CssParameter><CssParameter name="fill-opacity">0.9</CssParameter></Fill>
          <Stroke><CssParameter name="stroke">#ffffff</CssParameter><CssParameter name="stroke-width">1</CssParameter></Stroke>
        </Mark><Size>{size}</Size></Graphic></PointSymbolizer></Rule>'''


def else_rule(title, color="#9e9e9e"):
    return f'''
      <Rule><Name>{escape(title)}</Name><Title>{escape(title)}</Title><ElseFilter/>
        <PointSymbolizer><Graphic><Mark><WellKnownName>circle</WellKnownName>
          <Fill><CssParameter name="fill">{color}</CssParameter><CssParameter name="fill-opacity">0.8</CssParameter></Fill>
          <Stroke><CssParameter name="stroke">#ffffff</CssParameter><CssParameter name="stroke-width">1</CssParameter></Stroke>
        </Mark><Size>7</Size></Graphic></PointSymbolizer></Rule>'''


def sld(style_title, rules):
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<StyledLayerDescriptor version="1.0.0" xmlns="http://www.opengis.net/sld" xmlns:ogc="http://www.opengis.net/ogc" xmlns:xlink="http://www.w3.org/1999/xlink">
  <NamedLayer><Name>{LAYER}</Name><UserStyle><Title>{escape(style_title)}</Title>
    <FeatureTypeStyle>{"".join(rules)}
    </FeatureTypeStyle>
  </UserStyle></NamedLayer>
</StyledLayerDescriptor>
'''


def categorical_style(features, prop, title, top=14, other="Other"):
    counts = Counter(f["properties"].get(prop) or "" for f in features)
    values = [v for v, _ in counts.most_common() if v][:top]
    rules = [rule(f"{v} ({counts[v]})", prop, v, PALETTE[i % len(PALETTE)]) for i, v in enumerate(values)]
    rest = sum(n for v, n in counts.items() if v not in values)
    if rest:
        rules.append(else_rule(f"{other} ({rest})"))
    return sld(title, rules)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else None
    if not src:
        for cand in ("acmdp_all.json", "acmdp_records.json"):
            path = os.path.join(HERE, "data", cand)
            if os.path.exists(path):
                src = path
                break
    if not src or not os.path.exists(src):
        sys.exit("usage: acmdp_to_layer.py <acmdp json>  (no data/acmdp_all.json found)")
    with open(src, encoding="utf-8") as fh:
        records = json.load(fh)
    features, skipped, extra_keys = convert(records)
    if not features:
        sys.exit("no point features found")
    xs = [f["geometry"]["coordinates"][0] for f in features]
    ys = [f["geometry"]["coordinates"][1] for f in features]
    bbox = [min(xs), min(ys), max(xs), max(ys)]
    countries = Counter(f["properties"]["country"] for f in features)
    commodities = Counter(f["properties"]["commodity_type"] for f in features)

    data_dir, style_dir = os.path.join(ROOT, "geoserver", "data"), os.path.join(ROOT, "geoserver", "styles")
    os.makedirs(data_dir, exist_ok=True); os.makedirs(style_dir, exist_ok=True)
    with open(os.path.join(data_dir, LAYER + ".geojson"), "w", encoding="utf-8") as fh:
        json.dump({"type": "FeatureCollection", "features": features}, fh, ensure_ascii=False)

    top_countries = ", ".join(f"{c} ({n})" for c, n in countries.most_common(6) if c)
    top_comm = ", ".join(f"{c} ({n})" for c, n in commodities.most_common(8))
    sidecar = {
        "name": "acmdp-mineral-occurrences",
        "title": f"ACMDP mineral occurrences ({len(features):,} sites)",
        "notes": (f"Mineral occurrences, deposits and mines from the ASEAN Critical Minerals Data Platform "
                  f"(acmdp.org), scraped from the public record pages and republished as one point layer. "
                  f"{len(features):,} sites in {sum(1 for c in countries if c)} countries: {top_countries}. "
                  f"Main commodities: {top_comm}.\n\nEach point carries the ACMDP record ids, the flattened "
                  f"metadata sections (general information, geology, ore deposit, licence and copyright) and a "
                  f"link back to the source page. Source data remains the property of the registrants named in "
                  f"each record; see the licence fields per feature."),
        "country": "ASEAN" if len([c for c in countries if c]) > 1 else next(iter(countries), ""),
        "commodity": "Multiple",
        "data_type": "geospatial",
        "access_level": "public-download",
        "license_id": "other-at",
        "tags": ["minerals", "acmdp", "asean", "occurrences", "points"],
        "spatial": {"type": "Polygon", "coordinates": [[[bbox[0], bbox[1]], [bbox[2], bbox[1]], [bbox[2], bbox[3]], [bbox[0], bbox[3]], [bbox[0], bbox[1]]]]},
        "resource_name": "ACMDP mineral occurrences (WMS)",
        "resource_description": f"Point layer amconnect:{LAYER} on the POC GeoServer, styled by commodity type; alternate styles by country, status and deposit type.",
        "extra_resources": [
            {"name": "ACMDP portal (source)", "description": "ASEAN Critical Minerals Data Platform, the origin of every record.",
             "url": "https://acmdp.org/", "format": "HTML"}
        ],
    }
    with open(os.path.join(data_dir, LAYER + ".json"), "w", encoding="utf-8") as fh:
        json.dump(sidecar, fh, indent=2, ensure_ascii=False)

    styles = {
        LAYER + ".sld": categorical_style(features, "commodity_type", "ACMDP sites by commodity"),
        LAYER + "__country.sld": categorical_style(features, "country", "ACMDP sites by country", top=10),
        LAYER + "__status.sld": categorical_style(features, "status", "ACMDP sites by status", top=8, other="Not stated"),
        LAYER + "__deposit_type.sld": categorical_style(features, "deposit_type", "ACMDP sites by deposit type", top=12),
    }
    for name, xml in styles.items():
        with open(os.path.join(style_dir, name), "w", encoding="utf-8") as fh:
            fh.write(xml)

    print(f"source:   {src} ({len(records)} records)")
    print(f"features: {len(features)}  skipped: {dict(skipped) or 'none'}")
    print(f"extent:   {bbox}")
    print(f"countries: {dict(countries.most_common())}")
    print(f"commodities (top 10): {commodities.most_common(10)}")
    if extra_keys:
        print(f"metadata keys not in FIELDS (kept as x_*): {extra_keys.most_common(10)}")
    print(f"wrote geoserver/data/{LAYER}.geojson, .json and {len(styles)} styles")
    print(f"next: ./publish.sh geoserver/data/{LAYER}.geojson")


if __name__ == "__main__":
    main()
