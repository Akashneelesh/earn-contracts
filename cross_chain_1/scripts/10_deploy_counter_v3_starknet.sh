#!/usr/bin/env bash
# Deploy Counter v3 (ABA-capable) on Starknet Sepolia.
# Mirrors scripts/02 but for the Counter contract and v3 env vars.

set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
PATH="$HOME/.local/bin:$PATH"

: "${STARKNET_RPC_URL:?}"; : "${STARKNET_ACCOUNT:?}"; : "${STARKNET_ACCOUNTS_FILE:?}"
: "${LZ_ENDPOINT_STARKNET:?}"; : "${STRK_ADDRESS:?}"

OWNER=$(python3 -c "import json; d=json.load(open('$STARKNET_ACCOUNTS_FILE')); v=d.get('alpha-sepolia',{}).get('$STARKNET_ACCOUNT') or d.get('sepolia',{}).get('$STARKNET_ACCOUNT'); print(v['address'])")

echo ">> scarb build..."
(cd starknet_oapp && scarb build) > /dev/null

echo ">> Declaring Counter..."
PROJECT_ROOT=$(pwd)
DECLARE_OUT=$(cd starknet_oapp && sncast \
  --accounts-file "$PROJECT_ROOT/${STARKNET_ACCOUNTS_FILE#./}" \
  --account "$STARKNET_ACCOUNT" \
  declare \
  --url "$STARKNET_RPC_URL" \
  --contract-name Counter 2>&1 | tee /tmp/sncast_declare_counter_v3.log)

CLASS_HASH=$(echo "$DECLARE_OUT" | grep -oE 'class_hash:\s*0x[a-fA-F0-9]+' | head -1 | grep -oE '0x[a-fA-F0-9]+')
if [[ -z "$CLASS_HASH" ]]; then
  CLASS_HASH=$(grep -oE '0x[a-fA-F0-9]{60,64}' /tmp/sncast_declare_counter_v3.log | head -1)
fi
echo ">> Class hash: $CLASS_HASH"

# Wait for the new class to appear at the deploy node (sncast 0.60 has indexing lag).
echo ">> Waiting for declare to index..."
for i in $(seq 1 12); do
  sleep 5
  TEST=$(sncast \
    --accounts-file "$STARKNET_ACCOUNTS_FILE" \
    --account "$STARKNET_ACCOUNT" \
    deploy \
    --url "$STARKNET_RPC_URL" \
    --class-hash "$CLASS_HASH" \
    --arguments "$LZ_ENDPOINT_STARKNET $OWNER $STRK_ADDRESS" 2>&1 | tee /tmp/sncast_deploy_counter_v3.log || true)
  if echo "$TEST" | grep -qE 'contract_address:\s*0x[a-fA-F0-9]+'; then
    break
  fi
  echo "[$((i*5))s] still pending..."
done

CONTRACT_ADDR=$(grep -oE 'contract_address:\s*0x[a-fA-F0-9]+' /tmp/sncast_deploy_counter_v3.log | head -1 | grep -oE '0x[a-fA-F0-9]+')
echo ">> Counter v3 deployed at: $CONTRACT_ADDR"

# Persist
PADDED=$(python3 -c "a='$CONTRACT_ADDR'.lower().removeprefix('0x'); print('0x'+a.rjust(64,'0'))")
for key in COUNTER_V3_STARKNET COUNTER_V3_STARKNET_PEER_BYTES32; do
  if grep -q "^${key}=" .env; then
    if [[ "$key" == "COUNTER_V3_STARKNET" ]]; then
      sed -i.bak "s|^${key}=.*|${key}=$CONTRACT_ADDR|" .env
    else
      sed -i.bak "s|^${key}=.*|${key}=$PADDED|" .env
    fi
  else
    if [[ "$key" == "COUNTER_V3_STARKNET" ]]; then
      echo "${key}=$CONTRACT_ADDR" >> .env
    else
      echo "${key}=$PADDED" >> .env
    fi
  fi
done
rm -f .env.bak

echo "============================================================="
echo "  Counter v3 (Cairo) deployed."
echo "    COUNTER_V3_STARKNET=$CONTRACT_ADDR"
echo "    COUNTER_V3_STARKNET_PEER_BYTES32=$PADDED"
echo "  Next: ./scripts/11_deploy_counter_trigger_v3_eth.sh"
echo "============================================================="
