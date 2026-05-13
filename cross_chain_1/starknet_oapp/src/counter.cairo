// LayerZero V2 OApp on Starknet — bidirectional counter.
//
// Inbound  : `count` increases by N whenever the EVM peer sends `abi.encode(uint64 N)`.
// Outbound : `trigger_increment(dst_eid, by, gas_limit)` sends a message back to
//             the EVM peer, causing its counter to go up by `by`.

#[starknet::contract]
pub mod Counter {
    use layerzero::Origin;
    use layerzero::common::structs::messaging::{MessageReceipt, MessagingFee};
    use layerzero::oapps::counter::options::executor_lz_receive_option;
    use layerzero::oapps::oapp::oapp_core::OAppCoreComponent;
    use lz_utils::bytes::Bytes32;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};

    #[starknet::interface]
    pub trait ICounter<TState> {
        fn count(self: @TState) -> u64;
        fn last_increment_by(self: @TState) -> u64;
        fn last_src_eid(self: @TState) -> u32;
        fn return_gas(self: @TState) -> u128;
        fn return_value(self: @TState) -> u128;
        fn trusted_composer(self: @TState) -> ContractAddress;
        fn set_return_options(ref self: TState, gas: u128, value: u128);
        fn set_composer(ref self: TState, composer: ContractAddress);
        fn compose_increment(ref self: TState, by: u64) -> u64;
        fn quote_trigger_increment(
            self: @TState, dst_eid: u32, by: u64, gas_limit: u128,
        ) -> MessagingFee;
        fn trigger_increment(
            ref self: TState, dst_eid: u32, by: u64, gas_limit: u128,
        ) -> MessageReceipt;
        fn withdraw_strk(ref self: TState, to: ContractAddress, amount: u256);
    }

    const PLAIN_PAYLOAD_LEN: u32 = 32;
    const ABA_PAYLOAD_LEN: u32 = 17;
    const ABA_TAG: u8 = 0x01;

    component!(path: OAppCoreComponent, storage: oapp_core, event: OAppCoreEvent);
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OAppCoreImpl = OAppCoreComponent::OAppCoreImpl<ContractState>;
    #[abi(embed_v0)]
    impl ILayerZeroReceiverImpl =
        OAppCoreComponent::LayerZeroReceiverImpl<ContractState>;
    #[abi(embed_v0)]
    impl IOAppReceiverImpl = OAppCoreComponent::OAppReceiverImpl<ContractState>;
    impl OAppCoreInternalImpl = OAppCoreComponent::InternalImpl<ContractState>;
    impl OAppCoreSenderImpl = OAppCoreComponent::OAppSenderImpl<ContractState>;

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        count: u64,
        last_increment_by: u64,
        last_src_eid: u32,
        return_gas: u128,
        return_value: u128,
        trusted_composer: ContractAddress,
        #[substorage(v0)]
        oapp_core: OAppCoreComponent::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        Incremented: Incremented,
        IncrementTriggered: IncrementTriggered,
        AbaBounceSent: AbaBounceSent,
        ComposedIncrement: ComposedIncrement,
        ComposerSet: ComposerSet,
        #[flat]
        OAppCoreEvent: OAppCoreComponent::Event,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Incremented {
        #[key]
        pub src_eid: u32,
        pub guid: Bytes32,
        pub by: u64,
        pub new_count: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct IncrementTriggered {
        #[key]
        pub dst_eid: u32,
        pub guid: Bytes32,
        pub by: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AbaBounceSent {
        #[key]
        pub dst_eid: u32,
        pub guid: Bytes32,
        pub by_eth: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ComposedIncrement {
        #[key]
        pub composer: ContractAddress,
        pub by: u64,
        pub new_count: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ComposerSet {
        pub composer: ContractAddress,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        endpoint: ContractAddress,
        owner: ContractAddress,
        native_token: ContractAddress,
    ) {
        self.oapp_core.initializer(endpoint, owner, native_token);
        self.ownable.initializer(owner);
        self.return_gas.write(200_000_u128);
        self.return_value.write(0_u128);
    }

    impl OAppHooks of OAppCoreComponent::OAppHooks<ContractState> {
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
            } else if len == ABA_PAYLOAD_LEN {
                let tag = message.at(0).unwrap();
                if tag != ABA_TAG {
                    core::panic_with_felt252('BAD_ABA_TAG');
                }
                let by_sn = read_u64_be_at(@message, 1);
                let by_eth = read_u64_be_at(@message, 9);

                let mut contract = self.get_contract_mut();
                let new_count = contract.count.read() + by_sn;
                contract.count.write(new_count);
                contract.last_increment_by.write(by_sn);
                contract.last_src_eid.write(origin.src_eid);
                contract.emit(Incremented { src_eid: origin.src_eid, guid, by: by_sn, new_count });

                // Bounce back: plain 32-byte payload encoding by_eth to origin EID.
                let self_addr = get_contract_address();
                let return_payload = encode_uint64_abi(by_eth);
                let return_options = executor_lz_receive_option(
                    contract.return_gas.read(), contract.return_value.read().into(),
                );
                let fee = self
                    ._quote(origin.src_eid, return_payload.clone(), return_options.clone(), false);
                let receipt = self
                    ._lz_send(
                        self_addr, origin.src_eid, return_payload, return_options, fee, self_addr,
                    );
                contract
                    .emit(AbaBounceSent { dst_eid: origin.src_eid, guid: receipt.guid, by_eth });
            } else {
                core::panic_with_felt252('BAD_PAYLOAD_LEN');
            }
        }
    }

    #[abi(embed_v0)]
    impl CounterImpl of ICounter<ContractState> {
        fn count(self: @ContractState) -> u64 {
            self.count.read()
        }
        fn last_increment_by(self: @ContractState) -> u64 {
            self.last_increment_by.read()
        }
        fn last_src_eid(self: @ContractState) -> u32 {
            self.last_src_eid.read()
        }
        fn return_gas(self: @ContractState) -> u128 {
            self.return_gas.read()
        }
        fn return_value(self: @ContractState) -> u128 {
            self.return_value.read()
        }
        fn trusted_composer(self: @ContractState) -> ContractAddress {
            self.trusted_composer.read()
        }
        fn set_return_options(ref self: ContractState, gas: u128, value: u128) {
            self.ownable.assert_only_owner();
            self.return_gas.write(gas);
            self.return_value.write(value);
        }
        fn set_composer(ref self: ContractState, composer: ContractAddress) {
            self.ownable.assert_only_owner();
            self.trusted_composer.write(composer);
            self.emit(ComposerSet { composer });
        }
        fn compose_increment(ref self: ContractState, by: u64) -> u64 {
            let caller = get_caller_address();
            let composer = self.trusted_composer.read();
            assert(caller == composer, 'NOT_COMPOSER');
            let new_count = self.count.read() + by;
            self.count.write(new_count);
            self.last_increment_by.write(by);
            self.emit(ComposedIncrement { composer, by, new_count });
            new_count
        }

        fn quote_trigger_increment(
            self: @ContractState, dst_eid: u32, by: u64, gas_limit: u128,
        ) -> MessagingFee {
            let payload = encode_uint64_abi(by);
            let options = executor_lz_receive_option(gas_limit, 0);
            self.oapp_core._quote(dst_eid, payload, options, false)
        }

        fn trigger_increment(
            ref self: ContractState, dst_eid: u32, by: u64, gas_limit: u128,
        ) -> MessageReceipt {
            let caller = get_caller_address();
            let payload = encode_uint64_abi(by);
            let options = executor_lz_receive_option(gas_limit, 0);
            let fee = self.oapp_core._quote(dst_eid, payload.clone(), options.clone(), false);
            let receipt = self.oapp_core._lz_send(caller, dst_eid, payload, options, fee, caller);
            self.emit(IncrementTriggered { dst_eid, guid: receipt.guid, by });
            receipt
        }

        fn withdraw_strk(ref self: ContractState, to: ContractAddress, amount: u256) {
            self.ownable.assert_only_owner();
            let strk = self.oapp_core.OAppCore_native_token.read();
            let _ = IERC20Dispatcher { contract_address: strk }.transfer(to, amount);
        }
    }

    // Build the EVM-compatible payload: 32-byte big-endian value, value right-
    // aligned in the last 8 bytes. Matches Solidity's `abi.encode(uint64)`.
    fn encode_uint64_abi(value: u64) -> ByteArray {
        let mut out: ByteArray = Default::default();
        // 24 leading zero bytes
        let mut i: u32 = 0;
        while i < 24 {
            out.append_byte(0);
            i += 1;
        }
        // 8 bytes of value, big-endian
        let mut v: u64 = value;
        let mut bytes: Array<u8> = ArrayTrait::new();
        let mut j: u32 = 0;
        while j < 8 {
            let b: u8 = (v % 256).try_into().unwrap();
            bytes.append(b);
            v = v / 256;
            j += 1;
        }
        // bytes is little-endian; reverse onto `out`
        let mut k: u32 = 8;
        while k > 0 {
            k -= 1;
            out.append_byte(*bytes.at(k));
        }
        out
    }

    fn read_u64_be_at(data: @ByteArray, offset: usize) -> u64 {
        let mut acc: u64 = 0;
        let mut i: usize = 0;
        while i < 8 {
            let b: u64 = data.at(offset + i).unwrap().into();
            acc = acc * 256 + b;
            i += 1;
        }
        acc
    }
}
