#!/usr/bin/env bash
# Deploys the account itself (one-time) + StringReceiver, then writes
# STARKNET_OAPP_ADDRESS back into .env.

set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
PATH="$HOME/.local/bin:$PATH"

: "${STARKNET_RPC_URL:?}"; : "${STARKNET_ACCOUNT:?}"; : "${STARKNET_ACCOUNTS_FILE:?}"
: "${LZ_ENDPOINT_STARKNET:?}"; : "${STRK_ADDRESS:?}"

# --- 1. Deploy the account on-chain (no-op if already deployed) -------------
DEPLOYED=$(python3 -c "import json; d=json.load(open('$STARKNET_ACCOUNTS_FILE')); v=d.get('alpha-sepolia',{}).get('$STARKNET_ACCOUNT') or d.get('sepolia',{}).get('$STARKNET_ACCOUNT'); print('y' if v.get('deployed') else 'n')")
if [[ "$DEPLOYED" == "n" ]]; then
  echo ">> Deploying account '$STARKNET_ACCOUNT' on-chain..."
  sncast \
    --accounts-file "$STARKNET_ACCOUNTS_FILE" \
    account deploy \
    --url "$STARKNET_RPC_URL" \
    --name "$STARKNET_ACCOUNT" 2>&1 | tail -15
else
  echo ">> Account '$STARKNET_ACCOUNT' already on-chain — skipping deploy."
fi

OWNER=$(python3 -c "import json; d=json.load(open('$STARKNET_ACCOUNTS_FILE')); v=d.get('alpha-sepolia',{}).get('$STARKNET_ACCOUNT') or d.get('sepolia',{}).get('$STARKNET_ACCOUNT'); print(v['address'])")
echo ">> Owner address: $OWNER"

# --- 2. Build the Cairo contract ---------------------------------------------
echo ">> scarb build..."
(cd starknet_oapp && scarb build) > /dev/null

# --- 3. Declare ---------------------------------------------------------------
echo ">> Declaring StringReceiver..."
# Must run from inside the package so scarb metadata finds it (the parent
# workspace's Scarb.toml doesn't include starknet_oapp as a member).
PROJECT_ROOT=$(pwd)
DECLARE_OUT=$(cd starknet_oapp && sncast \
  --accounts-file "$PROJECT_ROOT/${STARKNET_ACCOUNTS_FILE#./}" \
  --account "$STARKNET_ACCOUNT" \
  declare \
  --url "$STARKNET_RPC_URL" \
  --contract-name StringReceiver 2>&1 | tee /tmp/sncast_declare.log)

CLASS_HASH=$(echo "$DECLARE_OUT" | grep -oE 'class_hash:\s*0x[a-fA-F0-9]+' | head -1 | grep -oE '0x[a-fA-F0-9]+')
if [[ -z "$CLASS_HASH" ]]; then
  # Already declared? Pull the previously-declared hash from artifact.
  CLASS_HASH=$(python3 -c "
import json
d = json.load(open('starknet_oapp/target/dev/starknet_oapp.starknet_artifacts.json'))
for c in d.get('contracts', []):
    if c.get('contract_name') == 'StringReceiver':
        # Compute path is in c['artifacts']['sierra']
        pass
# Fallback: re-read class hash from declare log
import re,sys
log = open('/tmp/sncast_declare.log').read()
m = re.search(r'(0x[a-fA-F0-9]{60,64})', log)
print(m.group(1) if m else '')
")
fi
echo ">> Class hash: $CLASS_HASH"

# --- 4. Deploy ----------------------------------------------------------------
echo ">> Deploying instance..."
DEPLOY_OUT=$(sncast \
  --accounts-file "$STARKNET_ACCOUNTS_FILE" \
  --account "$STARKNET_ACCOUNT" \
  deploy \
  --url "$STARKNET_RPC_URL" \
--class-hash "$CLASS_HASH" \
  --arguments "$LZ_ENDPOINT_STARKNET $OWNER $STRK_ADDRESS" 2>&1 | tee /tmp/sncast_deploy.log)

CONTRACT_ADDR=$(echo "$DEPLOY_OUT" | grep -oE 'contract_address:\s*0x[a-fA-F0-9]+' | head -1 | grep -oE '0x[a-fA-F0-9]+')
echo ">> Deployed StringReceiver at: $CONTRACT_ADDR"

# --- 5. Persist back into .env -----------------------------------------------
if grep -q '^STARKNET_OAPP_ADDRESS=' .env; then
  sed -i.bak "s|^STARKNET_OAPP_ADDRESS=.*|STARKNET_OAPP_ADDRESS=$CONTRACT_ADDR|" .env
else
  echo "STARKNET_OAPP_ADDRESS=$CONTRACT_ADDR" >> .env
fi
# Starknet addresses are already 32 bytes; left-pad the hex to 66 chars (0x + 64).
PADDED=$(python3 -c "
a = '$CONTRACT_ADDR'.lower().removeprefix('0x')
print('0x' + a.rjust(64, '0'))
")
if grep -q '^STARKNET_PEER_BYTES32=' .env; then
  sed -i.bak "s|^STARKNET_PEER_BYTES32=.*|STARKNET_PEER_BYTES32=$PADDED|" .env
else
  echo "STARKNET_PEER_BYTES32=$PADDED" >> .env
fi
rm -f .env.bak

echo ""
echo "============================================================="
echo "  Starknet side deployed."
echo "    STARKNET_OAPP_ADDRESS=$CONTRACT_ADDR"
echo "    STARKNET_PEER_BYTES32=$PADDED"
echo "  Next: ./scripts/03_deploy_eth_sender.sh"
echo "============================================================="
