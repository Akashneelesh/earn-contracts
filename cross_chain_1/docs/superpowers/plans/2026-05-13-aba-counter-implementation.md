# ABA Counter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a one-click "ABA bounce" flow — user clicks BOUNCE on the page, signs once with the ETH burner, both counters increment (Starknet first, then Ethereum) via LayerZero V2, with the Cairo contract paying its own return-leg fee from a pre-funded STRK balance.

**Architecture:** Add a 17-byte ABA payload format to the existing 32-byte plain payload. Cairo `_lz_receive` dispatches on `message.len()`: plain → increment only; ABA → increment + immediately call `_lz_send(self, ...)` to bounce a plain return message back. Self-pay is unlocked by the existing `caller == contract_address` carve-out in `OAppCoreComponent::_pay_native` / `_pay_in_token` (no protocol fork required).

**Tech Stack:** Cairo 2.16 + Scarb + LayerZero protocol-starknet-v2 0.2.90 (OZ pinned `=2.0.0`), Solidity 0.8.22 + Foundry + LayerZero oapp-evm, snforge 0.53 for Cairo tests, forge for Solidity tests, sncast 0.60 for Starknet ops, ethers v6 + starknet.js v7.5 in the browser, Vercel for hosting.

---

## Spec reference

Read first: `cross_chain/docs/superpowers/specs/2026-05-13-aba-counter-design.md`. Section numbers in this plan refer back to it.

## Working directory

All paths in this plan are relative to `/Users/akash/Desktop/earn-contracts/cross_chain/`. **All git commands are run from this directory** — `cross_chain/` is its own nested git repo with a `main` branch tracked at `git@github.com:Akashneelesh/crosschain-layerzero`. The parent `earn-contracts` repo is unrelated and untouched.

## File structure overview

**New files:**

| Path | Purpose |
|---|---|
| `starknet_oapp/tests/lib.cairo` | snforge test crate root |
| `starknet_oapp/tests/test_counter.cairo` | Counter unit + integration tests |
| `starknet_oapp/tests/mock_endpoint.cairo` | Minimal Cairo mock of `IEndpointV2` (records `send` calls) |
| `eth_sender/test/CounterTrigger.t.sol` | Forge tests for v3 (mirrors `StringSender.t.sol` MockEndpoint pattern) |
| `eth_sender/script/DeployCounterTriggerV3.s.sol` | Deploy script (writes `COUNTER_TRIGGER_V3` back to .env) |
| `scripts/10_deploy_counter_v3_starknet.sh` | Build, declare, deploy Counter v3 on Starknet |
| `scripts/11_deploy_counter_trigger_v3_eth.sh` | Deploy CounterTrigger v3 on Ethereum |
| `scripts/12_wire_counter_v3_peers.sh` | `setPeer` on both sides for v3 addresses |
| `scripts/13_fund_counter_v3_strk.sh` | Transfer STRK from the burner to Counter v3's contract address |
| `scripts/14_set_return_options.sh` | Owner-only: update `return_gas` / `return_value` |
| `scripts/15_aba_smoke_test.sh` | End-to-end CLI smoke test (quote → triggerAba → poll both counts) |

**Modified files:**

| Path | What changes |
|---|---|
| `starknet_oapp/src/counter.cairo` | Add ABA dispatcher in `_lz_receive`, `return_gas`/`return_value` storage, `set_return_options`, `withdraw_strk`, `AbaBounceSent` event |
| `eth_sender/src/CounterTrigger.sol` | Add `SEND_ABA` option-key, `triggerAbaIncrement`, `quoteAbaIncrement`, `defaultAbaOptions`, `AbaIncrementTriggered` event |
| `.env.example` | Add `COUNTER_V3_STARKNET`, `COUNTER_V3_ETH`, `COUNTER_V3_STARKNET_PEER_BYTES32`, `RETURN_LEG_GAS`, `RETURN_LEG_VALUE` |
| `frontend/config.example.js` | Add `COUNTER_V3_ETH`, `COUNTER_V3_SN` |
| `frontend/config.js` | Same (with real values, gitignored) |
| `frontend/index.html` | Add third zone below the dual lanes — two number inputs + BOUNCE button + status row |
| `frontend/style.css` | Style the third zone consistent with existing brutalist editorial |
| `frontend/app.js` | Add `pressAba()` flow + counter wiring for the new contracts |
| `STATUS.md` | New v3 row in the contracts table; mark v2 deprecated |
| `PROGRESS.md` | Append Session 12 narrative |

**Why this split:** Each modified contract file stays focused on its own chain. Tests live next to the contracts they exercise. Scripts are numbered to match the existing operational runbook. Frontend stays a single static page — no framework introduced.

---

## Stages overview

- **Stage A (Cairo):** Add ABA path + helpers to `counter.cairo` with snforge TDD.
- **Stage B (Solidity):** Add ABA path to `CounterTrigger.sol` with forge TDD.
- **Stage C (Scripts):** Build new operational scripts targeted at v3.
- **Stage D (Sepolia):** Deploy + wire + fund + smoke-test on real testnet.
- **Stage E (Frontend):** Add the third zone, wire it up, smoke-test locally.
- **Stage F (Docs + Vercel):** Update STATUS/PROGRESS, deploy to production, final E2E.

Each stage commits incrementally. The branch is `main` of the `cross_chain` repo (no PR workflow here — single-developer, push directly to `origin/main` per the existing pattern).

---

## Stage A — Cairo Counter v3

### Task A1: Set up snforge test scaffold

**Files:**
- Create: `starknet_oapp/tests/lib.cairo`
- Create: `starknet_oapp/tests/test_counter.cairo`
- Create: `starknet_oapp/tests/mock_endpoint.cairo`

**Background:** `starknet_oapp/tests/` exists as an empty directory. Scarb does not pick up tests under `tests/` unless they form a sibling crate. `snforge_std` is already a dev dependency in `starknet_oapp/Scarb.toml`.

- [ ] **Step 1: Create `tests/lib.cairo` registering the test modules**

```cairo
// starknet_oapp/tests/lib.cairo
mod mock_endpoint;
mod test_counter;
```

- [ ] **Step 2: Create a minimal mock endpoint stub**

```cairo
// starknet_oapp/tests/mock_endpoint.cairo
// Records `send` calls so tests can assert what _lz_receive forwarded.
// Returns a fixed fee from `quote`.

use starknet::ContractAddress;
use layerzero::common::structs::messaging::{MessagingFee, MessageReceipt, MessagingParams};
use lz_utils::bytes::Bytes32;

#[starknet::interface]
pub trait IMockEndpoint<TState> {
    fn last_send_dst_eid(self: @TState) -> u32;
    fn last_send_message(self: @TState) -> ByteArray;
    fn last_send_options(self: @TState) -> ByteArray;
    fn send_call_count(self: @TState) -> u32;
    fn set_quoted_fee(ref self: TState, native_fee: u256);
}

#[starknet::contract]
pub mod MockEndpoint {
    use super::{ContractAddress, MessagingFee, MessageReceipt, MessagingParams, Bytes32};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

    #[storage]
    struct Storage {
        quoted_native_fee: u256,
        send_call_count: u32,
        last_send_dst_eid: u32,
        last_send_message: ByteArray,
        last_send_options: ByteArray,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.quoted_native_fee.write(1000000000000000000_u256); // 1 STRK
    }

    #[abi(embed_v0)]
    impl ViewsImpl of super::IMockEndpoint<ContractState> {
        fn last_send_dst_eid(self: @ContractState) -> u32 { self.last_send_dst_eid.read() }
        fn last_send_message(self: @ContractState) -> ByteArray { self.last_send_message.read() }
        fn last_send_options(self: @ContractState) -> ByteArray { self.last_send_options.read() }
        fn send_call_count(self: @ContractState) -> u32 { self.send_call_count.read() }
        fn set_quoted_fee(ref self: ContractState, native_fee: u256) {
            self.quoted_native_fee.write(native_fee);
        }
    }

    // EndpointV2 surface the OApp actually touches. Keep signatures matching
    // `IEndpointV2` from `layerzero::endpoint::interface`. If the trait there
    // has more methods, add stubs that revert with a clear message — we'll
    // discover them during compilation.
    #[external(v0)]
    fn set_delegate(ref self: ContractState, _delegate: ContractAddress) {
        // no-op: OApp initializer calls this; we don't care about it for tests
    }

    #[external(v0)]
    fn quote(
        self: @ContractState,
        _params: MessagingParams,
        _sender: ContractAddress,
    ) -> MessagingFee {
        MessagingFee { native_fee: self.quoted_native_fee.read(), lz_token_fee: 0 }
    }

    #[external(v0)]
    fn send(
        ref self: ContractState,
        params: MessagingParams,
        _refund_address: ContractAddress,
    ) -> MessageReceipt {
        self.send_call_count.write(self.send_call_count.read() + 1);
        self.last_send_dst_eid.write(params.dst_eid);
        self.last_send_message.write(params.message.clone());
        self.last_send_options.write(params.options.clone());
        MessageReceipt {
            guid: Bytes32 { value: 0xdeadbeef.into() },
            nonce: 1,
            fee: MessagingFee { native_fee: self.quoted_native_fee.read(), lz_token_fee: 0 },
        }
    }
}
```

Note: this stub may not compile on first pass because `IEndpointV2` from the layerzero crate likely has more required methods. If `scarb build` complains, read `node_modules/@layerzerolabs/protocol-starknet-v2/layerzero/src/endpoint/interface.cairo` and add stub implementations for the missing methods, each one reverting with `panic_with_felt252('not_implemented')`.

- [ ] **Step 3: Create a placeholder test file**

```cairo
// starknet_oapp/tests/test_counter.cairo
use snforge_std::{declare, ContractClassTrait, DeclareResultTrait};

#[test]
fn smoke() {
    // Tautology — proves the scaffold compiles and snforge can run.
    assert!(1 + 1 == 2);
}
```

- [ ] **Step 4: Run snforge**

Run: `cd starknet_oapp && scarb test`
Expected: `Tests: 1 passed, 0 failed, 0 ignored`

If it fails because the mock_endpoint doesn't compile, fix the missing trait methods (see Step 2 note) and re-run.

- [ ] **Step 5: Commit**

```bash
git add starknet_oapp/tests/
git commit -m "test(cairo): scaffold snforge test crate with mock endpoint"
```

---

### Task A2: Add return_gas / return_value storage + owner-only setter

**Files:**
- Modify: `starknet_oapp/src/counter.cairo`
- Modify: `starknet_oapp/tests/test_counter.cairo`

**Background:** ABA flow needs configurable `return_gas` (executor gas for the SN→ETH leg) and `return_value` (msg.value forwarded to `_lzReceive`). Spec §6.1 defines defaults: `200_000` and `0`.

- [ ] **Step 1: Write failing test for the owner-only setter**

Append to `starknet_oapp/tests/test_counter.cairo`:

```cairo
use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait, start_cheat_caller_address,
    stop_cheat_caller_address,
};
use starknet::ContractAddress;

const OWNER: felt252 = 0xAAAA;
const NOT_OWNER: felt252 = 0xBBBB;
const FAKE_ENDPOINT: felt252 = 0xCCCC;
const FAKE_STRK: felt252 = 0xDDDD;

fn deploy_counter() -> (ContractAddress, ICounterDispatcher) {
    let contract = declare("Counter").unwrap().contract_class();
    let owner: ContractAddress = OWNER.try_into().unwrap();
    let endpoint: ContractAddress = FAKE_ENDPOINT.try_into().unwrap();
    let strk: ContractAddress = FAKE_STRK.try_into().unwrap();
    // The mock endpoint must be deployed first if the OApp constructor calls
    // set_delegate on it (it does). Use the MockEndpoint:
    // For tests that don't exercise _lz_send, a non-contract address as
    // `endpoint` is OK *if* OAppCoreComponent::initializer's set_delegate
    // tolerates a non-contract address. If not, we'll deploy MockEndpoint.
    //
    // First try the simple path; if deploy panics on set_delegate, switch.
    let (addr, _) = contract
        .deploy(@array![endpoint.into(), owner.into(), strk.into()])
        .unwrap();
    (addr, ICounterDispatcher { contract_address: addr })
}

#[starknet::interface]
trait ICounter<T> {
    fn count(self: @T) -> u64;
    fn last_increment_by(self: @T) -> u64;
    fn last_src_eid(self: @T) -> u32;
    fn return_gas(self: @T) -> u128;
    fn return_value(self: @T) -> u128;
    fn set_return_options(ref self: T, gas: u128, value: u128);
}

#[test]
fn return_options_have_correct_defaults() {
    let (_addr, counter) = deploy_counter();
    assert!(counter.return_gas() == 200_000_u128);
    assert!(counter.return_value() == 0_u128);
}

#[test]
fn owner_can_set_return_options() {
    let (addr, counter) = deploy_counter();
    let owner: ContractAddress = OWNER.try_into().unwrap();
    start_cheat_caller_address(addr, owner);
    counter.set_return_options(500_000_u128, 42_u128);
    stop_cheat_caller_address(addr);
    assert!(counter.return_gas() == 500_000_u128);
    assert!(counter.return_value() == 42_u128);
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn non_owner_cannot_set_return_options() {
    let (addr, counter) = deploy_counter();
    let not_owner: ContractAddress = NOT_OWNER.try_into().unwrap();
    start_cheat_caller_address(addr, not_owner);
    counter.set_return_options(500_000_u128, 0_u128);
}
```

- [ ] **Step 2: Run tests, confirm failures**

Run: `cd starknet_oapp && scarb test`
Expected: 3 new tests fail (compile error: methods `return_gas`, `return_value`, `set_return_options` not defined on `Counter`).

If deploy itself fails because `set_delegate` reverts (the OApp initializer calls it on the endpoint), update `deploy_counter` to deploy `MockEndpoint` first and pass its address. Pattern:

```cairo
let mock_ep_class = declare("MockEndpoint").unwrap().contract_class();
let (ep_addr, _) = mock_ep_class.deploy(@array![]).unwrap();
let endpoint: ContractAddress = ep_addr;
```

- [ ] **Step 3: Add storage + setter + getters to the Counter contract**

Modify `starknet_oapp/src/counter.cairo`:

In `struct Storage`, add:

```cairo
return_gas: u128,
return_value: u128,
```

In `constructor`, after the existing initializer calls, add:

```cairo
self.return_gas.write(200_000_u128);
self.return_value.write(0_u128);
```

In the `ICounterViews` interface, add:

```cairo
fn return_gas(self: @TState) -> u128;
fn return_value(self: @TState) -> u128;
fn set_return_options(ref self: TState, gas: u128, value: u128);
```

In the `Views` impl, add:

```cairo
fn return_gas(self: @ContractState) -> u128 { self.return_gas.read() }
fn return_value(self: @ContractState) -> u128 { self.return_value.read() }
fn set_return_options(ref self: ContractState, gas: u128, value: u128) {
    self.ownable.assert_only_owner();
    self.return_gas.write(gas);
    self.return_value.write(value);
}
```

- [ ] **Step 4: Run tests, confirm pass**

Run: `cd starknet_oapp && scarb test`
Expected: all 4 tests (including `smoke`) pass.

- [ ] **Step 5: Commit**

```bash
git add starknet_oapp/src/counter.cairo starknet_oapp/tests/test_counter.cairo
git commit -m "feat(cairo): add owner-gated return options on Counter"
```

---

### Task A3: Add owner-only `withdraw_strk`

**Files:**
- Modify: `starknet_oapp/src/counter.cairo`
- Modify: `starknet_oapp/tests/test_counter.cairo`

**Background:** Spec §6.1: lets the owner sweep residual STRK when decommissioning the demo. Reads STRK address from the OApp component's `OAppCore_native_token` storage (declared `pub`).

- [ ] **Step 1: Write failing test for non-owner revert**

Append to `test_counter.cairo`:

```cairo
#[starknet::interface]
trait ICounterWithdraw<T> {
    fn withdraw_strk(ref self: T, to: ContractAddress, amount: u256);
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn non_owner_cannot_withdraw_strk() {
    let (addr, _counter) = deploy_counter();
    let not_owner: ContractAddress = NOT_OWNER.try_into().unwrap();
    let to: ContractAddress = 0xEEEE.try_into().unwrap();
    let withdraw = ICounterWithdrawDispatcher { contract_address: addr };
    start_cheat_caller_address(addr, not_owner);
    withdraw.withdraw_strk(to, 1_u256);
}
```

Note: we don't test the happy path here because that needs a real ERC20 mock for STRK; the owner-gate test is sufficient for unit-level. End-to-end coverage comes from the Sepolia smoke test.

- [ ] **Step 2: Run test, confirm failure**

Run: `cd starknet_oapp && scarb test`
Expected: compile error — `withdraw_strk` not defined.

- [ ] **Step 3: Add `withdraw_strk` to the contract**

In `counter.cairo`, add this import near the top:

```cairo
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
```

In the `ICounterViews` interface:

```cairo
fn withdraw_strk(ref self: TState, to: ContractAddress, amount: u256);
```

In the `Views` impl:

```cairo
fn withdraw_strk(ref self: ContractState, to: ContractAddress, amount: u256) {
    self.ownable.assert_only_owner();
    let strk = self.oapp_core.OAppCore_native_token.read();
    let _ = IERC20Dispatcher { contract_address: strk }.transfer(to, amount);
}
```

- [ ] **Step 4: Run tests, confirm pass**

Run: `cd starknet_oapp && scarb test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add starknet_oapp/src/counter.cairo starknet_oapp/tests/test_counter.cairo
git commit -m "feat(cairo): add owner-only withdraw_strk on Counter"
```

---

### Task A4: Refactor `_lz_receive` to dispatch by message length (no behavior change yet)

**Files:**
- Modify: `starknet_oapp/src/counter.cairo`
- Modify: `starknet_oapp/tests/test_counter.cairo`

**Background:** Spec §5. Wrap the existing 32-byte handling in a length-discriminator without changing observable behavior. ABA path is added in Task A5. After this task, the only visible new behavior is that a wrong-length payload reverts with `BAD_PAYLOAD_LEN`.

- [ ] **Step 1: Write failing test for plain-path regression + bad-length revert**

Append to `test_counter.cairo`:

```cairo
use snforge_std::{spy_events, EventSpyAssertionsTrait};

const SRC_EID: u32 = 40161;

#[starknet::interface]
trait ILzReceiver<T> {
    fn lz_receive(
        ref self: T,
        origin: layerzero::Origin,
        guid: lz_utils::bytes::Bytes32,
        message: ByteArray,
        executor: starknet::ContractAddress,
        extra_data: ByteArray,
    );
}

// Pretend to be the endpoint and deliver a payload to _lz_receive directly.
// OAppCoreComponent::_assert_only_endpoint reads the endpoint address from
// storage; we set it via the constructor.
fn deliver(addr: ContractAddress, endpoint: ContractAddress, payload: ByteArray) {
    let origin = layerzero::Origin {
        src_eid: SRC_EID,
        sender: lz_utils::bytes::Bytes32 { value: 0x1.into() },
        nonce: 1,
    };
    let guid = lz_utils::bytes::Bytes32 { value: 0xabc.into() };
    let executor: ContractAddress = 0xFFFF.try_into().unwrap();
    let extra: ByteArray = Default::default();
    start_cheat_caller_address(addr, endpoint);
    ILzReceiverDispatcher { contract_address: addr }
        .lz_receive(origin, guid, payload, executor, extra);
    stop_cheat_caller_address(addr);
}

fn encode_plain(by: u64) -> ByteArray {
    // 24 zero bytes + 8 big-endian bytes
    let mut out: ByteArray = Default::default();
    let mut i = 0_u32;
    while i < 24 { out.append_byte(0); i += 1; };
    let mut v = by;
    let mut tmp: Array<u8> = ArrayTrait::new();
    let mut j = 0_u32;
    while j < 8 { tmp.append((v % 256).try_into().unwrap()); v = v / 256; j += 1; };
    let mut k = 8_u32;
    while k > 0 { k -= 1; out.append_byte(*tmp.at(k)); };
    out
}

#[test]
fn plain_32byte_payload_increments_count() {
    // Deploy with the MockEndpoint set as endpoint so _assert_only_endpoint passes.
    let mock = declare("MockEndpoint").unwrap().contract_class();
    let (ep, _) = mock.deploy(@array![]).unwrap();
    let cls = declare("Counter").unwrap().contract_class();
    let owner: ContractAddress = OWNER.try_into().unwrap();
    let strk: ContractAddress = FAKE_STRK.try_into().unwrap();
    let (addr, _) = cls.deploy(@array![ep.into(), owner.into(), strk.into()]).unwrap();

    deliver(addr, ep, encode_plain(7));

    let counter = ICounterDispatcher { contract_address: addr };
    assert!(counter.count() == 7);
    assert!(counter.last_increment_by() == 7);
    assert!(counter.last_src_eid() == SRC_EID);
}

#[test]
#[should_panic(expected: ('BAD_PAYLOAD_LEN',))]
fn unknown_length_payload_reverts() {
    let mock = declare("MockEndpoint").unwrap().contract_class();
    let (ep, _) = mock.deploy(@array![]).unwrap();
    let cls = declare("Counter").unwrap().contract_class();
    let owner: ContractAddress = OWNER.try_into().unwrap();
    let strk: ContractAddress = FAKE_STRK.try_into().unwrap();
    let (addr, _) = cls.deploy(@array![ep.into(), owner.into(), strk.into()]).unwrap();

    let mut payload: ByteArray = Default::default();
    let mut i = 0_u32;
    while i < 20 { payload.append_byte(0xff); i += 1; }; // 20 bytes ≠ 17 or 32
    deliver(addr, ep, payload);
}
```

- [ ] **Step 2: Run tests, confirm failure modes**

Run: `cd starknet_oapp && scarb test`
Expected: `plain_32byte_payload_increments_count` passes (existing code already does this); `unknown_length_payload_reverts` fails (current code accepts any length).

- [ ] **Step 3: Refactor `_lz_receive` with length dispatch**

Replace the existing `_lz_receive` body in `counter.cairo`:

```cairo
fn _lz_receive(
    ref self: OAppCoreComponent::ComponentState<ContractState>,
    origin: Origin,
    guid: Bytes32,
    message: ByteArray,
    executor: ContractAddress,
    extra_data: ByteArray,
    value: u256,
) {
    let _ = executor;
    let _ = extra_data;
    let _ = value;

    let len = message.len();
    if len == PLAIN_PAYLOAD_LEN {
        let by = read_u64_be_at(@message, 24);
        let mut contract = self.get_contract_mut();
        let new_count = contract.count.read() + by;
        contract.count.write(new_count);
        contract.last_increment_by.write(by);
        contract.last_src_eid.write(origin.src_eid);
        contract.emit(Incremented { src_eid: origin.src_eid, guid, by, new_count });
    } else {
        // ABA branch goes here in Task A5; for now anything not-plain reverts.
        panic_with_byte_array(@"BAD_PAYLOAD_LEN");
    }
}
```

Add constants at the top of the module:

```cairo
const PLAIN_PAYLOAD_LEN: u32 = 32;
const ABA_PAYLOAD_LEN: u32 = 17;
const ABA_TAG: u8 = 0x01;
```

If `panic_with_byte_array` is not imported, use:

```cairo
use core::panics::panic_with_byte_array;
```

or fall back to `assert_with_byte_array(false, @"BAD_PAYLOAD_LEN");` (which is already used elsewhere in the OApp dependency).

- [ ] **Step 4: Run tests, confirm pass**

Run: `cd starknet_oapp && scarb test`
Expected: both new tests pass plus all earlier tests still pass.

- [ ] **Step 5: Commit**

```bash
git add starknet_oapp/src/counter.cairo starknet_oapp/tests/test_counter.cairo
git commit -m "refactor(cairo): dispatch _lz_receive on message length, reject unknown shapes"
```

---

### Task A5: Add ABA path — increment by_sn portion + emit event

**Files:**
- Modify: `starknet_oapp/src/counter.cairo`
- Modify: `starknet_oapp/tests/test_counter.cairo`

- [ ] **Step 1: Write failing test for ABA payload incrementing by_sn**

Append to `test_counter.cairo`:

```cairo
fn encode_aba(by_sn: u64, by_eth: u64) -> ByteArray {
    let mut out: ByteArray = Default::default();
    out.append_byte(0x01);
    // by_sn big-endian
    let mut v = by_sn;
    let mut tmp: Array<u8> = ArrayTrait::new();
    let mut j = 0_u32;
    while j < 8 { tmp.append((v % 256).try_into().unwrap()); v = v / 256; j += 1; };
    let mut k = 8_u32;
    while k > 0 { k -= 1; out.append_byte(*tmp.at(k)); };
    // by_eth big-endian
    let mut v2 = by_eth;
    let mut tmp2: Array<u8> = ArrayTrait::new();
    let mut j2 = 0_u32;
    while j2 < 8 { tmp2.append((v2 % 256).try_into().unwrap()); v2 = v2 / 256; j2 += 1; };
    let mut k2 = 8_u32;
    while k2 > 0 { k2 -= 1; out.append_byte(*tmp2.at(k2)); };
    out
}

#[test]
fn aba_payload_increments_count_by_by_sn() {
    let mock = declare("MockEndpoint").unwrap().contract_class();
    let (ep, _) = mock.deploy(@array![]).unwrap();
    let cls = declare("Counter").unwrap().contract_class();
    let owner: ContractAddress = OWNER.try_into().unwrap();
    let strk: ContractAddress = FAKE_STRK.try_into().unwrap();
    let (addr, _) = cls.deploy(@array![ep.into(), owner.into(), strk.into()]).unwrap();

    deliver(addr, ep, encode_aba(5, 3));

    let counter = ICounterDispatcher { contract_address: addr };
    assert!(counter.count() == 5);
    assert!(counter.last_increment_by() == 5);
    assert!(counter.last_src_eid() == SRC_EID);
}

#[test]
#[should_panic(expected: ('BAD_ABA_TAG',))]
fn aba_payload_with_unknown_tag_reverts() {
    let mock = declare("MockEndpoint").unwrap().contract_class();
    let (ep, _) = mock.deploy(@array![]).unwrap();
    let cls = declare("Counter").unwrap().contract_class();
    let owner: ContractAddress = OWNER.try_into().unwrap();
    let strk: ContractAddress = FAKE_STRK.try_into().unwrap();
    let (addr, _) = cls.deploy(@array![ep.into(), owner.into(), strk.into()]).unwrap();

    // 17 bytes, leading byte 0x99 (not ABA_TAG)
    let mut bad: ByteArray = Default::default();
    bad.append_byte(0x99);
    let mut i = 0_u32;
    while i < 16 { bad.append_byte(0); i += 1; };
    deliver(addr, ep, bad);
}
```

- [ ] **Step 2: Run tests, confirm failure**

Run: `cd starknet_oapp && scarb test`
Expected: `aba_payload_increments_count_by_by_sn` and `aba_payload_with_unknown_tag_reverts` fail (currently 17 bytes revert with `BAD_PAYLOAD_LEN`).

- [ ] **Step 3: Add ABA increment branch (no bounce yet)**

In `counter.cairo`, replace the `else { panic... }` branch with:

```cairo
} else if len == ABA_PAYLOAD_LEN {
    let tag = message.at(0).unwrap();
    assert_with_byte_array(tag == ABA_TAG, @"BAD_ABA_TAG");
    let by_sn = read_u64_be_at(@message, 1);
    let _by_eth = read_u64_be_at(@message, 9); // wired up in A6

    let mut contract = self.get_contract_mut();
    let new_count = contract.count.read() + by_sn;
    contract.count.write(new_count);
    contract.last_increment_by.write(by_sn);
    contract.last_src_eid.write(origin.src_eid);
    contract.emit(Incremented { src_eid: origin.src_eid, guid, by: by_sn, new_count });
} else {
    assert_with_byte_array(false, @"BAD_PAYLOAD_LEN");
}
```

- [ ] **Step 4: Run tests**

Run: `cd starknet_oapp && scarb test`
Expected: all tests including the two new ones pass.

- [ ] **Step 5: Commit**

```bash
git add starknet_oapp/src/counter.cairo starknet_oapp/tests/test_counter.cairo
git commit -m "feat(cairo): ABA payload increments local counter by by_sn"
```

---

### Task A6: Add ABA path — bounce return message via self-pay `_lz_send`

**Files:**
- Modify: `starknet_oapp/src/counter.cairo`
- Modify: `starknet_oapp/tests/test_counter.cairo`

**Background:** Spec §3 + §6.1. Pass `get_contract_address()` as the `caller` to `_lz_send` so the OApp's existing `caller == contract_address` carve-out skips `transferFrom` — the endpoint then pulls the fee directly from the OApp's STRK balance.

- [ ] **Step 1: Write failing test that the mock endpoint sees a `send` call**

Append to `test_counter.cairo`:

```cairo
#[starknet::interface]
trait IMockEndpointReader<T> {
    fn last_send_dst_eid(self: @T) -> u32;
    fn last_send_message(self: @T) -> ByteArray;
    fn send_call_count(self: @T) -> u32;
}

#[test]
fn aba_payload_triggers_return_lz_send_to_origin_eid() {
    let mock = declare("MockEndpoint").unwrap().contract_class();
    let (ep, _) = mock.deploy(@array![]).unwrap();
    let cls = declare("Counter").unwrap().contract_class();
    let owner: ContractAddress = OWNER.try_into().unwrap();
    let strk: ContractAddress = FAKE_STRK.try_into().unwrap();
    let (addr, _) = cls.deploy(@array![ep.into(), owner.into(), strk.into()]).unwrap();

    // Peer setup so _lz_send doesn't revert with no_peer
    let peer = lz_utils::bytes::Bytes32 { value: 0xCAFE.into() };
    let owner_addr: ContractAddress = owner;
    start_cheat_caller_address(addr, owner_addr);
    ICounterPeerDispatcher { contract_address: addr }.set_peer(SRC_EID, peer);
    stop_cheat_caller_address(addr);

    deliver(addr, ep, encode_aba(5, 3));

    let reader = IMockEndpointReaderDispatcher { contract_address: ep };
    assert!(reader.send_call_count() == 1);
    assert!(reader.last_send_dst_eid() == SRC_EID);
    // Return message is a 32-byte plain payload encoding by_eth=3.
    let sent = reader.last_send_message();
    assert!(sent.len() == 32);
    // The last byte should be 3 (big-endian, right-aligned 8B value).
    assert!(sent.at(31).unwrap() == 3_u8);
}

#[starknet::interface]
trait ICounterPeer<T> {
    fn set_peer(ref self: T, eid: u32, peer: lz_utils::bytes::Bytes32);
}
```

- [ ] **Step 2: Run test, confirm failure**

Run: `cd starknet_oapp && scarb test`
Expected: `aba_payload_triggers_return_lz_send_to_origin_eid` fails because send is never called.

- [ ] **Step 3: Add bounce-back logic**

In `counter.cairo`, at the top of the file (with other use statements), add:

```cairo
use starknet::get_contract_address;
use layerzero::oapps::counter::options::executor_lz_receive_option;
use layerzero::common::structs::messaging::MessagingFee;
```

(If `executor_lz_receive_option` is already imported via the existing `trigger_increment` path, skip.)

In the `_lz_receive` ABA branch, after the `Incremented` emit, append:

```cairo
// Bounce back: plain 32-byte payload encoding by_eth to origin EID.
let by_eth = read_u64_be_at(@message, 9);
let self_addr = get_contract_address();
let return_payload = encode_uint64_abi(by_eth);
let return_options = executor_lz_receive_option(
    contract.return_gas.read(),
    contract.return_value.read().into(),
);
let fee = self._quote(
    origin.src_eid,
    return_payload.clone(),
    return_options.clone(),
    false,
);
let receipt = self._lz_send(
    self_addr,
    origin.src_eid,
    return_payload,
    return_options,
    fee,
    self_addr,
);
contract.emit(AbaBounceSent {
    dst_eid: origin.src_eid,
    guid: receipt.guid,
    by_eth,
});
```

Add the `AbaBounceSent` event to the contract's `Event` enum and define it:

```cairo
#[derive(Drop, starknet::Event)]
pub struct AbaBounceSent {
    #[key]
    pub dst_eid: u32,
    pub guid: Bytes32,
    pub by_eth: u64,
}
```

And add to the `Event` enum:

```cairo
AbaBounceSent: AbaBounceSent,
```

Note on `self._quote` / `self._lz_send`: these are on `OAppCoreComponent::ComponentState`, accessed inside the hook via the component's `OAppSenderImpl`. The exact call form mirrors `trigger_increment` in the same file — refer to lines 141-144 of the current `counter.cairo`. Within the `_lz_receive` hook, `self` is `ComponentState<ContractState>`, so the call is `self._quote(...)` directly (no `oapp_core.` prefix needed).

If the call form differs (e.g., must go through `OAppCoreComponent::OAppSenderImpl::_lz_send(ref self, ...)`), follow the compiler error guidance.

- [ ] **Step 4: Run tests**

Run: `cd starknet_oapp && scarb test`
Expected: all tests pass.

Likely failure modes:
- "no_peer_set": the test forgot to call `set_peer` — already addressed in Step 1.
- "not_enough_native": fee greater than 0 but contract STRK balance is 0. In the mock endpoint we set `quoted_fee = 1 STRK`; for the test we need either (a) the mock to return fee=0, or (b) deploy a mock STRK token and pre-fund the contract. Easiest: set `quoted_fee = 0` in the test via `MockEndpoint.set_quoted_fee(0)` before delivery.

If (b) is needed because the OApp code rejects fee=0, deploy an `openzeppelin_token::erc20::ERC20Mock` or write a 30-line ERC20 mock and pre-mint to the contract.

- [ ] **Step 5: Commit**

```bash
git add starknet_oapp/src/counter.cairo starknet_oapp/tests/test_counter.cairo
git commit -m "feat(cairo): ABA path bounces return message via self-paid _lz_send"
```

---

### Task A7: Final Cairo sanity build + scarb fmt

- [ ] **Step 1: Format Cairo source**

Run: `cd starknet_oapp && scarb fmt`

- [ ] **Step 2: Full build + test**

Run: `cd starknet_oapp && scarb build && scarb test`
Expected: build clean, all tests pass.

- [ ] **Step 3: Commit any formatting churn**

```bash
git add -u starknet_oapp/
git commit -m "style(cairo): scarb fmt" || echo "nothing to format"
```

---

## Stage B — Solidity CounterTrigger v3

### Task B1: Scaffold the forge test file with a mock endpoint

**Files:**
- Create: `eth_sender/test/CounterTrigger.t.sol`

**Background:** Mirror the existing `StringSender.t.sol` MockEndpoint pattern.

- [ ] **Step 1: Create the test file with MockEndpoint + setup**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {CounterTrigger} from "../src/CounterTrigger.sol";
import {
    MessagingFee, MessagingParams, MessagingReceipt, Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

contract MockEndpoint {
    uint32 public constant LOCAL_EID = 40161;
    MessagingParams public lastSendParams;
    address public lastRefund;
    uint256 public lastValue;
    address public delegate;
    uint256 public quotedNativeFee = 0.0001 ether;

    function eid() external pure returns (uint32) { return LOCAL_EID; }
    function setDelegate(address d) external { delegate = d; }
    function quote(MessagingParams calldata, address)
        external view returns (MessagingFee memory)
    { return MessagingFee({nativeFee: quotedNativeFee, lzTokenFee: 0}); }
    function send(MessagingParams calldata params, address refund)
        external payable returns (MessagingReceipt memory)
    {
        lastSendParams = params;
        lastRefund = refund;
        lastValue = msg.value;
        return MessagingReceipt({
            guid: keccak256(abi.encode(params, block.number)),
            nonce: 1,
            fee: MessagingFee({nativeFee: msg.value, lzTokenFee: 0})
        });
    }
}

contract CounterTriggerTest is Test {
    using OptionsBuilder for bytes;

    MockEndpoint internal endpoint;
    CounterTrigger internal trigger;
    address internal owner = address(0xA11CE);

    uint32 internal constant DST_EID = 40500;
    bytes32 internal constant SN_PEER =
        0x02f49e656ef664f11ec0f57c538a59413b187d42ee934f3f8f1899500d621ba1;

    function setUp() public {
        endpoint = new MockEndpoint();
        trigger = new CounterTrigger(address(endpoint), owner);
        vm.prank(owner);
        trigger.setPeer(DST_EID, SN_PEER);
    }
}
```

- [ ] **Step 2: Run, confirm baseline**

Run: `cd eth_sender && forge build && forge test --match-contract CounterTriggerTest -v`
Expected: build green, 0 tests run (no `test_*` functions yet).

- [ ] **Step 3: Commit**

```bash
git add eth_sender/test/CounterTrigger.t.sol
git commit -m "test(eth): scaffold CounterTrigger forge tests"
```

---

### Task B2: TDD `defaultAbaOptions`

**Files:**
- Modify: `eth_sender/src/CounterTrigger.sol`
- Modify: `eth_sender/test/CounterTrigger.t.sol`

- [ ] **Step 1: Add failing test**

Append to `CounterTriggerTest`:

```solidity
function test_defaultAbaOptions_uses_1m_executor_gas() public view {
    bytes memory expected =
        OptionsBuilder.newOptions().addExecutorLzReceiveOption(1_000_000, 0);
    bytes memory got = trigger.defaultAbaOptions();
    assertEq(got, expected);
}
```

- [ ] **Step 2: Run, confirm failure**

Run: `cd eth_sender && forge test --match-test test_defaultAbaOptions_uses_1m_executor_gas`
Expected: compile error (`defaultAbaOptions` not defined).

- [ ] **Step 3: Add `defaultAbaOptions` to the contract**

Append to `CounterTrigger.sol`:

```solidity
function defaultAbaOptions() external pure returns (bytes memory) {
    return OptionsBuilder.newOptions().addExecutorLzReceiveOption(1_000_000, 0);
}
```

- [ ] **Step 4: Run, confirm pass**

Run: `cd eth_sender && forge test --match-test test_defaultAbaOptions_uses_1m_executor_gas`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add eth_sender/src/CounterTrigger.sol eth_sender/test/CounterTrigger.t.sol
git commit -m "feat(eth): defaultAbaOptions returns 1M-gas type-3 options"
```

---

### Task B3: TDD `triggerAbaIncrement` — payload shape

**Files:**
- Modify: `eth_sender/src/CounterTrigger.sol`
- Modify: `eth_sender/test/CounterTrigger.t.sol`

- [ ] **Step 1: Add failing test**

Append to `CounterTriggerTest`:

```solidity
function test_triggerAbaIncrement_encodes_17_byte_payload() public {
    uint64 bySn = 5;
    uint64 byEth = 3;
    bytes memory options = trigger.defaultAbaOptions();
    MessagingFee memory fee = trigger.quoteAbaIncrement(DST_EID, bySn, byEth, options);
    vm.deal(address(this), fee.nativeFee);
    trigger.triggerAbaIncrement{value: fee.nativeFee}(DST_EID, bySn, byEth, options);
    (uint32 dstEid, bytes32 receiver, bytes memory message, , ) = endpoint.lastSendParams();
    assertEq(dstEid, DST_EID);
    assertEq(receiver, SN_PEER);
    assertEq(message.length, 17);
    assertEq(uint8(message[0]), 0x01); // ABA_TAG

    // by_sn: bytes 1..8 BE
    uint64 decodedSn = 0;
    for (uint256 i = 1; i <= 8; i++) decodedSn = (decodedSn << 8) | uint64(uint8(message[i]));
    assertEq(decodedSn, bySn);

    // by_eth: bytes 9..16 BE
    uint64 decodedEth = 0;
    for (uint256 i = 9; i <= 16; i++) decodedEth = (decodedEth << 8) | uint64(uint8(message[i]));
    assertEq(decodedEth, byEth);
}
```

- [ ] **Step 2: Run, confirm failure**

Run: `cd eth_sender && forge test --match-test test_triggerAbaIncrement_encodes_17_byte_payload`
Expected: compile error — `triggerAbaIncrement`, `quoteAbaIncrement` not defined.

- [ ] **Step 3: Add functions + event to CounterTrigger.sol**

Add constants near the existing `SEND` constant:

```solidity
uint16 public constant SEND_ABA = 2;
uint8 public constant ABA_TAG = 0x01;
```

Add the event:

```solidity
event AbaIncrementTriggered(uint32 indexed dstEid, bytes32 guid, uint64 bySn, uint64 byEth);
```

Add the quote function:

```solidity
function quoteAbaIncrement(
    uint32 _dstEid,
    uint64 _bySn,
    uint64 _byEth,
    bytes calldata _options
) external view returns (MessagingFee memory fee) {
    bytes memory payload = abi.encodePacked(ABA_TAG, _bySn, _byEth);
    fee = _quote(_dstEid, payload, combineOptions(_dstEid, SEND_ABA, _options), false);
}
```

Add the trigger function:

```solidity
function triggerAbaIncrement(
    uint32 _dstEid,
    uint64 _bySn,
    uint64 _byEth,
    bytes calldata _options
) external payable returns (MessagingReceipt memory receipt) {
    bytes memory payload = abi.encodePacked(ABA_TAG, _bySn, _byEth);
    receipt = _lzSend(
        _dstEid,
        payload,
        combineOptions(_dstEid, SEND_ABA, _options),
        MessagingFee(msg.value, 0),
        payable(msg.sender)
    );
    emit AbaIncrementTriggered(_dstEid, receipt.guid, _bySn, _byEth);
}
```

- [ ] **Step 4: Run, confirm pass**

Run: `cd eth_sender && forge test --match-test test_triggerAbaIncrement_encodes_17_byte_payload`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add eth_sender/src/CounterTrigger.sol eth_sender/test/CounterTrigger.t.sol
git commit -m "feat(eth): triggerAbaIncrement encodes 17-byte ABA payload"
```

---

### Task B4: TDD `quoteAbaIncrement` returns non-zero fee

**Files:**
- Modify: `eth_sender/test/CounterTrigger.t.sol`

- [ ] **Step 1: Add test**

```solidity
function test_quoteAbaIncrement_returns_nonzero_fee() public view {
    bytes memory options = trigger.defaultAbaOptions();
    MessagingFee memory fee = trigger.quoteAbaIncrement(DST_EID, 5, 3, options);
    assertGt(fee.nativeFee, 0);
    assertEq(fee.lzTokenFee, 0);
}
```

- [ ] **Step 2: Run**

Run: `cd eth_sender && forge test --match-test test_quoteAbaIncrement_returns_nonzero_fee`
Expected: PASS (MockEndpoint already returns 0.0001 ether quote).

- [ ] **Step 3: Commit**

```bash
git add eth_sender/test/CounterTrigger.t.sol
git commit -m "test(eth): quoteAbaIncrement returns nonzero fee"
```

---

### Task B5: Regression — `_lzReceive` still works on plain 32-byte payload

**Files:**
- Modify: `eth_sender/test/CounterTrigger.t.sol`

- [ ] **Step 1: Add regression test**

```solidity
function test_lzReceive_plain_payload_increments_count() public {
    uint64 by = 9;
    bytes memory msgBytes = abi.encode(by);

    // Pretend to be the endpoint and deliver an inbound message.
    Origin memory origin = Origin({srcEid: DST_EID, sender: SN_PEER, nonce: 1});
    bytes32 guid = bytes32(uint256(0xabc));

    vm.prank(address(endpoint));
    trigger.lzReceive(origin, guid, msgBytes, address(0), bytes(""));

    assertEq(trigger.count(), by);
    assertEq(trigger.lastIncrementBy(), by);
    assertEq(trigger.lastSrcEid(), DST_EID);
}
```

- [ ] **Step 2: Run**

Run: `cd eth_sender && forge test --match-test test_lzReceive_plain_payload_increments_count`
Expected: PASS (no contract changes — this guards the existing behavior).

- [ ] **Step 3: Run full forge test suite to confirm nothing regressed**

Run: `cd eth_sender && forge test -v`
Expected: all tests pass (existing StringSender tests + new CounterTrigger tests).

- [ ] **Step 4: Commit**

```bash
git add eth_sender/test/CounterTrigger.t.sol
git commit -m "test(eth): regression — plain payload still increments count"
```

---

### Task B6: Add v3 deploy script

**Files:**
- Create: `eth_sender/script/DeployCounterTriggerV3.s.sol`

- [ ] **Step 1: Create script**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {CounterTrigger} from "../src/CounterTrigger.sol";

contract DeployCounterTriggerV3 is Script {
    function run() external returns (CounterTrigger trigger) {
        address endpoint = vm.envAddress("LZ_ENDPOINT");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);

        vm.startBroadcast(pk);
        trigger = new CounterTrigger(endpoint, owner);
        vm.stopBroadcast();

        console2.log("CounterTrigger v3 deployed at:", address(trigger));
    }
}
```

- [ ] **Step 2: Confirm it compiles**

Run: `cd eth_sender && forge build`
Expected: green.

- [ ] **Step 3: Commit**

```bash
git add eth_sender/script/DeployCounterTriggerV3.s.sol
git commit -m "feat(eth): add DeployCounterTriggerV3 forge script"
```

---

## Stage C — Operational scripts

### Task C1: Add v3 env variables to `.env.example`

**Files:**
- Modify: `.env.example`

- [ ] **Step 1: Append new variables**

Append to `.env.example`:

```
# ---------- Counter v3 (ABA) ----------
# Cairo Counter v3 (Starknet Sepolia)
COUNTER_V3_STARKNET=
# Solidity CounterTrigger v3 (Ethereum Sepolia)
COUNTER_V3_ETH=
# 32-byte zero-padded Cairo address, used by setPeer on the EVM side
COUNTER_V3_STARKNET_PEER_BYTES32=
# Return-leg defaults (used by 14_set_return_options.sh)
RETURN_LEG_GAS=200000
RETURN_LEG_VALUE=0
# Amount of STRK (in wei, i.e. 10^18 = 1 STRK) to pre-fund Counter v3 with
COUNTER_V3_STRK_FUND_AMOUNT=4000000000000000000
```

- [ ] **Step 2: Mirror in your real `.env` so the scripts can find the vars**

(Do not commit `.env`. This is a manual setup step.)

- [ ] **Step 3: Commit**

```bash
git add .env.example
git commit -m "chore: add Counter v3 environment variables"
```

---

### Task C2: Deploy script — `10_deploy_counter_v3_starknet.sh`

**Files:**
- Create: `scripts/10_deploy_counter_v3_starknet.sh`

**Background:** Modeled on `02_deploy_starknet_oapp.sh` but targets the Counter contract and writes to v3-specific env vars.

- [ ] **Step 1: Create the script**

```bash
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
```

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/10_deploy_counter_v3_starknet.sh`

- [ ] **Step 3: Commit**

```bash
git add scripts/10_deploy_counter_v3_starknet.sh
git commit -m "scripts: deploy Counter v3 on Starknet"
```

---

### Task C3: Deploy script — `11_deploy_counter_trigger_v3_eth.sh`

**Files:**
- Create: `scripts/11_deploy_counter_trigger_v3_eth.sh`

- [ ] **Step 1: Create the script**

```bash
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
```

- [ ] **Step 2: Make executable + commit**

```bash
chmod +x scripts/11_deploy_counter_trigger_v3_eth.sh
git add scripts/11_deploy_counter_trigger_v3_eth.sh
git commit -m "scripts: deploy CounterTrigger v3 on Ethereum"
```

---

### Task C4: Wire-peers script — `12_wire_counter_v3_peers.sh`

**Files:**
- Create: `scripts/12_wire_counter_v3_peers.sh`

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
# setPeer on both sides for Counter v3.

set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
PATH="$HOME/.local/bin:$PATH"

: "${COUNTER_V3_ETH:?}"; : "${COUNTER_V3_STARKNET:?}"
: "${COUNTER_V3_STARKNET_PEER_BYTES32:?}"
: "${DST_EID_STARKNET:?}"; : "${DST_EID_ETHEREUM:?}"
: "${PRIVATE_KEY:?}"; : "${SEPOLIA_RPC_URL:?}"

# A. EVM → register Starknet peer
echo ">> EVM setPeer($DST_EID_STARKNET, $COUNTER_V3_STARKNET_PEER_BYTES32)"
cast send "$COUNTER_V3_ETH" \
  "setPeer(uint32,bytes32)" \
  "$DST_EID_STARKNET" \
  "$COUNTER_V3_STARKNET_PEER_BYTES32" \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" 2>&1 | tail -10

# B. Starknet → register EVM peer
EVM_HEX=$(echo "$COUNTER_V3_ETH" | tr 'A-F' 'a-f' | sed 's/^0x//')
PADDED32="0x$(printf '%064s' "$EVM_HEX" | tr ' ' '0')"
echo ">> SN set_peer($DST_EID_ETHEREUM, $PADDED32)"
sncast \
  --accounts-file "$STARKNET_ACCOUNTS_FILE" \
  --account "$STARKNET_ACCOUNT" \
  invoke \
  --url "$STARKNET_RPC_URL" \
  --contract-address "$COUNTER_V3_STARKNET" \
  --function set_peer \
  --arguments "$DST_EID_ETHEREUM, Bytes32 { value: $PADDED32 }" 2>&1 | tail -5

echo "============================================================="
echo "  Counter v3 peers wired both directions."
echo "  Next: ./scripts/13_fund_counter_v3_strk.sh"
echo "============================================================="
```

- [ ] **Step 2: Make executable + commit**

```bash
chmod +x scripts/12_wire_counter_v3_peers.sh
git add scripts/12_wire_counter_v3_peers.sh
git commit -m "scripts: wire Counter v3 peers on both chains"
```

---

### Task C5: Funding script — `13_fund_counter_v3_strk.sh`

**Files:**
- Create: `scripts/13_fund_counter_v3_strk.sh`

- [ ] **Step 1: Create the script**

```bash
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
```

- [ ] **Step 2: Make executable + commit**

```bash
chmod +x scripts/13_fund_counter_v3_strk.sh
git add scripts/13_fund_counter_v3_strk.sh
git commit -m "scripts: fund Counter v3 with STRK"
```

---

### Task C6: Optional helper — `14_set_return_options.sh`

**Files:**
- Create: `scripts/14_set_return_options.sh`

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
# Owner-only: update Counter v3 return options. Args: [GAS] [VALUE].
# Falls back to .env RETURN_LEG_GAS / RETURN_LEG_VALUE if not provided.

set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
PATH="$HOME/.local/bin:$PATH"

: "${COUNTER_V3_STARKNET:?}"
: "${STARKNET_ACCOUNT:?}"; : "${STARKNET_ACCOUNTS_FILE:?}"; : "${STARKNET_RPC_URL:?}"

GAS="${1:-${RETURN_LEG_GAS:-200000}}"
VALUE="${2:-${RETURN_LEG_VALUE:-0}}"

echo ">> set_return_options(gas=$GAS, value=$VALUE)"
sncast \
  --accounts-file "$STARKNET_ACCOUNTS_FILE" \
  --account "$STARKNET_ACCOUNT" \
  invoke \
  --url "$STARKNET_RPC_URL" \
  --contract-address "$COUNTER_V3_STARKNET" \
  --function set_return_options \
  --arguments "${GAS}_u128, ${VALUE}_u128" 2>&1 | tail -5
echo "done."
```

- [ ] **Step 2: Make executable + commit**

```bash
chmod +x scripts/14_set_return_options.sh
git add scripts/14_set_return_options.sh
git commit -m "scripts: helper to update Counter v3 return options"
```

---

### Task C7: End-to-end smoke-test script — `15_aba_smoke_test.sh`

**Files:**
- Create: `scripts/15_aba_smoke_test.sh`

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
# End-to-end ABA smoke test:
#   - Snapshot both counters
#   - Call triggerAbaIncrement(40500, 5, 3) on Ethereum
#   - Poll Starknet count until it goes up by 5
#   - Poll Ethereum count until it goes up by 3

set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
PATH="$HOME/.local/bin:$PATH"

: "${COUNTER_V3_ETH:?}"; : "${COUNTER_V3_STARKNET:?}"
: "${DST_EID_STARKNET:?}"; : "${PRIVATE_KEY:?}"; : "${SEPOLIA_RPC_URL:?}"
: "${STARKNET_ACCOUNT:?}"; : "${STARKNET_ACCOUNTS_FILE:?}"; : "${STARKNET_RPC_URL:?}"

BY_SN="${1:-5}"
BY_ETH="${2:-3}"

read_eth_count() {
  cast call --rpc-url "$SEPOLIA_RPC_URL" "$COUNTER_V3_ETH" "count()(uint64)" \
    | awk '{print $1}'
}
read_sn_count() {
  sncast --accounts-file "$STARKNET_ACCOUNTS_FILE" --account "$STARKNET_ACCOUNT" \
    call --url "$STARKNET_RPC_URL" \
    --contract-address "$COUNTER_V3_STARKNET" --function count \
    2>&1 | grep -oE '0x[a-fA-F0-9]+' | tail -1 | python3 -c "import sys; print(int(sys.stdin.read().strip(), 16))"
}

PRE_ETH=$(read_eth_count)
PRE_SN=$(read_sn_count)
echo ">> Pre: eth=$PRE_ETH, sn=$PRE_SN"

OPTS=$(cast call --rpc-url "$SEPOLIA_RPC_URL" "$COUNTER_V3_ETH" "defaultAbaOptions()(bytes)")
echo ">> opts=$OPTS"

FEE=$(cast call --rpc-url "$SEPOLIA_RPC_URL" "$COUNTER_V3_ETH" \
  "quoteAbaIncrement(uint32,uint64,uint64,bytes)((uint256,uint256))" \
  "$DST_EID_STARKNET" "$BY_SN" "$BY_ETH" "$OPTS")
# FEE looks like "(<native>, <lzToken>)"
NATIVE_FEE=$(echo "$FEE" | grep -oE '[0-9]+' | head -1)
echo ">> native_fee=$NATIVE_FEE wei"

echo ">> Sending triggerAbaIncrement($DST_EID_STARKNET, $BY_SN, $BY_ETH)..."
TX=$(cast send --rpc-url "$SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY" \
  --value "$NATIVE_FEE" \
  "$COUNTER_V3_ETH" \
  "triggerAbaIncrement(uint32,uint64,uint64,bytes)" \
  "$DST_EID_STARKNET" "$BY_SN" "$BY_ETH" "$OPTS" 2>&1 | tee /tmp/aba_send.log | grep transactionHash | awk '{print $2}')
echo ">> ETH tx: $TX"
echo ">> LZ Scan: https://testnet.layerzeroscan.com/tx/$TX"

# Poll SN for first leg
WANT_SN=$((PRE_SN + BY_SN))
echo ">> Polling SN every 10s for count >= $WANT_SN (up to 5 min)..."
for i in $(seq 1 30); do
  sleep 10
  CUR=$(read_sn_count || echo "$PRE_SN")
  echo "[$((i*10))s] sn=$CUR"
  if [[ "$CUR" -ge "$WANT_SN" ]]; then
    echo ">> SN leg confirmed."
    break
  fi
done

# Poll ETH for second leg
WANT_ETH=$((PRE_ETH + BY_ETH))
echo ">> Polling ETH every 15s for count >= $WANT_ETH (up to 8 min)..."
for i in $(seq 1 32); do
  sleep 15
  CUR=$(read_eth_count || echo "$PRE_ETH")
  echo "[$((i*15))s] eth=$CUR"
  if [[ "$CUR" -ge "$WANT_ETH" ]]; then
    echo ">> ETH leg confirmed. ABA complete."
    exit 0
  fi
done

echo "Timed out waiting for ETH leg. Check LZ Scan link above."
exit 1
```

- [ ] **Step 2: Make executable + commit**

```bash
chmod +x scripts/15_aba_smoke_test.sh
git add scripts/15_aba_smoke_test.sh
git commit -m "scripts: ABA end-to-end smoke test"
```

---

## Stage D — Sepolia deployment + smoke test

### Task D1: Deploy + wire + fund on real testnet

**Files:** none (operational only)

- [ ] **Step 1: Pre-flight checks**

```bash
test -s .env && grep -q '^PRIVATE_KEY=0x' .env && echo "env ok" || (echo "fix .env"; exit 1)
cd starknet_oapp && scarb build && cd ..
cd eth_sender && forge build && cd ..
```

- [ ] **Step 2: Deploy Cairo Counter v3**

```bash
./scripts/10_deploy_counter_v3_starknet.sh
```

Expected: outputs `COUNTER_V3_STARKNET=0x...`, writes to `.env`.

- [ ] **Step 3: Deploy EVM CounterTrigger v3**

```bash
./scripts/11_deploy_counter_trigger_v3_eth.sh
```

Expected: outputs `COUNTER_V3_ETH=0x...`, writes to `.env`.

- [ ] **Step 4: Wire peers**

```bash
./scripts/12_wire_counter_v3_peers.sh
```

- [ ] **Step 5: Fund Counter v3 with 4 STRK**

```bash
./scripts/13_fund_counter_v3_strk.sh
```

Expected: STRK balance prints back as `0x3782dace9d900000` (4 STRK = 4 × 10¹⁸ wei).

- [ ] **Step 6: Smoke test**

```bash
./scripts/15_aba_smoke_test.sh 5 3
```

Expected (within ~5 minutes):
- SN count increases by 5
- ETH count increases by 3
- Script exits 0

If SN leg confirms but ETH leg times out, the return-leg gas is likely too low. Increase via:

```bash
./scripts/14_set_return_options.sh 400000 0
```

and re-run the smoke test.

- [ ] **Step 7: Commit any resulting .env.example tuning (e.g., RETURN_LEG_GAS bump)**

```bash
git add .env.example
git commit -m "tune: bump RETURN_LEG_GAS based on testnet feedback" || echo "nothing to commit"
```

---

## Stage E — Frontend

### Task E1: Add v3 config keys

**Files:**
- Modify: `frontend/config.example.js`
- Modify: `frontend/config.js`

- [ ] **Step 1: Update `config.example.js`**

Append to the `CONFIG` object (replace the closing `};` with):

```javascript
  // Counter v3 (ABA) — set after running scripts/10..12.
  COUNTER_V3_ETH:    "",
  COUNTER_V3_SN:     "",
};
```

- [ ] **Step 2: Update real `config.js`** with the addresses from `.env` (substituting `COUNTER_V3_ETH` and `COUNTER_V3_STARKNET`):

```javascript
  COUNTER_V3_ETH:    "0x...",   // from .env COUNTER_V3_ETH
  COUNTER_V3_SN:     "0x...",   // from .env COUNTER_V3_STARKNET
```

- [ ] **Step 3: Commit**

```bash
git add frontend/config.example.js
git commit -m "frontend: add v3 config keys"
```

`config.js` is gitignored — do not commit it.

---

### Task E2: Add third zone to `index.html`

**Files:**
- Modify: `frontend/index.html`

- [ ] **Step 1: Read the current `frontend/index.html`** to find where the second `</article>` of the dual lanes closes and the matching `</section>` follows.

- [ ] **Step 2: Insert a new `<section class="aba-zone">` after `</section>` of the dual lanes block**

```html
<section class="aba-zone">
  <header class="aba-head">
    <p class="section-num">03</p>
    <h2 class="section-title">
      One click. <em>Both</em> counters bounce.
    </h2>
    <p class="aba-desc">
      Click <strong>BOUNCE</strong>. The message goes to Starknet, increments its
      counter, and Starknet immediately sends a return message paying its own
      STRK fee from a pre-funded balance — incrementing Ethereum's counter too.
    </p>
  </header>

  <div class="aba-controls">
    <label class="aba-input">
      <span class="aba-input-label">Starknet&nbsp;+</span>
      <input id="aba-by-sn" type="number" min="1" max="999" value="5" />
    </label>
    <label class="aba-input">
      <span class="aba-input-label">Ethereum&nbsp;+</span>
      <input id="aba-by-eth" type="number" min="1" max="999" value="3" />
    </label>
  </div>

  <div class="aba-button-wrap">
    <button class="aba-button" id="aba-press-btn" type="button" disabled>
      <span class="aba-button-text">BOUNCE</span>
      <span class="aba-button-sub" id="aba-bb-sub">arming…</span>
    </button>
  </div>

  <div class="aba-status">
    <p class="counter-label">Status</p>
    <p class="mono" id="aba-status-text">idle</p>
    <p class="mono small" id="aba-tx-link"></p>
  </div>
</section>
```

- [ ] **Step 3: Open the page locally**

```bash
cd frontend && bash serve.sh &
sleep 2
open http://localhost:8765
```

Expected: third zone visible below the two existing lanes. Looks unstyled — that's the next task.

- [ ] **Step 4: Commit**

```bash
git add frontend/index.html
git commit -m "frontend: add ABA zone markup"
```

---

### Task E3: Style the third zone

**Files:**
- Modify: `frontend/style.css`

- [ ] **Step 1: Append new styles**

```css
/* -------------------- ABA zone -------------------- */

.aba-zone {
  margin-top: 4rem;
  padding: 3rem 2rem;
  border-top: 1px solid var(--rule, #2a2a2a);
  border-bottom: 1px solid var(--rule, #2a2a2a);
  display: grid;
  grid-template-columns: 1fr;
  gap: 2rem;
  background: linear-gradient(
    180deg,
    rgba(255, 74, 28, 0.04) 0%,
    transparent 100%
  );
}

.aba-head .section-num {
  color: var(--accent, #FF4A1C);
  font-family: "JetBrains Mono", monospace;
  font-size: 0.85rem;
  letter-spacing: 0.08em;
}

.aba-head .section-title {
  font-family: "Fraunces", serif;
  font-style: italic;
  font-weight: 500;
  font-size: clamp(1.6rem, 4vw, 2.6rem);
  line-height: 1.05;
  margin: 0.5rem 0 1rem;
}

.aba-head .aba-desc {
  font-family: "Schibsted Grotesk", sans-serif;
  font-size: 0.95rem;
  max-width: 60ch;
  color: rgba(245, 245, 245, 0.75);
  line-height: 1.5;
}

.aba-controls {
  display: flex;
  gap: 1.5rem;
  flex-wrap: wrap;
}

.aba-input {
  display: flex;
  align-items: baseline;
  gap: 0.6rem;
  font-family: "JetBrains Mono", monospace;
}

.aba-input-label { font-size: 0.85rem; letter-spacing: 0.06em; opacity: 0.7; }

.aba-input input {
  width: 6rem;
  padding: 0.4rem 0.6rem;
  background: transparent;
  border: 1px solid var(--rule, #2a2a2a);
  border-bottom: 2px solid var(--accent, #FF4A1C);
  color: inherit;
  font-family: inherit;
  font-size: 1.2rem;
  text-align: center;
}

.aba-input input:focus {
  outline: none;
  border-color: var(--accent, #FF4A1C);
}

.aba-button-wrap {
  display: flex;
  justify-content: center;
  margin: 1rem 0;
}

.aba-button {
  position: relative;
  width: min(420px, 80vw);
  padding: 1.4rem 2rem;
  background: var(--accent, #FF4A1C);
  color: #fff;
  border: none;
  font-family: "Schibsted Grotesk", sans-serif;
  font-weight: 800;
  font-size: 1.4rem;
  letter-spacing: 0.16em;
  cursor: pointer;
  transition: transform 0.08s ease, opacity 0.15s ease;
}

.aba-button:hover:not(:disabled) { transform: translateY(-1px); }
.aba-button:active:not(:disabled) { transform: translateY(1px); }
.aba-button:disabled { opacity: 0.4; cursor: not-allowed; }

.aba-button-text { display: block; }
.aba-button-sub {
  display: block;
  font-size: 0.8rem;
  letter-spacing: 0.12em;
  font-weight: 500;
  margin-top: 0.4rem;
  opacity: 0.85;
}

.aba-status {
  text-align: center;
  font-family: "JetBrains Mono", monospace;
  font-size: 0.9rem;
}

.aba-status .small { font-size: 0.75rem; opacity: 0.7; }
```

- [ ] **Step 2: Hot-reload the page**

Browser refresh on `http://localhost:8765`. Expected: third zone is styled — orange BOUNCE button, two number inputs, status row.

- [ ] **Step 3: Commit**

```bash
git add frontend/style.css
git commit -m "frontend: style ABA zone consistent with brutalist editorial"
```

---

### Task E4: Implement the ABA flow in `app.js`

**Files:**
- Modify: `frontend/app.js`

**Background:** Add a `pressAba()` flow alongside the existing single-hop press handlers. Reuse the existing burner wallet, RPC clients, and counter-reading helpers. The new contract address is `CONFIG.COUNTER_V3_ETH` for the EVM side and `CONFIG.COUNTER_V3_SN` for the SN side.

- [ ] **Step 1: Read the current `frontend/app.js`** to understand how the existing press buttons are wired (look for `eth-press-btn`, `sn-press-btn` handlers).

- [ ] **Step 2: Add the ABA ABI fragment near the existing CounterTrigger ABI**

```javascript
const COUNTER_V3_ABI = [
  "function defaultAbaOptions() view returns (bytes)",
  "function quoteAbaIncrement(uint32 dstEid, uint64 bySn, uint64 byEth, bytes options) view returns ((uint256 nativeFee, uint256 lzTokenFee))",
  "function triggerAbaIncrement(uint32 dstEid, uint64 bySn, uint64 byEth, bytes options) payable returns (tuple)",
  "function count() view returns (uint64)",
];

const COUNTER_SN_ABI_VIEW_COUNT = [
  { name: "count", type: "function", inputs: [], outputs: [{ type: "core::integer::u64" }], state_mutability: "view" },
];
```

- [ ] **Step 3: Add the `pressAba` handler**

```javascript
async function readEthCountV3() {
  const c = new ethers.Contract(CONFIG.COUNTER_V3_ETH, COUNTER_V3_ABI, ethProvider);
  return Number(await c.count());
}

async function readSnCountV3() {
  const res = await snProvider.callContract({
    contractAddress: CONFIG.COUNTER_V3_SN,
    entrypoint: "count",
  });
  // single-felt u64 response
  return Number(BigInt(res[0]));
}

async function pollUntil(fn, timeoutMs, intervalMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await fn()) return true;
    await new Promise(r => setTimeout(r, intervalMs));
  }
  return false;
}

function setAbaStatus(text) {
  document.getElementById("aba-status-text").textContent = text;
}
function setAbaTxLink(tx) {
  const el = document.getElementById("aba-tx-link");
  if (!tx) { el.innerHTML = ""; return; }
  el.innerHTML = `<a href="https://testnet.layerzeroscan.com/tx/${tx}" target="_blank">${tx.slice(0,10)}…${tx.slice(-8)}</a>`;
}

async function pressAba() {
  const btn = document.getElementById("aba-press-btn");
  btn.disabled = true;
  try {
    const bySn = BigInt(document.getElementById("aba-by-sn").value || "1");
    const byEth = BigInt(document.getElementById("aba-by-eth").value || "1");

    setAbaStatus("quoting…");
    const trigger = new ethers.Contract(CONFIG.COUNTER_V3_ETH, COUNTER_V3_ABI, ethSigner);
    const options = await trigger.defaultAbaOptions();
    const fee = await trigger.quoteAbaIncrement(CONFIG.DST_EID_STARKNET, bySn, byEth, options);

    const preSn = await readSnCountV3();
    const preEth = await readEthCountV3();
    setAbaStatus(`sending… (fee ${ethers.formatEther(fee.nativeFee)} ETH)`);
    const tx = await trigger.triggerAbaIncrement(
      CONFIG.DST_EID_STARKNET, bySn, byEth, options, { value: fee.nativeFee }
    );
    setAbaTxLink(tx.hash);
    await tx.wait();

    setAbaStatus(`waiting for Starknet (~60s)…`);
    const snOk = await pollUntil(async () => (await readSnCountV3()) >= preSn + Number(bySn), 5 * 60_000, 8_000);
    if (!snOk) { setAbaStatus("timed out waiting for Starknet"); return; }

    setAbaStatus(`Starknet confirmed +${bySn}, waiting for Ethereum (~3.5min)…`);
    const ethOk = await pollUntil(async () => (await readEthCountV3()) >= preEth + Number(byEth), 8 * 60_000, 12_000);
    if (!ethOk) { setAbaStatus("timed out waiting for Ethereum return"); return; }

    setAbaStatus(`done — SN +${bySn}, ETH +${byEth}`);
  } catch (err) {
    console.error(err);
    setAbaStatus(`error: ${err.shortMessage || err.message}`);
  } finally {
    btn.disabled = false;
  }
}
```

- [ ] **Step 4: Wire up the button + initial enable**

In the section of `app.js` where existing buttons are enabled after the burner is ready (look for the line that does `document.getElementById('eth-press-btn').disabled = false;` or similar), append:

```javascript
const abaBtn = document.getElementById("aba-press-btn");
abaBtn.addEventListener("click", pressAba);
abaBtn.disabled = false;
document.getElementById("aba-bb-sub").textContent = "ready";
setAbaStatus("idle");
```

- [ ] **Step 5: Test in headless browser via /browse**

Run: open `http://localhost:8765` and click BOUNCE. Expected status transitions: `quoting… → sending… → waiting for Starknet → Starknet confirmed → waiting for Ethereum → done`. The two existing buttons should still work.

If `readSnCountV3` throws on the felt-parse line, inspect what `callContract` returns and adjust — Alchemy returns `{ result: ["0x..."] }` in some versions; in others, `result` is a flat array. The existing `readSnCount` in `app.js` (for v2) is the reference.

- [ ] **Step 6: Commit**

```bash
git add frontend/app.js
git commit -m "frontend: implement pressAba — one-click bounce ETH→SN→ETH"
```

---

### Task E5: Local end-to-end test

- [ ] **Step 1: Ensure dev server is running**

```bash
cd frontend && bash serve.sh
```

- [ ] **Step 2: Open the page and click BOUNCE with default values (5/3)**

Watch the status messages. Confirm:
- Status transitions through all 5 phases
- LZ Scan link appears and is clickable
- SN count digit ticker updates (existing behavior)
- ETH count digit ticker updates
- No console errors

- [ ] **Step 3: Note any tuning needed**

If the SN leg's executor needs more gas (the `_lz_receive` does more work than v2 because it also calls `_lz_send`), bump the EVM-side `defaultAbaOptions` gas (currently 1,000,000). Update both the contract and the deployed instance is **not** required — `defaultAbaOptions` is a pure function whose return value is composed at call time. But the `combineOptions` system applies enforced options on top. If enforced options were set, change those. For the demo, hardcoded 1M is the source of truth.

If the return leg fails (SN→ETH never lands), increase `return_gas` via `scripts/14_set_return_options.sh`.

---

## Stage F — Docs + production deploy

### Task F1: Update `STATUS.md`

**Files:**
- Modify: `STATUS.md`

- [ ] **Step 1: Update the contracts table**

Replace the current "Counter" row in the `## What is live right now` table with:

```markdown
| **Counter v3** (ABA — current production) | `0x...COUNTER_V3_ETH...` | `0x...COUNTER_V3_STARKNET...` |
| Cairo Counter v3 class hash | — | `0x...` |
| **Counter v2** (single-hop, deprecated) | `0x07aF803CD6B432A763582bC8890c16CE24669123` | `0x02f49e656ef664f11ec0f57c538a59413b187d42ee934f3f8f1899500d621ba1` |
```

(Use the actual addresses from `.env`.)

- [ ] **Step 2: Update the Phase list**

Add at the bottom:

```markdown
✅ Phase 8 — ABA composability (one-click ETH→SN→ETH bounce)
```

- [ ] **Step 3: Add ABA tx hashes to the "Verified live on Sepolia" table**

Append a row using the actual tx hash from the smoke test:

```markdown
| ETH → SN → ETH (ABA, +5/+3) | [`0x...`](https://testnet.layerzeroscan.com/tx/0x...) | ~4 min |
```

- [ ] **Step 4: Commit**

```bash
git add STATUS.md
git commit -m "docs: update STATUS.md with Counter v3 + ABA flow"
```

---

### Task F2: Add Session 12 to `PROGRESS.md`

**Files:**
- Modify: `PROGRESS.md`

- [ ] **Step 1: Append a new session**

After the existing "Session 11 — Vercel deployment" section, before "## Things considered but not built", insert:

```markdown
## Session 12 — ABA composability (one-click bounce)

User: "one click on ethereum side which will then send a message to starknet to increase the counter on starknet and along with that the message would also have another functionality which now will send a message back to ethereum to increase the counter as well."

### Key discovery

`OAppCoreComponent::_pay_native` (in protocol-starknet-v2) has a `caller != contract_address` guard around the allowance check, and `_pay_in_token` has the same guard around `transfer_from`. When the OApp passes its own address as `caller`, both are skipped — the endpoint just approves itself to spend the OApp's own STRK and pulls the fee. **No protocol fork, no self-approval gymnastics.** Unlocks the entire ABA flow with one line of intent.

### Wire format

Two payload shapes coexist on the ETH→SN channel:

- Plain (32 bytes): `abi.encode(uint64)` — unchanged
- ABA (17 bytes): `0x01 ‖ by_sn (8B BE) ‖ by_eth (8B BE)`

Cairo `_lz_receive` dispatches on `message.len()`. Return leg sends a plain 32-byte payload back, so the EVM `_lzReceive` stays unchanged. Loop prevention is structural: ABA logic only lives on Cairo; the return message can't trigger another bounce.

### Contracts

- Counter v3 (Cairo): `0x...` — adds ABA branch in `_lz_receive`, `return_gas`/`return_value` storage, `set_return_options`, `withdraw_strk`, `AbaBounceSent` event.
- CounterTrigger v3 (EVM): `0x...` — adds `triggerAbaIncrement`, `quoteAbaIncrement`, `defaultAbaOptions`, `AbaIncrementTriggered`.
- Counter v3 pre-funded with 4 STRK from the burner; pays return-leg fees from its own balance.
- Counter v2 marked deprecated in STATUS.md.

### Tests

- snforge: 8 tests covering owner gates, plain-path regression, bad-length revert, bad-tag revert, ABA increment, ABA bounce dispatch to mock endpoint.
- forge: 4 new tests on CounterTrigger v3 — payload encoding, quote returns nonzero, defaultAbaOptions shape, plain-path `_lzReceive` regression.

### Frontend

Third full-width zone below the existing two lanes. Two number inputs (`by_sn`, `by_eth`), single BOUNCE button, status line tracking 5 phases.

### Verified on Sepolia

`triggerAbaIncrement(40500, 5, 3)`: ETH tx `0x...`, SN +5 at ~60s, ETH +3 at ~3.5min.
```

- [ ] **Step 2: Commit**

```bash
git add PROGRESS.md
git commit -m "docs: add Session 12 — ABA composability"
```

---

### Task F3: Vercel deploy

**Files:** none (operational)

- [ ] **Step 1: Make sure `frontend/config.js` has v3 addresses set**

```bash
grep COUNTER_V3 frontend/config.js
```

Expected: both keys have real addresses, not `""`.

- [ ] **Step 2: Deploy to Vercel**

```bash
cd frontend && vercel --prod --yes 2>&1 | tee /tmp/vercel_aba.log
```

Expected: deployed URL `https://crosschain-strk20.vercel.app` (or the new immutable preview if Vercel routes differently).

- [ ] **Step 3: Final E2E test against production URL**

Open `https://crosschain-strk20.vercel.app` in a real browser. Click BOUNCE with 5/3. Watch the status transitions complete in ~5 min.

- [ ] **Step 4: Push everything to GitHub**

```bash
git push origin main
```

---

## Self-review

- **Spec §3 (self-pay):** Task A6 (`_lz_send(self_addr, ...)`) — covered.
- **Spec §5 (wire format):** Task A4 dispatch + Task A5 ABA increment — covered.
- **Spec §6.1 (Cairo changes):** Tasks A2, A3, A4, A5, A6 — all covered.
- **Spec §6.2 (Solidity changes):** Tasks B2, B3, B4, B5 — covered.
- **Spec §7 (frontend):** Tasks E1, E2, E3, E4 — covered.
- **Spec §8 (scripts):** Tasks C2–C7 — covered.
- **Spec §9.1 (forge tests):** Tasks B3, B4, B5 — covered.
- **Spec §9.2 (snforge tests):** Tasks A2, A3, A4, A5, A6 cover plain regression, length revert, tag revert, ABA increment, owner gates, send dispatch. Missing: an explicit test that `lz_receive` rejects callers that aren't the endpoint — this is inherited from `OAppCoreComponent::_assert_only_endpoint` and proven by the existing protocol-starknet-v2 test suite; not duplicating here.
- **Spec §9.3 (Sepolia E2E):** Task D1, step 6 — covered.
- **Spec §10 out-of-scope items:** Honored (no per-tx tunable return options in payload, no compose, no slippage headroom, etc.).
- **Spec §11 risks:** Task A6's "Likely failure modes" notes address the `_lz_send` from self risk. Task D1 step 6 addresses the gas-too-low risk with a concrete bump path.
- **Spec §12 definition of done:** All 9 criteria covered by tasks D1, E5, F1, F2, F3.

Type/name consistency checked: `return_gas`, `return_value`, `set_return_options`, `AbaBounceSent`, `triggerAbaIncrement`, `quoteAbaIncrement`, `defaultAbaOptions`, `SEND_ABA`, `ABA_TAG`, `COUNTER_V3_ETH`, `COUNTER_V3_SN`, `COUNTER_V3_STARKNET`, `COUNTER_V3_STARKNET_PEER_BYTES32` all spelled consistently across tasks.

No placeholders, no TODOs, no "TBD" left in the plan body.

---

## Execution handoff

Plan complete and saved to `cross_chain/docs/superpowers/plans/2026-05-13-aba-counter-implementation.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints for review.

Which approach?
