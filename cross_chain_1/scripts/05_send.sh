#!/usr/bin/env bash
# Sends one message from Ethereum Sepolia to the Starknet OApp.
# Then polls the Starknet contract for delivery.

set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
PATH="$HOME/.local/bin:$PATH"

: "${SENDER_ADDRESS:?}"; : "${STARKNET_OAPP_ADDRESS:?}"
: "${DST_EID_STARKNET:?}"; : "${PRIVATE_KEY:?}"; : "${SEPOLIA_RPC_URL:?}"
MESSAGE="${MESSAGE:-hello from ethereum}"

echo ">> Sending '$MESSAGE' from Sepolia to Starknet Sepolia..."
cd eth_sender
SENDER_ADDRESS=$SENDER_ADDRESS \
DST_EID_STARKNET=$DST_EID_STARKNET \
MESSAGE="$MESSAGE" \
forge script script/Send.s.sol --rpc-url "$SEPOLIA_RPC_URL" --broadcast -vv | tee /tmp/forge_send.log | tail -20

GUID=$(grep -oE '0x[a-fA-F0-9]{64}' /tmp/forge_send.log | tail -1)
TX=$(grep -oE 'transactionHash.*0x[a-fA-F0-9]{64}' /tmp/forge_send.log | head -1 | grep -oE '0x[a-fA-F0-9]{64}')

cd ..
echo ""
echo "============================================================="
echo "  ETH tx:  $TX"
echo "  guid:    $GUID"
echo "  LZ Scan: https://testnet.layerzeroscan.com/tx/$TX"
echo ""
echo "  Polling Starknet receiver every 15s (up to 5min)..."
echo "============================================================="

for i in $(seq 1 20); do
  sleep 15
  CUR=$(sncast \
    --accounts-file "$STARKNET_ACCOUNTS_FILE" \
    --account "$STARKNET_ACCOUNT" \
    call \
    --url "$STARKNET_RPC_URL" \
    --contract-address "$STARKNET_OAPP_ADDRESS" \
    --function message_count 2>&1 | grep -oE '0x[a-fA-F0-9]+' | tail -1 || true)
  echo "[$((i*15))s] message_count = $CUR"
  if [[ -n "$CUR" && "$CUR" != "0x0" ]]; then
    echo ""
    echo ">> Delivered! Reading last_message..."
    sncast \
      --accounts-file "$STARKNET_ACCOUNTS_FILE" \
      --account "$STARKNET_ACCOUNT" \
      call \
      --url "$STARKNET_RPC_URL" \
      --contract-address "$STARKNET_OAPP_ADDRESS" \
      --function last_message
    exit 0
  fi
done

echo ""
echo "Not delivered after 5 minutes. Check the LZ scan link above for status."
exit 1
