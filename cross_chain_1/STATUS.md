# cross_chain — Project Status

End-to-end LayerZero V2 demo wiring **Ethereum Sepolia ⇄ Starknet Sepolia**. Two contract pairs are deployed, both fully bidirectional, plus a brutalist-editorial browser UI deployed to Vercel. Everything signs locally with burner keys — no MetaMask, no Argent, no popups.

> **Reading this in a fresh Claude session?** Read **PROGRESS.md** first for the chronological narrative, then come back here for the current snapshot. Everything you need to resume work is in these two files plus `.env` (gitignored) and `frontend/config.js` (gitignored).

---

## Stage of the project

```
✅ Phase 1 — Research & decide on bridge technology       (LayerZero V2 chosen)
✅ Phase 2 — Strings: ETH → Starknet                       (StringSender/Receiver v1)
✅ Phase 3 — Strings: Starknet → ETH (bidirectional)       (StringSender/Receiver v2)
✅ Phase 4 — Counter: ETH → Starknet (one-way)             (CounterTrigger v1, Counter v1)
✅ Phase 5 — Counter: Starknet → ETH (bidirectional)       (CounterTrigger v2, Counter v2)
✅ Phase 6 — Frontend (brutalist UI, burner signing)
✅ Phase 7 — Deploy frontend to Vercel
✅ Phase 8 — ABA composability (one-click ETH→SN→ETH bounce)
✅ Phase 8.5 — Persistent transmission log + LZ-scan history import
☐ Phase 9 — Mainnet deploy                                 (out of scope)
☐ Phase 10 — Source-verify on Voyager + Etherscan
```

You are currently at **end of Phase 8.5**. The ABA composability feature is implemented, tested, and deployed. The transmission log now persists across refreshes, exposes an EXPAND ALL toggle, and can backfill historical sends from LayerZero scan. Remaining work is mainnet deploy (Phase 9) and block-explorer verification (Phase 10).

---

## What is live right now

### Browser

**Production URL**: https://crosschain-strk20.vercel.app — public, single-click increment in either direction, no wallet popups (burners baked in).

| | |
|---|---|
| Vercel project | `akashneeleshs-projects/crosschain-strk20` |
| GitHub repo | https://github.com/Akashneelesh/crosschain-layerzero (private) |
| Local dev server | `cd cross_chain/frontend && bash serve.sh` → http://localhost:8765 |

### Contracts (Sepolia testnets)

| Pair | EVM contract | Starknet contract |
|---|---|---|
| **Counter v3** (ABA — current production) | [`0xD4582B4070acFf36C281Af6cedE080ABB5189AfA`](https://sepolia.etherscan.io/address/0xD4582B4070acFf36C281Af6cedE080ABB5189AfA) | [`0x02db00647367c532eb25d176b74b128a34e7fdd508435cb7623a4d7db024ef1b`](https://sepolia.voyager.online/contract/0x02db00647367c532eb25d176b74b128a34e7fdd508435cb7623a4d7db024ef1b) |
| Cairo Counter v3 class hash | — | `0x468956507a92fe2d24603b6e01af836137eaa0f25302f7e4d11bd899bbb573e` |
| **String** (older demo, still works) | [`0xEa6a7c3F7a861f3C7E9A502159ccddf4D1F64083`](https://sepolia.etherscan.io/address/0xEa6a7c3F7a861f3C7E9A502159ccddf4D1F64083) | [`0x04803a6e58d41103b5acb21a924b80538be917601d054c194cd777739b0fcf94`](https://sepolia.voyager.online/contract/0x04803a6e58d41103b5acb21a924b80538be917601d054c194cd777739b0fcf94) |
| Cairo String class hash | — | `0x269c3513e86df8e3e4e30884fccd332f378eb4b51967d2f40996cb2dd7b02f2` |

**Deprecated** (still on-chain but unused by anything):
- Counter v2 (bidirectional, no ABA): EVM `0x07aF803CD6B432A763582bC8890c16CE24669123`, Cairo `0x02f49e656ef664f11ec0f57c538a59413b187d42ee934f3f8f1899500d621ba1` (class `0x7f65b70cb27145aaeb26afa63d96f789d8acca00a9941e269fda1bfea4ec456`)
- Counter v1 (one-way only): EVM `0xEf1CCEc22D65E8fB96653fdd009Bf308D256DEa9`, Cairo `0x01df31db648414d6278f9b12d8f228cc5282b397c4ec86d1947abf80717e8f39`
- String v1 (one-way only): EVM `0x23E5a47c0b4de487Ea825fcF33dE0d2ea84D2acF`, Cairo `0x067cf70cfcb25ddea9d02e8517f873472945027fe31e00944f53f8ff379e7907`

### Burner wallets (testnet only — throwaway)

| Side | Address | Funded with |
|---|---|---|
| Ethereum Sepolia | `0x2146F1c3C15F0e0f8fd0Eb9594634601cA3B2d60` | ~0.029 ETH (decreases per tx) |
| Starknet Sepolia | `0x0233f9527bee21ca9633bde7e5ca19087759c0a4737815d9e11d88ce5ad8a0f8` | ~89 STRK (decreases per tx) |

Both private keys are in **two** local files (each gitignored):
- `cross_chain/.env` — for CLI scripts
- `cross_chain/frontend/config.js` — for the browser (and Vercel)
- `cross_chain/accounts.json` — for sncast

### LayerZero endpoint constants

| Network | EID | EndpointV2 address |
|---|---|---|
| Ethereum Sepolia | 40161 | `0x6EDCE65403992e310A62460808c4b910D972f10f` |
| Starknet Sepolia | 40500 | `0x0316d70a6e0445a58c486215fac8ead48d3db985acde27efca9130da4c675878` |

### STRK token (Starknet Sepolia)

`0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d` — used as `native_token` for OApp fee payment. Starknet burner has already approved 5 STRK to the current Counter v2; bumps required after several sends.

---

## Architecture

```
                              ┌─────────────────────────┐
                              │  Ethereum Sepolia       │
                              │                         │
   triggerIncrement(N)  ────▶ │  CounterTrigger (OApp)  │ ◀──── _lzReceive (state++)
                              │       │                 │
                              │       ▼                 │
                              │  EndpointV2.send()      │
                              └────────┬────────────────┘
                                       │
                              LZ DVNs attest
                              LZ Executor delivers
                                       │
                              ┌────────┴────────────────┐
                              │  Starknet Sepolia       │
                              │                         │
                              │  EndpointV2.deliver()   │
                              │       │                 │
                              │       ▼                 │
                              │  Counter._lz_receive    │ ◀── trigger_increment(N)
                              │       │                 │            │
                              │       ▼                 │            ▼
                              │  count += N             │      LZ packet east
                              │       │                 │
                              └─────────────────────────┘
```

Both contracts are **simultaneously sender + receiver**. Same OApp pattern in either direction. Both pay fees in the native gas token of their chain (ETH on Sepolia, STRK on Starknet Sepolia).

With v3, a single ETH-side `triggerAbaIncrement` produces a 17-byte ABA payload
that the Cairo Counter increments and immediately bounces back as a plain
32-byte return message, with the Cairo contract paying the return-leg STRK
fee from a pre-funded balance — true one-click round trip.

---

## Repository layout

```
cross_chain/
├── README.md                           Runbook / deploy steps
├── STATUS.md                           ← you are here
├── PROGRESS.md                         Chronological build log
├── .env                                Secrets + addresses (gitignored)
├── .env.example                        Template
├── .gitignore
├── accounts.json                       sncast keystore (gitignored)
├── snfoundry.toml                      Real sncast profile (gitignored)
├── snfoundry.toml.example              Template
│
├── starknet_oapp/                      Cairo package (Scarb 2.14+, isolated)
│   ├── Scarb.toml                      pins every openzeppelin_* sub-package to =2.0.0
│   ├── package.json                    pulls @layerzerolabs/protocol-starknet-v2
│   └── src/
│       ├── lib.cairo
│       ├── counter.cairo               bidirectional Counter OApp
│       └── string_receiver.cairo       bidirectional String OApp
│
├── eth_sender/                         Solidity package (Foundry)
│   ├── foundry.toml
│   ├── src/
│   │   ├── CounterTrigger.sol          bidirectional Counter OApp (v3 — ABA)
│   │   └── StringSender.sol            bidirectional String OApp
│   ├── test/
│   │   ├── StringSender.t.sol          6 forge tests, all pass
│   │   └── CounterTrigger.t.sol        4 forge tests for v3 ABA
│   └── script/
│       ├── Deploy.s.sol
│       ├── DeployCounterTrigger.s.sol
│       ├── DeployCounterTriggerV3.s.sol
│       ├── SetPeer.s.sol
│       └── Send.s.sol
│
├── frontend/                           Static page deployed to Vercel
│   ├── index.html                      dual-lane brutalist editorial
│   ├── style.css                       Fraunces + Schibsted + JetBrains
│   ├── app.js                          ethers v6 + starknet.js v7.5
│   │                                     persistent log + LZ-scan import
│   ├── config.js                       burner keys + RPC (gitignored)
│   ├── config.example.js               template
│   ├── vercel.json                     static site config + headers
│   ├── .vercelignore                   override .gitignore (include config.js in deploy)
│   ├── .vercel/                        Vercel link (auto, gitignored)
│   └── serve.sh                        python -m http.server :8765
│
├── starknet_oapp/tests/                Cairo snforge test crate (sibling of src/)
│   ├── lib.cairo                       declares the test modules
│   ├── mock_endpoint.cairo             stubbed IEndpointV2 (records send calls)
│   └── test_counter.cairo              10 tests covering plain + ABA paths
│
├── docs/
│   └── superpowers/                    session plans + design notes
│
└── scripts/                            CLI runbook
    ├── 01_setup_starknet_account.sh    create sncast burner
    ├── 02_deploy_starknet_oapp.sh      declare + deploy Cairo OApp
    ├── 03_deploy_eth_sender.sh         deploy Solidity OApp
    ├── 04_wire_peers.sh                setPeer on both sides
    ├── 05_send.sh                      string: ETH → Starknet
    ├── 06_send_from_starknet.sh        string: Starknet → ETH (approves STRK)
    ├── 10_deploy_counter_v3_starknet.sh  declare + deploy Cairo Counter v3
    ├── 11_deploy_counter_trigger_v3_eth.sh  deploy Solidity CounterTrigger v3
    ├── 12_wire_counter_v3_peers.sh     setPeer both directions for v3
    ├── 13_fund_counter_v3_strk.sh      transfer STRK to Counter v3 for return fees
    ├── 14_set_return_options.sh        set return_gas + return_value on Counter v3
    ├── 15_aba_smoke_test.sh            end-to-end ABA smoke test
    ├── 16_kick_message.sh              manually call endpoint.lz_receive when executor lags
    └── lib/lz-kick/                    Node.js helper for 16 (starknet.js + kick.mjs)
```

---

## How to resume from scratch (new Claude instance)

If you're starting a new session and want to keep building, do this first:

```sh
cd /Users/akash/Desktop/earn-contracts/cross_chain
cat STATUS.md PROGRESS.md            # absorb current state + history
ls -la .env accounts.json snfoundry.toml frontend/config.js   # confirm secrets present
cd starknet_oapp && scarb build      # verify Cairo still compiles
cd ../eth_sender && forge build && forge test  # verify Solidity still compiles
cd .. && bash frontend/serve.sh &    # dev server on :8765
```

If everything compiles and the dev page loads, you're at end of Phase 7. From there, common next moves:

| Goal | Where to start |
|---|---|
| Cairo snforge tests | `starknet_oapp/tests/test_counter.cairo` — 10 tests covering plain + ABA paths, owner gates |
| Etherscan / Voyager verify | Add `--verify` to forge scripts; sncast has `--verifier voyager` |
| Mainnet deploy | Swap EIDs (30161, 30500) + endpoints in `.env`; fund real wallets; re-run `02..05` |
| Add a third chain | Deploy a new OApp on chain C; call `setPeer(C_eid, C_addr)` on existing two |
| Compose / ABA flows | The Cairo OApp already has `OAppSenderImpl`; Solidity has `_lzSend` |
| Frontend changes | Edit `frontend/`, re-deploy with `cd frontend && vercel --prod --yes` |
| Bidirectional OFT (token) | Different OApp pattern; `protocol-starknet-v2` ships an OFT example |

---

## What works (ABI surfaces)

### Cairo `Counter` — current production, v2 bidirectional

External:
- `count() → u64`
- `last_increment_by() → u64`
- `last_src_eid() → u32`
- `quote_trigger_increment(dst_eid, by, gas_limit) → MessagingFee` — pre-flight cost in STRK
- `trigger_increment(dst_eid, by, gas_limit) → MessageReceipt` — sends; caller must pre-approve STRK
- OApp surface inherited: `set_peer`, `get_peer`, `set_delegate`, `oapp_version`, `lz_receive`, `is_compose_msg_sender`, `next_nonce`, `allow_initialize_path`
- Ownable: `owner`, `transfer_ownership`, `renounce_ownership`

Events: `Incremented{src_eid, guid, by, new_count}`, `IncrementTriggered{dst_eid, guid, by}`

### Solidity `CounterTrigger` — current production, v2 bidirectional

External:
- `count() → uint64`, `lastIncrementBy() → uint64`, `lastSrcEid() → uint32`
- `quoteTriggerIncrement(dstEid, by, options) → MessagingFee` view
- `triggerIncrement(dstEid, by, options)` payable
- `defaultOptions() → bytes` — 200k executor gas, type-3 options
- OApp surface: `setPeer`, `peers(eid)`, `setDelegate`, `setEnforcedOptions`, `endpoint`, `oAppVersion`, `nextNonce`, `allowInitializePath`, `isComposeMsgSender`, `lzReceive`
- Ownable

Events: `IncrementTriggered`, `IncrementReceived`

### Verified live on Sepolia (sample txs)

| Direction | Tx | Latency |
|---|---|---|
| ETH → SN (string) | [`0xe246af8f…`](https://testnet.layerzeroscan.com/tx/0xe246af8fb5de27428692613994136be130c4009fb0aaaf0e5939de17a038c23a) | ~60 s |
| SN → ETH (string) | [`0x04a36488…`](https://testnet.layerzeroscan.com/tx/0x04a36488ad6d474c17d8770f30f4e9c82f96790df462bb06f3985dcbef04bd18) | ~3.5 min |
| ETH → SN (counter +5) | [`0xb03c6c69…`](https://testnet.layerzeroscan.com/tx/0xb03c6c69121c2a3b3875ec531e04391b896752b24434dc95dc6b04d985414ffd) | ~90 s |
| SN → ETH (counter +7) | [`0x004b1515…`](https://testnet.layerzeroscan.com/tx/0x004b151578aa8f29882c3db1e4b5ed90c7620ff04b3259e941cf66423633edb0) | ~3.5 min |
| ETH → SN (v2 counter +3, late-day re-verify 2026-05-13) | [`0x649018b5…`](https://testnet.layerzeroscan.com/tx/0x649018b5635e200f8e9d82c25ae1092c50f8fc2dedd746fa0a6f6286ea17dca2) | **~2 h 20 m** (sealer lag) — dest tx `0x26c64d28…` |
| ETH → SN (v3 counter +5, in flight at time of writing) | [`0x753994b6…`](https://testnet.layerzeroscan.com/tx/0x753994b67f1565dcce3c6c28af86c070dfca8437d26c600245c7ec647be36441) | INFLIGHT — DVN not yet attested when last polled |

> **Phase 8 verified end-to-end on chain (2026-05-13).** ETH→SN send tx
> `0x9f4f7a57…` was manually delivered via `scripts/16_kick_message.sh`
> (direct `endpoint.lz_receive(...)` call from the burner — bypasses the
> LZ Starknet executor which was lagging hours that day). Concrete proofs:
> SN Counter v3 `count` 0 → **5** (ABA `by_sn` decoded correctly), Counter v3
> STRK balance **4.000 → 3.272 STRK** (0.728 STRK return-leg fee paid from
> contract balance — the `caller == self` self-pay carve-out works on real
> chain, not just snforge mock), then ~85 s later EVM Counter v3 `count`
> 0 → **3** (`by_eth` decoded correctly via the return-leg plain payload).
> SN delivery tx: `0x3e822ef5763883178806f16b0aa17e2b646bcb89d788c0117e18fb6585cc8c8`.
>
> The LZ Starknet Sepolia executor / sealer were broadly slow this day (the
> v2 control single-hop also timed out at sealer), so the autonomous BOUNCE
> flow had to fall back to the kick script. When the sealer + executor are
> healthy, BOUNCE delivers without manual help.

> **Phase 8.5 — Persistent transmission log (2026-05-13, evening).**
> The on-page log used to live only in `state.txs`, so every refresh wiped
> it and ABA presses never appeared at all. Now:
>
> - **localStorage persistence.** Key `crosschain.transmission-log.v1`.
>   `loadLog()` rehydrates in `boot()`, `persistLog()` runs from every
>   `renderLog()`. Survives reloads, tabs, Vercel deploys.
> - **EXPAND / COLLAPSE.** Default cap is 12 entries (`LOG_COLLAPSED_LIMIT`).
>   Header shows `showing 12 of N` when overflowing or `N transmissions`
>   when fully visible. Button text is `EXPAND ALL (N)` ↔ `COLLAPSE`.
> - **CLEAR** with confirm — only visible when log is non-empty.
> - **IMPORT HISTORY** — pulls every ETH-initiated message for the burner
>   from `scan-testnet.layerzero-api.com/v1/messages/wallet/<addr>`,
>   decodes plain 32-byte and ABA 17-byte payloads, probes a small
>   hardcoded list of known SN→ETH source tx hashes (the API doesn't
>   index Starknet senders), dedupes by tx hash, sorts newest-first,
>   merges into `state.txs`. Backfills ~20 historical entries.
> - **ABA in the log.** `pressAba` now writes an entry with lifecycle
>   `pending → eth-ok → aba-half → delivered` (and `timed-out` / `failed`
>   branches), rendered as `ABA ⇄ SN+x · ETH+y`.
> - **Visual.** Brutalist outlined controls, accent-orange hover, status
>   colors for `sn-ok` / `aba-half` / `timed-out`, and a `MAY 13` date
>   prefix per row (hidden on narrow screens).
>
> Verified end-to-end via headless browser: 15 seeded entries → reload →
> `showing 12 of 15` → click EXPAND → 15 rows / `15 transmissions` →
> click COLLAPSE → back to 12. Decoder validated against real payloads
> (5/7/42 single-hop and 5/3, 4/7, 5/10 ABA cases).
>
> Shipped in commit `0601d0c` on `feat/aba-counter`. Not yet re-deployed
> to Vercel — run `cd cross_chain/frontend && vercel --prod --yes` to go
> live.

---

## Footguns to remember

1. **OZ Cairo 2.0.0 is broken on the registry** — `openzeppelin_utils-2.0.0` wasn't published while every other OZ 2.0 sub-package depends on it. Fix in `starknet_oapp/Scarb.toml`: every `openzeppelin_*` sub-package pinned to `=2.0.0` exact-version.

2. **sncast 0.60 quirks** —
   - `--fee-token` removed; auto-estimates now
   - Calldata uses Cairo-like syntax: structs as `Bytes32 { value: 0x... }`, args comma+space separated
   - Class indexing lag after declare; scripts retry with `until` on "not declared"

3. **Scarb workspace contamination** — running `sncast declare` from `cross_chain/` errors with "more than one package in scarb metadata". Must `cd starknet_oapp/` first.

4. **starknet.js v7.5 + Alchemy RPC** — Alchemy's `/v0_10/` path serves spec 0.10 which starknet.js v7.5 doesn't speak. The frontend uses `/v0_8/` + explicit `specVersion: "0.8.1"` + `blockIdentifier: "latest"` (because the default `"pending"` block tag is rejected by Alchemy). See `frontend/config.js` `STARKNET_RPC` + `STARKNET_SPEC`.

5. **STRK approval required on Starknet sends** — `_lz_send` pulls fees via `transferFrom`. Currently 5 STRK approved on Counter v2; bump with one sncast invoke when it runs out.

6. **EVM `abi.encode(string)` adds a 64-byte envelope** — when EVM sends a string, the Cairo `ByteArray` receives offset + length + padded content. Decoded in `app.js` for the StringReceiver demo. The Counter payload is just `abi.encode(uint64)` = 32 bytes, decoded via `read_u64_be_at(message, 24)` in Cairo.

7. **BlastAPI's free Starknet RPC died** in 2026. Use Alchemy (with the spec-version path workaround above) or `api.cartridge.gg/x/starknet/sepolia`.

8. **Vercel `.gitignore` fallback** — by default Vercel respects `.gitignore`, which would exclude `frontend/config.js` (containing the burner keys). Override with `frontend/.vercelignore` that explicitly `!config.js` includes it. This is intentional — see Secrets section.

9. **LZ Starknet Sepolia executor + sealer lag** — on slow days the testnet
   committer/sealer can take 10+ min (sometimes hours) to commit DVN
   attestations to the SN-side receive lib, after which the executor still
   has to deliver. The destination contract sits in WAITING state at LZ
   scan and the BOUNCE UI flow times out at "waiting for Starknet".
   **Workaround:** once the message's `verification.sealer.status` is
   `SUCCEEDED` on LZ scan, run `./scripts/16_kick_message.sh <source-tx>`
   to call `endpoint.lz_receive(...)` directly from the burner — anyone
   can do this in LZ V2 once the attestation is sealed; it bypasses the
   executor entirely. Costs ~0.05 STRK in fees. The script auto-pulls
   origin/guid/payload from LZ scan, encodes the Cairo ByteArray/Bytes32/
   u256 calldata via starknet.js, and submits. Use `setSendConfig` for a
   permanent fix once a healthier executor is identified.

---

## Secrets, exposure, and rotation

### Files with real secrets (all gitignored)

| File | Contains |
|---|---|
| `cross_chain/.env` | Ethereum private key + Alchemy RPC URLs |
| `cross_chain/accounts.json` | Starknet account-1 private key |
| `cross_chain/snfoundry.toml` | sncast profile (also has Alchemy URL) |
| `cross_chain/frontend/config.js` | Both burner private keys + both Alchemy URLs |

### Public exposure

Because `frontend/config.js` is bundled into the Vercel build (we deliberately overrode `.gitignore` with `.vercelignore`), **anyone with the URL has the two burner private keys and your Alchemy API key**. Acceptable here because:
- Both burners are throwaway testnet accounts (no real value)
- Alchemy free tier is rate-limited, not billed
- The smart contracts can't be drained — they only relay LZ messages

When you're done sharing the demo:
1. Sweep residual ETH/STRK from the burners (or just abandon them).
2. Rotate the Alchemy API key in the dashboard.
3. (Optional) Redeploy with the keys stripped from `config.js` — the page falls back to MetaMask + Argent automatically.

### Token used for this deploy

A short-lived Vercel CLI token (prefix `vcp_2V1s…`) was used for the original deploy session. **Revoke it at https://vercel.com/account/tokens** if you haven't already — it was in plaintext in the chat log used to create this project.

---

## Tooling versions (pinned mentally)

| Tool | Version installed | Why this version |
|---|---|---|
| Scarb (Cairo) | 2.16.1 | Latest; works with starknet 2.14 deps |
| Cairo | 2.16.1 | bundled with Scarb |
| Starknet Foundry | 0.60.0 | `snforge`, `sncast` |
| Foundry | forge 1.6.0 | Solidity build + scripts |
| Solidity | 0.8.22 | Matches LayerZero V2 OApp requirements |
| OpenZeppelin Cairo | =2.0.0 (every sub-package) | LayerZero protocol-starknet-v2 expects this |
| `@layerzerolabs/protocol-starknet-v2` | 0.2.90 (via npm) | Latest at session time |
| ethers (browser) | 6.13.4 via esm.sh | Stable v6 |
| starknet.js (browser) | 7.5.0 via esm.sh | Pinned — v8 breaks `Account` constructor, v6 sends v1 txs which Sepolia rejects |
| `@noble/hashes` | 1.5.0 via esm.sh | for sn_keccak in browser |
| Vercel CLI | 53.4.0 | global install |

---

## One-paragraph protocol mental model

LayerZero V2: a contract calls `EndpointV2.send()` with `(dstEid, peer, message, options)`; the endpoint emits `PacketSent`; one or more off-chain **DVNs** observe it, wait for source-chain finality, and call `commitPacket()` on the destination endpoint; once the configured quorum of DVNs has committed, an off-chain **executor** delivers the message by invoking `Endpoint.lzReceive()` on the destination, which forwards to the OApp's `_lzReceive` / `_lz_receive` hook. Trust is whatever DVN set you configure — default is "trust LayerZero's official DVN". Same protocol either direction; the Starknet implementation just runs on Cairo + STRK fees.
