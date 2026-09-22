"""Scrape ALL ACMDP mineral data (4000+ records) with full metadata and geodata.

Usage:
    python external-data/scrape_acmdp_all.py                   # all records, resumable
    python external-data/scrape_acmdp_all.py --limit 100       # test with 100
    python external-data/scrape_acmdp_all.py --concurrency 8   # faster (default 5)

Resumable: every fetched detail page is appended to data/acmdp_cache.jsonl; a re-run skips
records already in the cache (use --no-resume to refetch everything). Outputs
data/acmdp_all.json and data/acmdp_all.csv next to this script; feed the JSON to
acmdp_to_layer.py to publish it as a map layer.
"""
import argparse
import asyncio
import csv
import json
import os
import re
import time
from datetime import timedelta

import httpx
from bs4 import BeautifulSoup

BASE_URL = "https://acmdp.org"
DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
CACHE_PATH = os.path.join(DATA_DIR, "acmdp_cache.jsonl")


async def fetch_all_locations(client: httpx.AsyncClient) -> list[dict]:
    """Fetch all location entries from /locations API."""
    resp = await client.get(f"{BASE_URL}/locations")
    resp.raise_for_status()
    data = resp.json()
    locations = data.get("locations", [])
    print(f"Total locations from API: {len(locations)}")
    return locations


def parse_detail_page(html: str) -> dict:
    """Parse a /data/{uuid} page for all metadata."""
    soup = BeautifulSoup(html, "lxml")
    record = {}

    # Title
    title_el = soup.select_one(".vt_text")
    if title_el:
        record["title"] = re.sub(r'\s+', ' ', title_el.get_text(strip=True))

    # Record codes (e.g. ASEAN-CMR-2026-001430, MM-000046)
    codes = [s.get_text(strip=True) for s in soup.select(".vt_shape")]
    if codes:
        record["categories"] = codes

    # WKT geodata from hidden input
    wkt_list = []
    for el in soup.select("input.wkt-geo"):
        val = el.get("value", "")
        if val:
            wkt_list.append(val)
    record["geodata_wkt"] = wkt_list

    # Parse sections: .view_meta_container_title then .md_table.row_type > h5 + p
    metadata = {}
    current_section = ""
    for el in soup.select(".view_meta_container_title, .view_sub_title, .md_table.row_type"):
        classes = el.get("class", [])
        if "view_meta_container_title" in classes or "view_sub_title" in classes:
            current_section = el.get_text(strip=True)
            continue
        h5 = el.select_one("h5")
        p = el.select_one("p")
        if h5 and p:
            key = h5.get_text(strip=True)
            val = re.sub(r'\s+', ' ', p.get_text(strip=True))
            if key and val:
                section_key = f"{current_section} > {key}" if current_section else key
                metadata[section_key] = val
    record["metadata"] = metadata

    # JSON-LD
    for script in soup.select('script[type="application/ld+json"]'):
        try:
            record["structured_data"] = json.loads(script.string)
        except (json.JSONDecodeError, TypeError):
            pass

    if record.get("structured_data", {}).get("description"):
        record["description"] = record["structured_data"]["description"]

    return record


async def fetch_detail(client: httpx.AsyncClient, loc: dict, semaphore: asyncio.Semaphore) -> dict:
    """Fetch and parse a single detail page with concurrency control."""
    link = loc.get("link", "")
    uuid = link.split("/")[-1] if link else ""
    detail_url = f"{BASE_URL}{link}" if link.startswith("/") else link

    async with semaphore:
        try:
            resp = await client.get(detail_url)
            resp.raise_for_status()
            detail = parse_detail_page(resp.text)
        except Exception as e:
            detail = {"_error": str(e)}

    return {
        "uuid": uuid,
        "title": detail.get("title") or loc.get("title", ""),
        "commodity_code": loc.get("commodity", ""),
        "geodata": {
            "wkt_point": loc.get("location", ""),
            "wkt_detail": detail.get("geodata_wkt", []),
        },
        "categories": detail.get("categories", []),
        "description": detail.get("description", ""),
        "metadata": detail.get("metadata", {}),
        "structured_data": detail.get("structured_data"),
        "url": detail_url,
        "_error": detail.get("_error"),
    }


def save_csv(records: list[dict], path: str):
    """Flatten records and save as CSV."""
    all_meta_keys = []
    for r in records:
        for k in r.get("metadata", {}):
            if k not in all_meta_keys:
                all_meta_keys.append(k)

    fieldnames = [
        "uuid", "title", "commodity_code", "latitude", "longitude",
        "wkt_point", "categories", "description", "url",
    ] + all_meta_keys

    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for r in records:
            wkt = r["geodata"]["wkt_point"]
            m = re.match(r"POINT \(([\d.-]+) ([\d.-]+)\)", wkt)
            row = {
                "uuid": r["uuid"],
                "title": r["title"],
                "commodity_code": r["commodity_code"],
                "latitude": m.group(2) if m else "",
                "longitude": m.group(1) if m else "",
                "wkt_point": wkt,
                "categories": " | ".join(r.get("categories", [])),
                "description": r.get("description", ""),
                "url": r["url"],
            }
            row.update(r.get("metadata", {}))
            writer.writerow(row)


def load_cache() -> dict:
    """uuid -> record for every detail page fetched by an earlier run."""
    cached = {}
    if os.path.exists(CACHE_PATH):
        with open(CACHE_PATH, encoding="utf-8") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                    cached[rec["uuid"]] = rec
                except (json.JSONDecodeError, KeyError):
                    continue
    return cached


async def scrape_all(limit: int = 0, concurrency: int = 5, resume: bool = True):
    """Scrape all ACMDP records with concurrent detail fetching (resumable)."""
    start = time.time()
    os.makedirs(DATA_DIR, exist_ok=True)
    cached = load_cache() if resume else {}
    if cached:
        print(f"Resuming: {len(cached)} records already in {CACHE_PATH}")

    async with httpx.AsyncClient(timeout=60, follow_redirects=True) as client:
        locations = await fetch_all_locations(client)
        if limit:
            locations = locations[:limit]
            print(f"Limited to {limit} records")

        total = len(locations)
        semaphore = asyncio.Semaphore(concurrency)
        completed = 0
        errors = 0
        cache_file = open(CACHE_PATH, "a", encoding="utf-8")

        async def fetch_with_progress(loc):
            nonlocal completed, errors
            uuid = (loc.get("link") or "").split("/")[-1]
            if uuid in cached:
                result = cached[uuid]
            else:
                result = await fetch_detail(client, loc, semaphore)
                if not result.get("_error"):
                    cache_file.write(json.dumps(result, ensure_ascii=False) + "\n")
                    cache_file.flush()
            completed += 1
            if result.get("_error"):
                errors += 1
            if completed % 50 == 0 or completed == total:
                elapsed = time.time() - start
                rate = completed / elapsed
                eta = timedelta(seconds=int((total - completed) / rate)) if rate > 0 else "?"
                print(f"  Progress: {completed}/{total} ({errors} errors) | {rate:.1f} rec/s | ETA: {eta}")
            return result

        print(f"\nFetching {total} detail pages (concurrency={concurrency})...")
        tasks = [fetch_with_progress(loc) for loc in locations]
        results = await asyncio.gather(*tasks)
        cache_file.close()

    # Filter out errors for reporting
    good = [r for r in results if not r.get("_error")]
    bad = [r for r in results if r.get("_error")]

    elapsed = time.time() - start
    print(f"\nDone in {timedelta(seconds=int(elapsed))}")
    print(f"  Success: {len(good)}")
    print(f"  Errors:  {len(bad)}")

    # Clean up _error key from results
    for r in results:
        r.pop("_error", None)

    return results


async def main():
    parser = argparse.ArgumentParser(description="Scrape ACMDP mineral data")
    parser.add_argument("--limit", type=int, default=0, help="Limit records (0=all)")
    parser.add_argument("--concurrency", type=int, default=5, help="Concurrent requests (default 5)")
    parser.add_argument("--no-resume", action="store_true", help="Ignore data/acmdp_cache.jsonl and refetch everything")
    args = parser.parse_args()

    records = await scrape_all(limit=args.limit, concurrency=args.concurrency, resume=not args.no_resume)

    os.makedirs(DATA_DIR, exist_ok=True)

    json_path = os.path.join(DATA_DIR, "acmdp_all.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(records, f, indent=2, ensure_ascii=False)

    csv_path = os.path.join(DATA_DIR, "acmdp_all.csv")
    save_csv(records, csv_path)

    print(f"\nSaved {len(records)} records:")
    print(f"  JSON: {json_path}")
    print(f"  CSV:  {csv_path}")
    print(f"  CSV size: {os.path.getsize(csv_path) / 1024 / 1024:.1f} MB")
    print(f"\nNext: python external-data/acmdp_to_layer.py {json_path}")


if __name__ == "__main__":
    asyncio.run(main())
