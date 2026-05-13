#!/usr/bin/env bash
# Static-file server on :8765 so MetaMask can talk to the page.
cd "$(dirname "$0")"
echo "serving http://localhost:8765"
python3 -m http.server 8765
