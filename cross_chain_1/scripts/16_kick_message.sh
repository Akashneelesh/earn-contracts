#!/usr/bin/env bash
# Manually deliver a stuck LayerZero V2 message on Starknet Sepolia.
#
# When the LZ Starknet executor service lags, anyone can call
# endpoint.lz_receive(...) directly to push a sealed message through.
# This script wraps a Node.js helper (uses starknet.js for ByteArray /
# Bytes32 / u256 encoding which sncast can't express).
#
# Prerequisites: the source-side tx's verification.sealer.status MUST be
# SUCCEEDED on LZ scan. (DVN attestation committed to the SN receive lib.)
# If not, the endpoint will revert with PAYLOAD_HASH_NOT_FOUND.
#
# Usage:
#   ./scripts/16_kick_message.sh <source-tx-hash>
#
# Examples:
#   ./scripts/16_kick_message.sh 0x9f4f7a57bd5aa4d6...   # an ABA send
#   ./scripts/16_kick_message.sh 0xdc51e81d96d68961...   # a plain single-hop

set -euo pipefail
cd "$(dirname "$0")/.."

TX="${1:-}"
if [[ -z "$TX" ]]; then
  echo "usage: $0 <source-tx-hash>"
  exit 2
fi

HERE="scripts/lib/lz-kick"
if [[ ! -d "$HERE/node_modules" ]]; then
  echo ">> installing starknet.js (first run only)..."
  (cd "$HERE" && npm install --no-audit --no-fund) > /dev/null
fi

exec node "$HERE/kick.mjs" "$TX"
