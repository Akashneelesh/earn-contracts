# cross_chain — LayerZero V2 demo (Ethereum → Starknet)

End-to-end demo: an Ethereum transaction sends a string to a Starknet contract via
LayerZero V2. The Starknet contract stores the string and emits a `MessageReceived`
event.

```
┌──────────────┐   sendString()    ┌──────────────────┐
│ StringSender │  ───────────────► │  LZ EndpointV2   │  (Ethereum)
└──────────────┘                   └──────────────────┘
                                            │
                                            │  (DVNs verify, Executor delivers)
                                            ▼
                                   ┌──────────────────┐
                                   │  LZ Endpoint     │  (Starknet)
                                   └──────────────────┘
                                            │ _lz_receive
                                            ▼
                                   ┌──────────────────┐
                                   │ StringReceiver   │  (Cairo)
                                   └──────────────────┘
```

This folder is **isolated from the rest of the workspace** because LayerZero's
Starknet packages require Scarb 2.14+ / starknet 2.14, while `contracts/` is pinned
to starknet 2.12.2 for Primer class-hash stability. Do not add `cross_chain/` to
the root `Scarb.toml` workspace members.

## Status

- `cross_chain/starknet_oapp` — compiles cleanly (`scarb build`). Sierra +
  contract_class.json produced. ABI exposes `set_peer`, `lz_receive`,
  `last_message`, `last_src_eid`, `message_count`, owner controls.
- `cross_chain/eth_sender` — compiles cleanly (`forge build`). 6/6 forge tests
  pass (peer forwarding, fee quoting, owner-only setPeer, payload encoding).
- Testnet deployment — not yet executed (needs your wallet keys + funded
  Sepolia accounts on both sides). Steps below.

### Important pinning quirk (Cairo side)

The LayerZero `protocol-starknet-v2` npm package was published when OpenZeppelin
`openzeppelin_utils-2.0.0` was on the Scarb registry. Today only 1.0.0 and 2.1.0
remain visible by default, so the Scarb resolver picks 2.1.0 which is **not**
ABI-compatible with `openzeppelin_token-2.0.0`. The `Scarb.toml` in
`starknet_oapp/` pins every OZ sub-package to `=2.0.0` to keep the resolver
honest. Don't change those pins unless you also bump LayerZero.

## Layout

```
cross_chain/
├── starknet_oapp/        # Cairo receiver (LayerZero OApp)
│   ├── Scarb.toml
│   ├── package.json      # pulls @layerzerolabs/protocol-starknet-v2 via npm
│   └── src/string_receiver.cairo
└── eth_sender/           # Solidity sender (Foundry)
    ├── foundry.toml
    ├── .env.example
    ├── src/StringSender.sol
    └── script/{Deploy,SetPeer,Send}.s.sol
```

## Required addresses (verify before mainnet use)

| Network            | LayerZero EndpointV2                                                         |
|--------------------|------------------------------------------------------------------------------|
| Ethereum Mainnet   | `0x1a44076050125825900e736c501f859c50fe728c`                                 |
| Ethereum Sepolia   | `0x6EDcE65403992e310A62460808c4b910D972f10f`                                 |
| Starknet Mainnet   | `0x524e065abff21d225fb7b28f26ec2f48314ace6094bc085f0a7cf1dc2660f68`          |
| Starknet Sepolia   | `0x0316d70a6e0445a58c486215fac8ead48d3db985acde27efca9130da4c675878`         |

| Chain              | EID         |
|--------------------|-------------|
| Ethereum Mainnet   | `30101`     |
| Ethereum Sepolia   | `40161`     |
| Starknet Mainnet   | **fetch**   |
| Starknet Sepolia   | **fetch**   |

Starknet EIDs were not in the docs we fetched. Get them from
<https://docs.layerzero.network/v2/tools/endpoint-metadata> or run
`curl https://metadata.layerzero-api.com/v1/metadata/deployments | jq` and grep
for `starknet`.

Required tool versions on the Starknet side: **Scarb 2.14.0**, **Starknet Foundry 0.53.0**.

---

## Step 1 — Deploy the Starknet receiver

```sh
cd cross_chain/starknet_oapp
npm install                      # vendors @layerzerolabs/protocol-starknet-v2
scarb build

# Declare + deploy on Sepolia
sncast --account <ACCOUNT> declare \
  --contract-name StringReceiver \
  --url https://starknet-sepolia.public.blastapi.io

sncast --account <ACCOUNT> deploy \
  --class-hash <CLASS_HASH_FROM_PREV_STEP> \
  --url https://starknet-sepolia.public.blastapi.io \
  --arguments \
    0x0316d70a6e0445a58c486215fac8ead48d3db985acde27efca9130da4c675878, \
    <YOUR_STARKNET_OWNER>, \
    0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
```

Args are `(endpoint, owner, native_token=STRK)`. Note the deployed contract
address — call it `<STARKNET_OAPP>`.

## Step 2 — Deploy the Ethereum sender

```sh
cd cross_chain/eth_sender
cp .env.example .env             # then fill in PRIVATE_KEY, SEPOLIA_RPC_URL
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts \
              LayerZero-Labs/layerzero-v2

forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
```

Note the deployed sender address as `<SENDER_ADDRESS>`.

## Step 3 — Wire peers (both directions)

LayerZero requires each side to register the other as a "peer" for the given EID
before any message can flow.

**3a — EVM tells the sender about the Starknet peer:**

```sh
# Convert your Starknet OApp address to bytes32 (just left-pad to 32 bytes;
# Starknet addresses are already 32 bytes, so this is a direct copy).
export STARKNET_PEER_BYTES32=<STARKNET_OAPP>      # 0x-prefixed, 32 bytes
export SENDER_ADDRESS=<SENDER_ADDRESS>
export DST_EID_STARKNET=<starknet_sepolia_eid>

forge script script/SetPeer.s.sol \
  --rpc-url $SEPOLIA_RPC_URL --broadcast
```

**3b — Starknet tells the receiver about the EVM peer:**

```sh
# Convert the EVM sender (20 bytes) to two u128 halves for the bytes32 arg.
# EVM address 0x<20B> becomes:
#   peer_high = upper 4 bytes (0x00000000 + first 4B of addr)  -> usually 0x00000000<4B>
#   peer_low  = lower 16 bytes of the 32-byte left-padded value
# For sender 0xAABB...CCDD (20 bytes), the bytes32 is
#   0x0000000000000000000000000000<AA..DD>
# Take peer_high = upper 16 bytes, peer_low = lower 16 bytes.
# Example for 0x1234567890abcdef1234567890abcdef12345678:
#   peer_high = 0x000000000000000000000000_12345678
#   peer_low  = 0x90abcdef1234567890abcdef_12345678

sncast --account <ACCOUNT> invoke \
  --contract-address <STARKNET_OAPP> \
  --function set_peer \
  --url https://starknet-sepolia.public.blastapi.io \
  --calldata <eth_sepolia_eid> <peer_low> <peer_high>
```

## Step 4 — Send your first message

```sh
cd cross_chain/eth_sender
export SENDER_ADDRESS=<SENDER_ADDRESS>
export DST_EID_STARKNET=<starknet_sepolia_eid>
export MESSAGE="hello from ethereum"

forge script script/Send.s.sol \
  --rpc-url $SEPOLIA_RPC_URL --broadcast
```

The script prints a guid; track delivery at
<https://testnet.layerzeroscan.com/> by pasting the tx hash or guid.

## Step 5 — Verify on Starknet

After ~1–3 minutes, query the receiver:

```sh
sncast --account <ACCOUNT> call \
  --contract-address <STARKNET_OAPP> \
  --function last_message \
  --url https://starknet-sepolia.public.blastapi.io
```

Should return the string you sent.

---

## Gotchas

- **STRK fee on the Starknet side.** The Starknet OApp pays its own delivery
  in STRK when sending out, but for receive-only it does not. Your EVM sender
  pays the *entire* round-trip fee in ETH.
- **Peer = bytes32.** Both sides store the peer as a 32-byte value. EVM
  addresses get left-padded; Starknet addresses are already 32 bytes.
- **Options matter.** `addExecutorLzReceiveOption(200_000, 0)` allocates 200k
  gas-equivalent to the destination executor. Too low and delivery reverts;
  the receipt's guid will show as failed on LayerZero Scan. Bump if needed.
- **EID is not chain id.** It's a LayerZero-internal id. Look it up at
  <https://docs.layerzero.network/v2/tools/endpoint-metadata>.
- **Do not add this folder to the workspace `Scarb.toml`.** It uses newer
  Cairo/Scarb than the rest of the repo on purpose.
- **Trust assumption.** Messages are verified by LayerZero's DVN set, not by
  Starknet's native L1→L2 bridge. If you need protocol-level trust, use
  `sendMessageToL2` on the Starknet Core contract instead — slower, but
  same security as Starknet itself.
