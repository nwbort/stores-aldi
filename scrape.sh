#!/bin/bash
set -e

# Keep a copy of the store locator landing page for reference / debugging.
./download.sh 'https://store.aldi.com.au/'

# ALDI AU's store locator is a Nuxt SPA backed by the Uberall storefinder API,
# so the store list is fetched from that API rather than parsed out of HTML.
python3 scrape_stores.py
