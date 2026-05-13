#!/usr/bin/env bash
# setPeer on both sides for Counter v3.

set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
PATH="$HOME/.local/bin:$PATH"

: "${COUNTER_V3_ETH:?}"; : "${COUNTER_V3_STARKNET:?}"
: "${COUNTER_V3_STARKNET_PEER_BYTES32:?}"
: "${DST_EID_STARKNET:?}"; : "${DST_EID_ETHEREUM:?}"
: "${PRIVATE_KEY:?}"; : "${SEPOLIA_RPC_URL:?}"

# A. EVM → register Starknet peer
echo ">> EVM setPeer($DST_EID_STARKNET, $COUNTER_V3_STARKNET_PEER_BYTES32)"
cast send "$COUNTER_V3_ETH" \
  "setPeer(uint32,bytes32)" \
  "$DST_EID_STARKNET" \
  "$COUNTER_V3_STARKNET_PEER_BYTES32" \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" 2>&1 | tail -10

# B. Starknet → register EVM peer
EVM_HEX=$(echo "$COUNTER_V3_ETH" | tr 'A-F' 'a-f' | sed 's/^0x//')
PADDED32="0x$(printf '%064s' "$EVM_HEX" | tr ' ' '0')"
echo ">> SN set_peer($DST_EID_ETHEREUM, $PADDED32)"
sncast \
  --accounts-file "$STARKNET_ACCOUNTS_FILE" \
  --account "$STARKNET_ACCOUNT" \
  invoke \
  --url "$STARKNET_RPC_URL" \
  --contract-address "$COUNTER_V3_STARKNET" \
  --function set_peer \
  --arguments "$DST_EID_ETHEREUM, Bytes32 { value: $PADDED32 }" 2>&1 | tail -5

echo "============================================================="
echo "  Counter v3 peers wired both directions."
echo "  Next: ./scripts/13_fund_counter_v3_strk.sh"
echo "============================================================="
