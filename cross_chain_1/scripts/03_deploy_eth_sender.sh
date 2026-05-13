#!/usr/bin/env bash
# Deploys StringSender on Ethereum Sepolia, writes SENDER_ADDRESS back to .env.

set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

: "${SEPOLIA_RPC_URL:?missing in .env}"; : "${PRIVATE_KEY:?missing in .env}"; : "${LZ_ENDPOINT:?}"

echo ">> Building..."
(cd eth_sender && forge build > /dev/null)

echo ">> Deploying StringSender..."
cd eth_sender
OUT=$(forge script script/Deploy.s.sol \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast \
  -vv 2>&1 | tee /tmp/forge_deploy.log)

# forge prints `StringSender deployed at: 0x...`
ADDR=$(echo "$OUT" | grep -oE 'StringSender deployed at:\s*0x[a-fA-F0-9]{40}' | head -1 | grep -oE '0x[a-fA-F0-9]{40}')
if [[ -z "$ADDR" ]]; then
  echo "ERROR: couldn't parse deployed address from forge output." >&2
  echo "Check /tmp/forge_deploy.log" >&2
  exit 1
fi
echo ">> SENDER_ADDRESS=$ADDR"

cd ..
if grep -q '^SENDER_ADDRESS=' .env; then
  sed -i.bak "s|^SENDER_ADDRESS=.*|SENDER_ADDRESS=$ADDR|" .env
else
  echo "SENDER_ADDRESS=$ADDR" >> .env
fi
rm -f .env.bak

echo ""
echo "============================================================="
echo "  Ethereum side deployed."
echo "    SENDER_ADDRESS=$ADDR"
echo "  Next: ./scripts/04_wire_peers.sh"
echo "============================================================="
