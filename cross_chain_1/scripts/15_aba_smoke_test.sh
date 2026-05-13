#!/usr/bin/env bash
# End-to-end ABA smoke test:
#   - Snapshot both counters
#   - Call triggerAbaIncrement(40500, 5, 3) on Ethereum
#   - Poll Starknet count until it goes up by 5
#   - Poll Ethereum count until it goes up by 3

set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
PATH="$HOME/.local/bin:$PATH"

: "${COUNTER_V3_ETH:?}"; : "${COUNTER_V3_STARKNET:?}"
: "${DST_EID_STARKNET:?}"; : "${PRIVATE_KEY:?}"; : "${SEPOLIA_RPC_URL:?}"
: "${STARKNET_ACCOUNT:?}"; : "${STARKNET_ACCOUNTS_FILE:?}"; : "${STARKNET_RPC_URL:?}"

BY_SN="${1:-5}"
BY_ETH="${2:-3}"

read_eth_count() {
  cast call --rpc-url "$SEPOLIA_RPC_URL" "$COUNTER_V3_ETH" "count()(uint64)" \
    | awk '{print $1}'
}
read_sn_count() {
  sncast --accounts-file "$STARKNET_ACCOUNTS_FILE" --account "$STARKNET_ACCOUNT" \
    call --url "$STARKNET_RPC_URL" \
    --contract-address "$COUNTER_V3_STARKNET" --function count \
    2>&1 | grep -oE '0x[a-fA-F0-9]+' | tail -1 | python3 -c "import sys; print(int(sys.stdin.read().strip(), 16))"
}

PRE_ETH=$(read_eth_count)
PRE_SN=$(read_sn_count)
echo ">> Pre: eth=$PRE_ETH, sn=$PRE_SN"

OPTS=$(cast call --rpc-url "$SEPOLIA_RPC_URL" "$COUNTER_V3_ETH" "defaultAbaOptions()(bytes)")
echo ">> opts=$OPTS"

FEE=$(cast call --rpc-url "$SEPOLIA_RPC_URL" "$COUNTER_V3_ETH" \
  "quoteAbaIncrement(uint32,uint64,uint64,bytes)((uint256,uint256))" \
  "$DST_EID_STARKNET" "$BY_SN" "$BY_ETH" "$OPTS")
NATIVE_FEE=$(echo "$FEE" | grep -oE '[0-9]+' | head -1)
echo ">> native_fee=$NATIVE_FEE wei"

echo ">> Sending triggerAbaIncrement($DST_EID_STARKNET, $BY_SN, $BY_ETH)..."
TX=$(cast send --rpc-url "$SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY" \
  --value "$NATIVE_FEE" \
  "$COUNTER_V3_ETH" \
  "triggerAbaIncrement(uint32,uint64,uint64,bytes)" \
  "$DST_EID_STARKNET" "$BY_SN" "$BY_ETH" "$OPTS" 2>&1 | tee /tmp/aba_send.log | grep transactionHash | awk '{print $2}')
echo ">> ETH tx: $TX"
echo ">> LZ Scan: https://testnet.layerzeroscan.com/tx/$TX"

WANT_SN=$((PRE_SN + BY_SN))
echo ">> Polling SN every 10s for count >= $WANT_SN (up to 5 min)..."
for i in $(seq 1 30); do
  sleep 10
  CUR=$(read_sn_count || echo "$PRE_SN")
  echo "[$((i*10))s] sn=$CUR"
  if [[ "$CUR" -ge "$WANT_SN" ]]; then
    echo ">> SN leg confirmed."
    break
  fi
done

WANT_ETH=$((PRE_ETH + BY_ETH))
echo ">> Polling ETH every 15s for count >= $WANT_ETH (up to 8 min)..."
for i in $(seq 1 32); do
  sleep 15
  CUR=$(read_eth_count || echo "$PRE_ETH")
  echo "[$((i*15))s] eth=$CUR"
  if [[ "$CUR" -ge "$WANT_ETH" ]]; then
    echo ">> ETH leg confirmed. ABA complete."
    exit 0
  fi
done

echo "Timed out waiting for ETH leg. Check LZ Scan link above."
exit 1
