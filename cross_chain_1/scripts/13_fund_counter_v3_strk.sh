#!/usr/bin/env bash
# Transfer STRK from the Starknet burner to Counter v3's contract address.

set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
PATH="$HOME/.local/bin:$PATH"

: "${COUNTER_V3_STARKNET:?}"; : "${STRK_ADDRESS:?}"
: "${COUNTER_V3_STRK_FUND_AMOUNT:?}"
: "${STARKNET_ACCOUNT:?}"; : "${STARKNET_ACCOUNTS_FILE:?}"; : "${STARKNET_RPC_URL:?}"

echo ">> Transferring $COUNTER_V3_STRK_FUND_AMOUNT wei-STRK to $COUNTER_V3_STARKNET..."
sncast \
  --accounts-file "$STARKNET_ACCOUNTS_FILE" \
  --account "$STARKNET_ACCOUNT" \
  invoke \
  --url "$STARKNET_RPC_URL" \
  --contract-address "$STRK_ADDRESS" \
  --function transfer \
  --arguments "$COUNTER_V3_STARKNET, ${COUNTER_V3_STRK_FUND_AMOUNT}_u256" 2>&1 | tail -5

# Verify balance
BAL=$(sncast \
  --accounts-file "$STARKNET_ACCOUNTS_FILE" \
  --account "$STARKNET_ACCOUNT" \
  call \
  --url "$STARKNET_RPC_URL" \
  --contract-address "$STRK_ADDRESS" \
  --function balance_of \
  --arguments "$COUNTER_V3_STARKNET" 2>&1 | tail -5)
echo ">> Counter v3 STRK balance: $BAL"
echo "============================================================="
echo "  Funded. Next: ./scripts/15_aba_smoke_test.sh"
echo "============================================================="
