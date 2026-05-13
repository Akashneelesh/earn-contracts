#!/usr/bin/env bash
# Registers each side as the other's peer. Must be done before any message can flow.

set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
PATH="$HOME/.local/bin:$PATH"

: "${SENDER_ADDRESS:?run 03 first}"; : "${STARKNET_OAPP_ADDRESS:?run 02 first}"
: "${STARKNET_PEER_BYTES32:?run 02 first}"; : "${DST_EID_STARKNET:?}"; : "${DST_EID_ETHEREUM:?}"
: "${PRIVATE_KEY:?}"; : "${SEPOLIA_RPC_URL:?}"

# --- A. EVM → register Starknet peer ---------------------------------------
echo ">> Setting Starknet peer on the EVM sender..."
cd eth_sender
SENDER_ADDRESS=$SENDER_ADDRESS \
DST_EID_STARKNET=$DST_EID_STARKNET \
STARKNET_PEER_BYTES32=$STARKNET_PEER_BYTES32 \
forge script script/SetPeer.s.sol --rpc-url "$SEPOLIA_RPC_URL" --broadcast -vv | tail -20
cd ..

# --- B. Starknet → register EVM peer ---------------------------------------
# Cairo's set_peer takes (eid: u32, peer: Bytes32). sncast 0.60's Cairo-like
# calldata wants the literal struct: `Bytes32 { value: <u256_hex> }`.
EVM_HEX=$(echo "$SENDER_ADDRESS" | tr 'A-F' 'a-f' | sed 's/^0x//')
PADDED32="0x$(printf '%064s' "$EVM_HEX" | tr ' ' '0')"

echo ">> Setting EVM peer on the Starknet receiver (eid=$DST_EID_ETHEREUM, peer=$PADDED32)..."
sncast \
  --accounts-file "$STARKNET_ACCOUNTS_FILE" \
  --account "$STARKNET_ACCOUNT" \
  invoke \
  --url "$STARKNET_RPC_URL" \
  --contract-address "$STARKNET_OAPP_ADDRESS" \
  --function set_peer \
  --arguments "$DST_EID_ETHEREUM, Bytes32 { value: $PADDED32 }"

echo ""
echo "============================================================="
echo "  Peers wired both directions."
echo "  Next: ./scripts/05_send.sh"
echo "============================================================="
