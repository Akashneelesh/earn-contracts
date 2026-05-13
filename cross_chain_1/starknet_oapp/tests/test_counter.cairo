use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address, start_mock_call,
    stop_cheat_caller_address,
};
use starknet::ContractAddress;
use starknet_oapp::counter::Counter::{ICounterDispatcher, ICounterDispatcherTrait};

const OWNER: felt252 = 0xAAAA;
const NOT_OWNER: felt252 = 0xBBBB;
const FAKE_STRK: felt252 = 0xDDDD;

fn deploy_counter() -> (ContractAddress, ICounterDispatcher) {
    let owner: ContractAddress = OWNER.try_into().unwrap();
    let strk: ContractAddress = FAKE_STRK.try_into().unwrap();
    let mock_ep_class = declare("MockEndpoint").unwrap().contract_class();
    let (ep_addr, _) = mock_ep_class.deploy(@array![]).unwrap();
    let counter_class = declare("Counter").unwrap().contract_class();
    let (addr, _) = counter_class
        .deploy(@array![ep_addr.into(), owner.into(), strk.into()])
        .unwrap();
    (addr, ICounterDispatcher { contract_address: addr })
}

#[test]
fn smoke() {
    // Tautology — proves the scaffold compiles and snforge can run.
    assert!(1 + 1 == 2);
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

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn non_owner_cannot_withdraw_strk() {
    let (addr, counter) = deploy_counter();
    let not_owner: ContractAddress = NOT_OWNER.try_into().unwrap();
    let to: ContractAddress = 0xEEEE.try_into().unwrap();
    start_cheat_caller_address(addr, not_owner);
    counter.withdraw_strk(to, 1_u256);
}

const SRC_EID: u32 = 40161;
// Fake sender address used as the peer — must be registered via set_peer.
const FAKE_SENDER: u256 = 0x1;

#[starknet::interface]
trait ILzReceiver<T> {
    fn lz_receive(
        ref self: T,
        origin: layerzero::Origin,
        guid: lz_utils::bytes::Bytes32,
        message: ByteArray,
        executor: starknet::ContractAddress,
        extra_data: ByteArray,
        value: u256,
    );
}

#[starknet::interface]
trait IOAppCore<T> {
    fn set_peer(ref self: T, eid: u32, peer: lz_utils::bytes::Bytes32);
}

// Pretend to be the endpoint and deliver a payload to _lz_receive directly.
// OAppCoreComponent::_assert_only_endpoint reads the endpoint address from
// storage; we set it via the constructor.
// Before calling lz_receive, register FAKE_SENDER as the peer for SRC_EID
// (set_peer is owner-gated, so cheat caller to owner first).
fn deliver(addr: ContractAddress, endpoint: ContractAddress, payload: ByteArray) {
    let sender = lz_utils::bytes::Bytes32 { value: FAKE_SENDER.into() };
    let origin = layerzero::Origin { src_eid: SRC_EID, sender, nonce: 1 };
    let guid = lz_utils::bytes::Bytes32 { value: 0xabc.into() };
    let executor: ContractAddress = 0xFFFF.try_into().unwrap();
    let extra: ByteArray = Default::default();

    // Register peer so lz_receive's peer check passes.
    let owner: ContractAddress = OWNER.try_into().unwrap();
    start_cheat_caller_address(addr, owner);
    IOAppCoreDispatcher { contract_address: addr }.set_peer(SRC_EID, sender);
    stop_cheat_caller_address(addr);

    // Deliver as the endpoint.
    start_cheat_caller_address(addr, endpoint);
    ILzReceiverDispatcher { contract_address: addr }
        .lz_receive(origin, guid, payload, executor, extra, 0_u256);
    stop_cheat_caller_address(addr);
}

fn encode_plain(by: u64) -> ByteArray {
    // 24 zero bytes + 8 big-endian bytes
    let mut out: ByteArray = Default::default();
    let mut i = 0_u32;
    while i < 24 {
        out.append_byte(0);
        i += 1;
    }
    let mut v = by;
    let mut tmp: Array<u8> = ArrayTrait::new();
    let mut j = 0_u32;
    while j < 8 {
        tmp.append((v % 256).try_into().unwrap());
        v = v / 256;
        j += 1;
    }
    let mut k = 8_u32;
    while k > 0 {
        k -= 1;
        out.append_byte(*tmp.at(k));
    }
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
    while i < 20 {
        payload.append_byte(0xff);
        i += 1;
    } // 20 bytes ≠ 17 or 32
    deliver(addr, ep, payload);
}

fn encode_aba(by_sn: u64, by_eth: u64) -> ByteArray {
    let mut out: ByteArray = Default::default();
    out.append_byte(0x01);
    // by_sn big-endian
    let mut v = by_sn;
    let mut tmp: Array<u8> = ArrayTrait::new();
    let mut j = 0_u32;
    while j < 8 {
        tmp.append((v % 256).try_into().unwrap());
        v = v / 256;
        j += 1;
    }
    let mut k = 8_u32;
    while k > 0 {
        k -= 1;
        out.append_byte(*tmp.at(k));
    }
    // by_eth big-endian
    let mut v2 = by_eth;
    let mut tmp2: Array<u8> = ArrayTrait::new();
    let mut j2 = 0_u32;
    while j2 < 8 {
        tmp2.append((v2 % 256).try_into().unwrap());
        v2 = v2 / 256;
        j2 += 1;
    }
    let mut k2 = 8_u32;
    while k2 > 0 {
        k2 -= 1;
        out.append_byte(*tmp2.at(k2));
    }
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

    // ABA branch now bounces a return message; mock fee=0 and FAKE_STRK calls
    // so the self-pay path doesn't revert on the non-deployed token address.
    IMockEndpointReaderDispatcher { contract_address: ep }.set_quoted_fee(0_u256);
    start_mock_call(strk, selector!("balance_of"), array![0_felt252, 0_felt252]);
    start_mock_call(strk, selector!("approve"), array![1_felt252]);

    deliver(addr, ep, encode_aba(5, 3));

    let counter = ICounterDispatcher { contract_address: addr };
    assert!(counter.count() == 5);
    assert!(counter.last_increment_by() == 5);
    assert!(counter.last_src_eid() == SRC_EID);
}

#[starknet::interface]
trait IMockEndpointReader<T> {
    fn last_send_dst_eid(self: @T) -> u32;
    fn last_send_message(self: @T) -> ByteArray;
    fn send_call_count(self: @T) -> u32;
    fn set_quoted_fee(ref self: T, native_fee: u256);
}

#[test]
fn aba_payload_triggers_return_lz_send_to_origin_eid() {
    let mock = declare("MockEndpoint").unwrap().contract_class();
    let (ep, _) = mock.deploy(@array![]).unwrap();
    let cls = declare("Counter").unwrap().contract_class();
    let owner: ContractAddress = OWNER.try_into().unwrap();
    let strk: ContractAddress = FAKE_STRK.try_into().unwrap();
    let (addr, _) = cls.deploy(@array![ep.into(), owner.into(), strk.into()]).unwrap();

    // Set mock fee to zero so the balance check (balance >= 0) trivially passes.
    // We still need to mock balance_of and approve on FAKE_STRK since it is not
    // a real deployed contract; snforge's start_mock_call intercepts those calls.
    let ep_reader = IMockEndpointReaderDispatcher { contract_address: ep };
    ep_reader.set_quoted_fee(0_u256);

    // Mock STRK balance_of → 0  (u256 serialises as two felts: low, high)
    start_mock_call(strk, selector!("balance_of"), array![0_felt252, 0_felt252]);
    // Mock STRK approve → true  (bool serialises as felt252 1)
    start_mock_call(strk, selector!("approve"), array![1_felt252]);

    // deliver() registers the peer and calls lz_receive as the endpoint.
    deliver(addr, ep, encode_aba(5, 3));

    let reader = IMockEndpointReaderDispatcher { contract_address: ep };
    assert!(reader.send_call_count() == 1);
    assert!(reader.last_send_dst_eid() == SRC_EID);
    // Return message is a 32-byte plain payload encoding by_eth=3.
    let sent = reader.last_send_message();
    assert!(sent.len() == 32);
    // The last byte should be 3 (big-endian, right-aligned 8-byte value).
    assert!(sent.at(31).unwrap() == 3_u8);
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
    while i < 16 {
        bad.append_byte(0);
        i += 1;
    }
    deliver(addr, ep, bad);
}
