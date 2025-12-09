#!/usr/bin/env bash
#
# download - Downloader that can extract ALDI store data from HTML to JSON
# Usage: ./download.sh URL [--extract-stores]

set -e

# Function to detect MIME type and return appropriate extension
get_file_extension() {
  local file_path="$1"
  local mime_type=$(file --mime-type -b "$file_path")
  local extension=""
  
  case "$mime_type" in
    text/html)                extension=".html" ;;
    application/json)         extension=".json" ;;
    text/plain)               extension=".txt" ;;
    application/javascript)   extension=".js" ;;
    application/xml|text/xml) extension=".xml" ;;
    application/pdf)          extension=".pdf" ;;
    image/jpeg)               extension=".jpg" ;;
    image/png)                extension=".png" ;;
    image/gif)                extension=".gif" ;;
    image/svg+xml)            extension=".svg" ;;
    application/zip)          extension=".zip" ;;
    application/gzip)         extension=".gz" ;;
    application/x-tar)        extension=".tar" ;;
    application/x-bzip2)      extension=".bz2" ;;
    *)                        extension=".html" ;;
  esac
  
  echo "$extension"
}

# Function to extract ALDI store data from HTML
extract_stores() {
  local html_file="$1"
  local output_file="$2"
  
  python3 << PYTHON_SCRIPT
import re
import json
from html.parser import HTMLParser

class ALDIStoreParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.stores = []
        self.current_store = None
        self.in_store_link = False
        self.in_store_name = False
        self.page_title = None
        self.page_location = None
        self.in_title = False
        self.in_geo = False
        
    def handle_starttag(self, tag, attrs):
        attrs_dict = dict(attrs)
        
        # Capture page title
        if tag == 'span' and 'Hero-title' in attrs_dict.get('class', ''):
            self.in_title = True
        
        # Capture location/geo info
        if tag == 'span' and 'Hero-geo' in attrs_dict.get('class', ''):
            self.in_geo = True
        
        # Look for store links
        if tag == 'a' and 'Directory-listLink' in attrs_dict.get('class', ''):
            self.in_store_link = True
            href = attrs_dict.get('href', '')
            count = attrs_dict.get('data-count', '(1)')
            # Parse count - remove parentheses
            count_num = int(re.sub(r'[^\d]', '', count) or '1')
            
            # Parse URL path to extract details
            parts = href.strip('/').split('/')
            state = parts[0] if len(parts) > 0 else ''
            suburb = parts[1] if len(parts) > 1 else ''
            address_slug = parts[2] if len(parts) > 2 else ''
            
            # Convert address slug to readable format
            address = address_slug.replace('-', ' ').title() if address_slug else ''
            
            self.current_store = {
                'url_path': href,
                'state': state.upper(),
                'suburb': suburb.title(),
                'address_slug': address_slug,
                'address': address,
                'store_count': count_num
            }
        
        # Look for store name span
        if tag == 'span' and 'Directory-listLinkText' in attrs_dict.get('class', ''):
            self.in_store_name = True
    
    def handle_endtag(self, tag):
        if tag == 'a' and self.in_store_link:
            if self.current_store:
                self.stores.append(self.current_store)
                self.current_store = None
            self.in_store_link = False
        if tag == 'span':
            self.in_store_name = False
            self.in_title = False
            self.in_geo = False
    
    def handle_data(self, data):
        if self.in_store_name and self.current_store:
            self.current_store['name'] = data.strip()
        if self.in_title:
            self.page_title = data.strip()
        if self.in_geo:
            self.page_location = data.strip()

# Read and parse the HTML
with open('${html_file}', 'r', encoding='utf-8') as f:
    html_content = f.read()

parser = ALDIStoreParser()
parser.feed(html_content)

# Build the output structure
output = {
    'source': 'ALDI Store Locator',
    'page_title': parser.page_title,
    'location': parser.page_location,
    'total_stores': len(parser.stores),
    'stores': parser.stores
}

# Write JSON output
with open('${output_file}', 'w', encoding='utf-8') as f:
    json.dump(output, f, indent=2, ensure_ascii=False)

print(f"Extracted {len(parser.stores)} stores to ${output_file}")
PYTHON_SCRIPT
}

# Parse arguments
EXTRACT_STORES=false
URL=""

for arg in "$@"; do
  case "$arg" in
    --extract-stores)
      EXTRACT_STORES=true
      ;;
    *)
      if [ -z "$URL" ]; then
        URL="$arg"
      fi
      ;;
  esac
done

# Check if URL provided
if [ -z "$URL" ]; then
  echo "Usage: $0 URL [--extract-stores]"
  echo ""
  echo "Options:"
  echo "  --extract-stores  Extract ALDI store data from HTML to JSON"
  exit 1
fi

# Validate URL format
if [[ ! "$URL" =~ ^https?:// ]]; then
  echo "Error: URL must start with http:// or https://"
  exit 1
fi

# Create temporary file
TEMP_FILE=$(mktemp)

# Download the file
echo "Downloading $URL"
curl -s -L "$URL" -o "$TEMP_FILE" || {
  echo "Error: Failed to download $URL"
  rm -f "$TEMP_FILE"
  exit 1
}

# Get file extension based on MIME type
EXTENSION=$(get_file_extension "$TEMP_FILE")

# Construct filename from the URL
FILENAME=$(echo "$URL" | sed -E 's|^https?://||' | sed -E 's|^www\.||' | sed 's|/$||' | sed 's|/|-|g')

# Handle store extraction
if [ "$EXTRACT_STORES" = true ] && [ "$EXTENSION" = ".html" ]; then
  FILENAME="${FILENAME}-stores.json"
  CURRENT_DIR="$(pwd)"
  FULL_PATH="${CURRENT_DIR}/${FILENAME}"
  
  # Extract stores to JSON
  extract_stores "$TEMP_FILE" "$FULL_PATH"
  rm -f "$TEMP_FILE"
else
  # Normal download behaviour
  FILENAME="${FILENAME}${EXTENSION}"
  
  if [ "$FILENAME" = "${EXTENSION}" ]; then
    FILENAME="index${EXTENSION}"
  fi
  
  CURRENT_DIR="$(pwd)"
  FULL_PATH="${CURRENT_DIR}/${FILENAME}"
  
  # Pretty-print JSON if applicable
  if [ "$EXTENSION" = ".json" ]; then
    PRETTY_TEMP=$(mktemp)
    if command -v jq &> /dev/null; then
      if jq . "$TEMP_FILE" > "$PRETTY_TEMP" 2>/dev/null; then
        mv "$PRETTY_TEMP" "$TEMP_FILE"
      else
        rm -f "$PRETTY_TEMP"
      fi
    else
      rm -f "$PRETTY_TEMP"
    fi
  fi
  
  mv "$TEMP_FILE" "$FULL_PATH"
  echo "Saved to $FULL_PATH"
fi
