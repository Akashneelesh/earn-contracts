#!/usr/bin/env bash
# Owner-only: update Counter v3 return options. Args: [GAS] [VALUE].
# Falls back to .env RETURN_LEG_GAS / RETURN_LEG_VALUE if not provided.

set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
PATH="$HOME/.local/bin:$PATH"

: "${COUNTER_V3_STARKNET:?}"
: "${STARKNET_ACCOUNT:?}"; : "${STARKNET_ACCOUNTS_FILE:?}"; : "${STARKNET_RPC_URL:?}"

GAS="${1:-${RETURN_LEG_GAS:-200000}}"
VALUE="${2:-${RETURN_LEG_VALUE:-0}}"

echo ">> set_return_options(gas=$GAS, value=$VALUE)"
sncast \
  --accounts-file "$STARKNET_ACCOUNTS_FILE" \
  --account "$STARKNET_ACCOUNT" \
  invoke \
  --url "$STARKNET_RPC_URL" \
  --contract-address "$COUNTER_V3_STARKNET" \
  --function set_return_options \
  --arguments "${GAS}_u128, ${VALUE}_u128" 2>&1 | tail -5
echo "done."
