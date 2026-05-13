#!/usr/bin/env bash
# Creates a Starknet Sepolia account and prints the address that needs funding.
# Run once. Idempotent: skips creation if the account already exists.

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo "ERROR: cross_chain/.env not found. Copy .env.example to .env first." >&2
  exit 1
fi
set -a; source .env; set +a

: "${STARKNET_RPC_URL:?STARKNET_RPC_URL missing in .env}"
: "${STARKNET_ACCOUNT:?STARKNET_ACCOUNT missing in .env}"
: "${STARKNET_ACCOUNTS_FILE:?STARKNET_ACCOUNTS_FILE missing in .env}"

PATH="$HOME/.local/bin:$PATH"

ACCOUNTS_FILE_ABS="$(pwd)/${STARKNET_ACCOUNTS_FILE#./}"

if [[ -f "$ACCOUNTS_FILE_ABS" ]] && grep -q "\"$STARKNET_ACCOUNT\"" "$ACCOUNTS_FILE_ABS" 2>/dev/null; then
  echo ">> Account '$STARKNET_ACCOUNT' already exists in $ACCOUNTS_FILE_ABS"
  ADDR=$(python3 -c "import json; d=json.load(open('$ACCOUNTS_FILE_ABS')); v=d.get('alpha-sepolia',{}).get('$STARKNET_ACCOUNT') or d.get('sepolia',{}).get('$STARKNET_ACCOUNT'); print(v['address'])")
  echo ">> Address: $ADDR"
  echo ">> If this account has never been deployed on-chain, fund it (~0.005 ETH or 5 STRK), then run script 02."
  exit 0
fi

echo ">> Creating new Starknet Sepolia account '$STARKNET_ACCOUNT'..."
sncast \
  --accounts-file "$STARKNET_ACCOUNTS_FILE" \
  --account "$STARKNET_ACCOUNT" \
  account create \
  --url "$STARKNET_RPC_URL" \
  --type oz \
  --add-profile "$STARKNET_ACCOUNT" 2>&1 | tee /tmp/sncast_create.log

ADDR=$(grep -oE '0x[a-fA-F0-9]{40,}' /tmp/sncast_create.log | head -1)
echo ""
echo "============================================================="
echo "  NEXT STEP — fund this address before running script 02:"
echo ""
echo "    $ADDR"
echo ""
echo "  Faucets (need ~0.005 ETH or 5 STRK for deploy + setPeer):"
echo "    https://starknet-faucet.vercel.app/"
echo "    https://blastapi.io/faucets/starknet-sepolia-eth"
echo "    https://blastapi.io/faucets/starknet-sepolia-strk"
echo "============================================================="
