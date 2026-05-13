# ABA Counter — Design Spec

**Date:** 2026-05-13
**Project:** `cross_chain/` (LayerZero V2 Ethereum Sepolia ⇄ Starknet Sepolia demo)
**Goal:** One click on Ethereum kicks off Ethereum → Starknet → Ethereum, incrementing both counters from a single user-signed transaction.

---

## 1. Problem

Today the demo supports two independent flows:

- **ETH → SN press:** Increments Starknet's counter only.
- **SN → ETH press:** Increments Ethereum's counter only.

Each flow is a single LayerZero message, paid for by the burner on the originating side. They are not composed.

We want a third flow — **ABA composability** — where one click on Ethereum:

1. Sends one message to Starknet.
2. Starknet's `_lz_receive`:
   - Increments Starknet's local counter by `by_sn`.
   - Sends a return message back to Ethereum.
3. Ethereum's `_lzReceive` increments its local counter by `by_eth`.

All without the user touching anything after the first click and without any STRK approval popups on the Starknet side.

---

## 2. Constraints from the existing system

- Cairo `Counter` v2's `_lz_send` pulls fees via `IERC20.transferFrom(caller, contract, fee)` in STRK. During `_lz_receive` the caller is the LZ Endpoint, not a user — so the existing `trigger_increment` external cannot be reused inside the receive hook.
- Cairo contracts are not upgradeable here; `Counter` has no `Upgradeable` component. New behavior = new class hash = new address.
- Existing wire format for both directions is exactly `abi.encode(uint64)` = 32 bytes, big-endian, right-aligned. CounterTrigger.sol decodes this with `abi.decode(_message, (uint64))`; counter.cairo decodes with `read_u64_be_at(message, 24)`. We want to keep this format intact for the return leg so Ethereum's `_lzReceive` stays unchanged.
- The Cairo Counter v3 will be pre-funded with STRK by the owner (4 STRK already loaded on v2 for testing; will be moved to v3 after deploy).

---

## 3. Key discovery: OAppCoreComponent already supports self-pay

In `node_modules/@layerzerolabs/protocol-starknet-v2/layerzero/src/oapps/oapp/oapp_core.cairo`:

```cairo
// _pay_native, line 335
if caller != contract_address {
    let allowance = native_token_dispatcher.allowance(caller, contract_address);
    assert_with_byte_array(allowance >= fee, ...);
}

// _pay_in_token, line 397
if caller != contract_address {
    let success = token_dispatcher.transfer_from(caller, contract_address, fee);
    assert_with_byte_array(success, err_transfer_failed());
}
let success = token_dispatcher.approve(endpoint, fee);
```

When the OApp passes its own address as `caller` to `_lz_send`, both the allowance check and the `transfer_from` are skipped. The component just approves the endpoint to spend the OApp's own STRK balance, and the endpoint pulls the fee directly. **No self-approval setup, no custom send path, no protocol modifications.** The carve-out is clearly intentional for ABA/compose patterns.

This unblocks the entire design.

---

## 4. Architecture

```
User clicks ABA on UI
        │
        ▼
ETH burner signs ONE tx
        │
        ▼
┌───────────────────────────────────────┐
│ CounterTrigger v3 (Sepolia)           │
│  triggerAbaIncrement(by_sn, by_eth)   │
│    encodes 17-byte ABA payload        │
│    _lzSend(40500, payload, options)   │
│  count: unchanged here                │
└──────────────┬────────────────────────┘
               │ LZ DVN + executor (~60s)
               ▼
┌───────────────────────────────────────┐
│ Counter v3 (Starknet Sepolia)         │
│  _lz_receive (message.len() == 17)    │
│    1. count += by_sn                  │
│    2. encode_plain(by_eth) — 32 bytes │
│    3. _lz_send(self_addr, …)          │
│       fee drawn from contract's STRK  │
└──────────────┬────────────────────────┘
               │ LZ DVN + executor (~3.5min)
               ▼
┌───────────────────────────────────────┐
│ CounterTrigger v3 (Sepolia)           │
│  _lzReceive (message.length == 32)    │
│  count += by_eth                      │  ← existing path, untouched
└───────────────────────────────────────┘
```

Loop prevention is structural: ABA logic lives only in Cairo. The return message is a plain 32-byte payload, which on Ethereum only triggers a counter increment — there's no path back to send another message.

---

## 5. Wire format

Two payload shapes coexist on the ETH → SN channel:

| Shape | Length | Content | Origin | Cairo `_lz_receive` behavior |
|---|---|---|---|---|
| **Plain** | 32 bytes | `abi.encode(uint64 by)` — 24 zero bytes + 8-byte big-endian value | `triggerIncrement` (existing) | Read u64 at offset 24, increment count |
| **ABA** | 17 bytes | `0x01 ‖ by_sn (8B BE) ‖ by_eth (8B BE)` | `triggerAbaIncrement` (new) | Increment by `by_sn`, send plain 32-byte payload with `by_eth` back to origin |

Discrimination is by `message.len()`. The 17 vs 32 byte distinction is unambiguous because `abi.encode(uint64)` is always exactly 32 bytes. The leading `0x01` is a version/type tag for forward extensibility (e.g., a future `0x02` could carry per-tx return gas/value overrides).

The SN → ETH channel only ever carries the plain 32-byte format. `CounterTrigger._lzReceive` is unchanged.

---

## 6. Contract changes

### 6.1 `starknet_oapp/src/counter.cairo` (v3)

**New constants:**

```cairo
const ABA_TAG: u8 = 0x01;
const ABA_PAYLOAD_LEN: u32 = 17;
const PLAIN_PAYLOAD_LEN: u32 = 32;
```

**New storage:**

```cairo
return_gas: u128,    // gas for SN→ETH executor lzReceive option. Default 200_000.
return_value: u128,  // value (msg.value) delivered to ETH _lzReceive. Default 0.
```

**New events:**

```cairo
struct AbaBounceSent {
    #[key] dst_eid: u32,
    guid: Bytes32,
    by_eth: u64,
}
```

**Constructor change:** initialize `return_gas = 200_000`, `return_value = 0`.

**`_lz_receive` change:** discriminator on `message.len()`:

```cairo
fn _lz_receive(...) {
    let len = message.len();
    if len == PLAIN_PAYLOAD_LEN {
        // existing path, unchanged
        let by = read_u64_be_at(@message, 24);
        // ... increment + emit Incremented ...
    } else if len == ABA_PAYLOAD_LEN {
        let tag: u8 = message.at(0).unwrap();
        assert_with_byte_array(tag == ABA_TAG, "BAD_ABA_TAG");
        let by_sn = read_u64_be_at(@message, 1);
        let by_eth = read_u64_be_at(@message, 9);

        // (1) increment local count
        let mut contract = self.get_contract_mut();
        let new_count = contract.count.read() + by_sn;
        contract.count.write(new_count);
        contract.last_increment_by.write(by_sn);
        contract.last_src_eid.write(origin.src_eid);
        contract.emit(Incremented { src_eid: origin.src_eid, guid, by: by_sn, new_count });

        // (2) bounce back: send plain 32-byte payload with by_eth
        let self_addr = get_contract_address();
        let return_payload = encode_uint64_abi(by_eth);
        let return_options = executor_lz_receive_option(
            contract.return_gas.read(),
            contract.return_value.read(),
        );
        let fee = self.oapp_core._quote(
            origin.src_eid, return_payload.clone(), return_options.clone(), false,
        );
        let receipt = self.oapp_core._lz_send(
            self_addr,        // caller == self → skips transferFrom; uses contract STRK
            origin.src_eid,
            return_payload,
            return_options,
            fee,
            self_addr,        // refund excess to self
        );
        contract.emit(AbaBounceSent { dst_eid: origin.src_eid, guid: receipt.guid, by_eth });
    } else {
        // unknown shape — revert to surface bugs loudly
        assert_with_byte_array(false, "BAD_PAYLOAD_LEN");
    }
}
```

**New owner-only externals:**

```cairo
fn set_return_options(ref self: ContractState, gas: u128, value: u128) {
    self.ownable.assert_only_owner();
    self.return_gas.write(gas);
    self.return_value.write(value);
}

fn withdraw_strk(ref self: ContractState, to: ContractAddress, amount: u256) {
    self.ownable.assert_only_owner();
    let strk = self.oapp_core.OAppCore_native_token.read();
    IERC20Dispatcher { contract_address: strk }.transfer(to, amount);
}
```

`withdraw_strk` exists so the owner can sweep residual STRK when the demo is decommissioned. `OAppCore_native_token` is declared `pub` on the component storage (line 39 of `node_modules/@layerzerolabs/protocol-starknet-v2/layerzero/src/oapps/oapp/oapp_core.cairo`), so the embedded substorage is readable directly from the Counter contract.

**No new view for quoting the return leg.** The user only pays for the forward leg from Ethereum (`quoteAbaIncrement` in §6.2 returns that fee). The return leg is paid by the Cairo contract's pre-funded STRK balance — operator concern, not user concern. There is intentionally no Cairo-side quote function for the ABA flow.

### 6.2 `eth_sender/src/CounterTrigger.sol` (v3)

**New constants:**

```solidity
uint8 public constant ABA_TAG = 0x01;
uint16 public constant SEND_ABA = 2;  // distinct enforced-options key
```

**New external:**

```solidity
function quoteAbaIncrement(
    uint32 _dstEid,
    uint64 _bySn,
    uint64 _byEth,
    bytes calldata _options
) external view returns (MessagingFee memory fee) {
    bytes memory payload = abi.encodePacked(ABA_TAG, _bySn, _byEth); // 17 bytes
    fee = _quote(_dstEid, payload, combineOptions(_dstEid, SEND_ABA, _options), false);
}

function triggerAbaIncrement(
    uint32 _dstEid,
    uint64 _bySn,
    uint64 _byEth,
    bytes calldata _options
) external payable returns (MessagingReceipt memory receipt) {
    bytes memory payload = abi.encodePacked(ABA_TAG, _bySn, _byEth); // 17 bytes
    receipt = _lzSend(
        _dstEid,
        payload,
        combineOptions(_dstEid, SEND_ABA, _options),
        MessagingFee(msg.value, 0),
        payable(msg.sender)
    );
    emit AbaIncrementTriggered(_dstEid, receipt.guid, _bySn, _byEth);
}

event AbaIncrementTriggered(uint32 indexed dstEid, bytes32 guid, uint64 bySn, uint64 byEth);
```

**`_lzReceive` is unchanged.** Still decodes 32-byte plain payloads, still increments by the embedded `uint64`. The return message looks identical to a single-hop SN→ETH message.

**`defaultAbaOptions`:** New convenience pure function returning options sized for the ABA forward leg — needs more gas than plain because the Cairo `_lz_receive` does more work (an extra `_lz_send`). Suggested starting point: `addExecutorLzReceiveOption(1_000_000, 0)`. Will be tuned during testing.

---

## 7. Frontend changes

### 7.1 Layout

Current page has two side-by-side lanes (ETH on the left, SN on the right). Add a **third zone below the two lanes**, full-width, distinct visual treatment to call out that it's a composed flow.

```
┌────────────────────┬────────────────────┐
│  ETHEREUM lane     │  STARKNET lane     │
│   (existing)       │   (existing)       │
│   PRESS button     │   PRESS button     │
└────────────────────┴────────────────────┘
┌─────────────────────────────────────────┐
│  ABA — ROUND TRIP                       │
│  by_sn: [   ]   by_eth: [   ]           │
│  [          BOUNCE           ]          │
│  status: armed | quoting | sending |    │
│          waiting-for-sn | sn-confirmed  │
│          | waiting-for-eth | done       │
└─────────────────────────────────────────┘
```

Visual style consistent with existing brutalist editorial — orange accent on the BOUNCE button, monospace JetBrains for the status readouts.

### 7.2 JS flow (`frontend/app.js`)

```js
async function pressAba() {
  const bySn  = BigInt(document.getElementById('aba-by-sn').value || '1');
  const byEth = BigInt(document.getElementById('aba-by-eth').value || '1');

  const trigger = new ethers.Contract(COUNTER_TRIGGER_V3, COUNTER_TRIGGER_ABI, ethSigner);
  const options = await trigger.defaultAbaOptions();
  const fee = await trigger.quoteAbaIncrement(STARKNET_EID, bySn, byEth, options);

  setStatus('sending');
  const tx = await trigger.triggerAbaIncrement(
    STARKNET_EID, bySn, byEth, options, { value: fee.nativeFee }
  );
  await tx.wait();

  setStatus('waiting-for-sn');
  await pollUntil(() => readStarknetCount() === preSnCount + bySn,  120_000);

  setStatus('waiting-for-eth');
  await pollUntil(() => readEthCount()      === preEthCount + byEth, 300_000);

  setStatus('done');
}
```

Polls share the same animated ticker pattern the existing buttons use.

### 7.3 Inputs & validation

- Both inputs accept positive integers, default 1, max u64 (UI clamps to a reasonable max like 999 for the demo to avoid arithmetic overflow surprises).
- Button disabled while any of the three flows is in flight.

---

## 8. Scripts and deployment

| Script | Status | Purpose |
|---|---|---|
| `scripts/02_deploy_starknet_oapp.sh` | edit | Point at new `counter.cairo`; declares + deploys v3 |
| `scripts/03_deploy_eth_sender.sh` | edit | Deploys v3 of `CounterTrigger` |
| `scripts/04_wire_peers.sh` | edit | `setPeer` on both sides for v3 addresses |
| `scripts/07_aba_smoke_test.sh` | new | End-to-end: quote → call `triggerAbaIncrement(40500, 5, 3, options)` → poll both counts |
| `scripts/08_fund_counter_strk.sh` | new | Owner transfers N STRK from burner to Counter v3 contract address |
| `scripts/09_set_return_options.sh` | new | Owner-only: tune `return_gas` / `return_value` without redeploy |

The pre-funded 4 STRK currently sitting on Counter v2 can be swept back to the burner if v2 is decommissioned, but it's not blocking — v2 keeps working as a deprecated single-hop contract. We'll send a fresh ~4 STRK to v3 in `08_fund_counter_strk.sh`.

---

## 9. Testing

### 9.1 Solidity (forge)

- `triggerAbaIncrement` builds the expected 17-byte payload (`0x01` ‖ two u64s big-endian).
- `quoteAbaIncrement` returns a non-zero `nativeFee`.
- `_lzReceive` still increments correctly on a 32-byte plain payload (regression test).
- Reverts on `msg.value < fee.nativeFee`.

### 9.2 Cairo (snforge, currently scaffolded but no tests written)

We will write the first snforge tests as part of this work, using a mocked endpoint:

- `_lz_receive` with 32-byte payload increments by the decoded u64 (plain path regression).
- `_lz_receive` with 17-byte payload increments by `by_sn` AND emits `AbaBounceSent`.
- `_lz_receive` with 17-byte payload and unknown tag byte reverts.
- `_lz_receive` with any other length reverts.
- `set_return_options` is owner-gated.
- `withdraw_strk` is owner-gated.

Mock endpoint can lean on `node_modules/@layerzerolabs/protocol-starknet-v2/layerzero/tests/mocks/` (which exists per the grep in section 3).

### 9.3 End-to-end on Sepolia

- Run `07_aba_smoke_test.sh` with `by_sn=5, by_eth=3`.
- Pre-condition: snapshot both counters.
- Post-condition (within ~5 min): SN count up by 5, ETH count up by 3.
- Verify on layerzeroscan that both messages settled.

---

## 10. Things explicitly out of scope

- **Per-tx tunable return gas/value via the payload.** Hardcoded in the contract, owner-tunable. If we ever need per-tx tuning, bump the ABA tag to `0x02` and extend the payload format. Not now.
- **Slippage / fee headroom.** The user pays `msg.value = fee.nativeFee` exactly; excess is refunded. No 1.5× headroom on the ETH side. The Cairo return-leg quote and send happen in the same `_lz_receive` transaction, so there's no inter-tx fee race to buffer against.
- **lzCompose pattern.** Considered and rejected. Length-discriminated payload achieves the same observable behavior with less code.
- **Mainnet.** Stays on Sepolia. Mainnet deploy is a separate, gated decision.
- **Argent X / Braavos wallet support.** Burner-only, like the existing buttons.
- **Voyager / Etherscan source verification.** Tracked separately as Phase 10.

---

## 11. Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Cairo `_lz_send` from self fails for a reason not visible in the `oapp_core` source (e.g., endpoint requires actual transferFrom event) | Low | First implementation step is a minimal Cairo test that calls `_lz_send` with `caller=self` against a mock endpoint, before wiring it into `_lz_receive`. If it fails, we fall back to either (a) the contract approving itself to spend its own STRK in an init function, or (b) the contract holding allowance to itself. |
| SN-leg executor gas (1,000,000 default) is too low — the `_lz_receive` does more work than a single hop (a read, an emit, AND a full `_lz_send` round) | Medium | Quote against testnet, bump until it works, document the final number. |
| Contract STRK balance runs out mid-demo | Low (4 STRK = many hops) | `08_fund_counter_strk.sh` is one command; document the threshold in STATUS.md. |
| Length discriminator collides if someone adds another message shape later | Low | The `0x01` leading tag inside the 17-byte payload provides a second axis of disambiguation. Future shapes can use other tags. |
| Inbound 32-byte payload that happens to start with `0x00...0x01` looks ambiguous | None | They're distinguishable by length first, so byte content doesn't matter for routing. |

---

## 12. Definition of done

1. Cairo Counter v3 deployed to Starknet Sepolia, peered with v3 EVM contract.
2. EVM CounterTrigger v3 deployed to Ethereum Sepolia, peered with v3 Cairo contract.
3. Counter v3 funded with ≥3 STRK.
4. Frontend updated with third "ABA" zone; deployed to Vercel.
5. End-to-end test: one click on `https://crosschain-strk20.vercel.app` with `by_sn=5, by_eth=3` results in both counters incrementing, observable from the page, within ~5 minutes.
6. `STATUS.md` updated with v3 addresses; Counter v2 marked deprecated.
7. `PROGRESS.md` gets a Session 12 narrative.
8. `forge test` and `scarb build` both green.
9. At least the four core snforge tests listed in §9.2 written and passing.
