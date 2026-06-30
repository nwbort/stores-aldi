#!/usr/bin/env python3
"""Scrape ALDI Australia store data.

ALDI AU migrated their store locator (https://store.aldi.com.au/, now
https://www.aldi.com.au/storelocator) from a static, server-rendered Yext
directory to a Nuxt single-page app. The old approach of parsing
`Directory-listLink` anchors out of per-state HTML pages no longer works -
those classes don't exist anymore, so the scraper was silently producing
`"total_stores": 0` for every state.

The new locator is powered by Uberall. All Australian stores are available
from a single Uberall "storefinder" endpoint, so we fetch that once and write
both a combined file and per-state files (keeping the historical filenames so
the git history stays continuous).
"""

import json
import sys
import urllib.error
import urllib.request

# Uberall storefinder key for ALDI Australia (from the storelocator front-end).
UBERALL_KEY = "Lbio8mFv9Ysxu1YhX4ARiQTNKOHNlE"
API_URL = f"https://uberall.com/api/storefinders/{UBERALL_KEY}/locations/all"

# States/territories where ALDI operates, keyed by the lowercase slug used in
# the historical output filenames.
STATE_SLUGS = ["act", "nsw", "qld", "sa", "vic", "wa"]

# Map the various ways a state can appear in the data to a canonical code.
STATE_ALIASES = {
    "act": "ACT",
    "australian capital territory": "ACT",
    "nsw": "NSW",
    "new south wales": "NSW",
    "qld": "QLD",
    "queensland": "QLD",
    "sa": "SA",
    "south australia": "SA",
    "vic": "VIC",
    "victoria": "VIC",
    "wa": "WA",
    "western australia": "WA",
    "nt": "NT",
    "northern territory": "NT",
    "tas": "TAS",
    "tasmania": "TAS",
}

DAYS = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]


def fetch_locations():
    """Return the raw list of location dicts from the Uberall API."""
    req = urllib.request.Request(
        API_URL,
        headers={
            "User-Agent": (
                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
            ),
            "Accept": "application/json",
            "Referer": "https://www.aldi.com.au/storelocator",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.load(resp)

    status = data.get("status")
    if status != "SUCCESS":
        raise RuntimeError(f"Unexpected API status: {status!r}")

    locations = data.get("response", {}).get("locations", [])
    # Some Uberall responses wrap each entry as {"location": {...}}.
    normalised = []
    for entry in locations:
        if isinstance(entry, dict) and "location" in entry and isinstance(entry["location"], dict):
            normalised.append(entry["location"])
        else:
            normalised.append(entry)
    return normalised


def canonical_state(loc):
    """Best-effort 2-3 letter state code for a location."""
    for key in ("province", "state", "region", "regionIsoCode", "regionName"):
        value = loc.get(key)
        if value:
            code = STATE_ALIASES.get(str(value).strip().lower())
            if code:
                return code
    return None


def parse_opening_hours(raw):
    """Convert Uberall openingHours rows into a list of readable strings."""
    if not raw:
        return []
    hours = []
    for rule in raw:
        try:
            day = DAYS[int(rule.get("dayOfWeek", 0)) - 1]
        except (ValueError, IndexError, TypeError):
            continue
        if rule.get("closed"):
            hours.append(f"{day}: closed")
            continue
        ranges = []
        for i in (1, 2):
            start = rule.get(f"from{i}")
            end = rule.get(f"to{i}")
            if start and end:
                ranges.append(f"{start}-{end}")
        if ranges:
            hours.append(f"{day}: {', '.join(ranges)}")
    return hours


def normalise_store(loc):
    """Map a raw Uberall location dict to our output schema."""
    street = loc.get("streetAndNumber") or ""
    extra = loc.get("addressExtra") or ""
    address = ", ".join(part for part in (street, extra) if part)

    lat = loc.get("lat", loc.get("latitude"))
    lng = loc.get("lng", loc.get("longitude"))

    return {
        "id": loc.get("identifier") or loc.get("id"),
        "name": loc.get("name"),
        "address": address,
        "street": street,
        "suburb": loc.get("city"),
        "state": canonical_state(loc),
        "postcode": loc.get("zip") or loc.get("postcode"),
        "country": loc.get("country"),
        "latitude": lat,
        "longitude": lng,
        "phone": loc.get("phone"),
        "opening_hours": parse_opening_hours(loc.get("openingHours")),
    }


def write_json(path, page_title, location, stores):
    output = {
        "source": "ALDI Store Locator",
        "page_title": page_title,
        "location": location,
        "total_stores": len(stores),
        "stores": stores,
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)


def main():
    locations = fetch_locations()
    stores = [normalise_store(loc) for loc in locations]
    # Sort for stable, readable diffs.
    stores.sort(key=lambda s: (s.get("state") or "", s.get("suburb") or "", s.get("name") or ""))

    write_json("store.aldi.com.au-stores.json", "ALDI Store Locator", "Australia", stores)
    print(f"Extracted {len(stores)} stores to store.aldi.com.au-stores.json")

    for slug in STATE_SLUGS:
        code = STATE_ALIASES[slug]
        state_stores = [s for s in stores if s.get("state") == code]
        path = f"store.aldi.com.au-{slug}-stores.json"
        write_json(path, code, code, state_stores)
        print(f"Extracted {len(state_stores)} stores to {path}")

    if not stores:
        # Don't fail the workflow, but make the regression obvious in the logs.
        print("WARNING: no stores extracted - the API response may have changed.", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except (urllib.error.URLError, urllib.error.HTTPError) as exc:
        print(f"ERROR: failed to fetch store data: {exc}", file=sys.stderr)
        sys.exit(1)
