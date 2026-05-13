#!/usr/bin/env bash
# Deploy CounterTrigger v3 on Ethereum Sepolia.

set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
PATH="$HOME/.local/bin:$PATH"

: "${SEPOLIA_RPC_URL:?}"; : "${PRIVATE_KEY:?}"; : "${LZ_ENDPOINT:?}"

cd eth_sender
forge build > /dev/null
OUT=$(forge script script/DeployCounterTriggerV3.s.sol \
  --rpc-url "$SEPOLIA_RPC_URL" --broadcast -vv 2>&1 | tee /tmp/forge_deploy_v3.log)

ADDR=$(grep -oE 'CounterTrigger v3 deployed at: 0x[a-fA-F0-9]{40}' /tmp/forge_deploy_v3.log | grep -oE '0x[a-fA-F0-9]{40}' | head -1)
cd ..

if [[ -z "$ADDR" ]]; then
  echo "Could not parse deploy address — check /tmp/forge_deploy_v3.log"
  exit 1
fi
echo ">> CounterTrigger v3 at: $ADDR"

if grep -q '^COUNTER_V3_ETH=' .env; then
  sed -i.bak "s|^COUNTER_V3_ETH=.*|COUNTER_V3_ETH=$ADDR|" .env
else
  echo "COUNTER_V3_ETH=$ADDR" >> .env
fi
rm -f .env.bak

echo "============================================================="
echo "  CounterTrigger v3 (EVM) deployed at: $ADDR"
echo "  Next: ./scripts/12_wire_counter_v3_peers.sh"
echo "============================================================="
