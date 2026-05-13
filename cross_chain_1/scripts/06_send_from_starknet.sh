#!/usr/bin/env bash
# Send a string FROM Starknet Sepolia TO Ethereum Sepolia.
# Approves STRK, calls send_string, polls EVM for delivery.

set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
PATH="$HOME/.local/bin:$PATH"

: "${STARKNET_RPC_URL:?}"; : "${STARKNET_ACCOUNT:?}"; : "${STARKNET_ACCOUNTS_FILE:?}"
: "${STARKNET_OAPP_ADDRESS:?}"; : "${STRK_ADDRESS:?}"
: "${DST_EID_ETHEREUM:?}"; : "${SENDER_ADDRESS:?}"; : "${SEPOLIA_RPC_URL:?}"
MESSAGE="${MESSAGE:-hello from starknet}"
GAS_LIMIT="${GAS_LIMIT:-200000}"

# --- 1. Quote the fee ----------------------------------------------------
echo ">> Quoting send fee..."
QUOTE_OUT=$(sncast \
  --accounts-file "$STARKNET_ACCOUNTS_FILE" \
  --account "$STARKNET_ACCOUNT" \
  call \
  --url "$STARKNET_RPC_URL" \
  --contract-address "$STARKNET_OAPP_ADDRESS" \
  --function quote_send_string \
  --arguments "$DST_EID_ETHEREUM, \"$MESSAGE\", ${GAS_LIMIT}_u128")
echo "$QUOTE_OUT" | grep "Response:" || echo "$QUOTE_OUT"
NATIVE_FEE=$(echo "$QUOTE_OUT" | grep -oE 'native_fee:\s*[0-9]+' | grep -oE '[0-9]+')
echo ">> native_fee = $NATIVE_FEE wei-STRK"

# --- 2. Approve STRK to OApp (1.5x the quote as headroom) ----------------
APPROVE_AMT=$(python3 -c "print($NATIVE_FEE * 3 // 2)")
echo ">> Approving $APPROVE_AMT wei-STRK to OApp..."
sncast \
  --accounts-file "$STARKNET_ACCOUNTS_FILE" \
  --account "$STARKNET_ACCOUNT" \
  invoke \
  --url "$STARKNET_RPC_URL" \
  --contract-address "$STRK_ADDRESS" \
  --function approve \
  --arguments "$STARKNET_OAPP_ADDRESS, ${APPROVE_AMT}_u256" 2>&1 | tail -5

# --- 3. Send -------------------------------------------------------------
echo ">> Sending '$MESSAGE' to EID $DST_EID_ETHEREUM..."
SEND_OUT=$(sncast \
  --accounts-file "$STARKNET_ACCOUNTS_FILE" \
  --account "$STARKNET_ACCOUNT" \
  invoke \
  --url "$STARKNET_RPC_URL" \
  --contract-address "$STARKNET_OAPP_ADDRESS" \
  --function send_string \
  --arguments "$DST_EID_ETHEREUM, \"$MESSAGE\", ${GAS_LIMIT}_u128")
echo "$SEND_OUT" | tail -5
SN_TX=$(echo "$SEND_OUT" | grep -oE 'Transaction Hash:\s*0x[a-fA-F0-9]+' | grep -oE '0x[a-fA-F0-9]+')

echo ""
echo "============================================================="
echo "  Starknet tx: $SN_TX"
echo "  LZ Scan:     https://testnet.layerzeroscan.com/tx/$SN_TX"
echo ""
echo "  Polling EVM messageCount every 30s (up to ~30 min)..."
echo "  L2->L1 is slow: 5-15min typical for delivery."
echo "============================================================="

# --- 4. Poll EVM side ----------------------------------------------------
for i in $(seq 1 60); do
  COUNT=$(cast call "$SENDER_ADDRESS" "messageCount()(uint64)" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "?")
  echo "[$((i*30))s] messageCount=$COUNT"
  if [[ "$COUNT" != "0" && "$COUNT" != "?" && -n "$COUNT" ]]; then
    echo ""
    echo ">> DELIVERED"
    echo "lastMessage: $(cast call "$SENDER_ADDRESS" "lastMessage()(string)" --rpc-url "$SEPOLIA_RPC_URL")"
    echo "lastSrcEid:  $(cast call "$SENDER_ADDRESS" "lastSrcEid()(uint32)" --rpc-url "$SEPOLIA_RPC_URL")"
    exit 0
  fi
  sleep 30
done
echo "Not delivered after 30 min. Check LZ Scan link above."
exit 1
