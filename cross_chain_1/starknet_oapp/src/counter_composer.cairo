// LayerZero V2 OFT compose target.
//
// Receives `lz_compose` from the Starknet endpoint after the local MockUsdcOft
// has minted `amount_ld` mUSDC to this contract. We then:
//   1) forward the just-credited mUSDC to the final recipient encoded in the
//      compose payload,
//   2) bump the existing Counter contract by `by`,
//   3) emit ComposeExecuted for the UI.
//
// Payload format (EVM-side `abi.encode(uint64 by, bytes32 final_recipient)`):
//   bytes  0..32 : uint64 `by`, right-aligned in 32-byte big-endian word
//   bytes 32..64 : bytes32 final_recipient (felt252 fits in 252 bits)
//
// `from` (the lz_compose arg) is the source-OApp address ON THIS CHAIN —
// i.e. the MockUsdcOft contract.

use starknet::ContractAddress;

#[starknet::interface]
pub trait ICounterComposeIncrement<TState> {
    fn compose_increment(ref self: TState, by: u64) -> u64;
}

#[starknet::contract]
pub mod CounterComposer {
    use core::num::traits::Zero;
    use layerzero::endpoint::interfaces::layerzero_composer::ILayerZeroComposer;
    use layerzero::oapps::oft::oft_compose_msg_codec::OFTComposeMsgCodec;
    use lz_utils::bytes::Bytes32;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address};
    use super::{ICounterComposeIncrementDispatcher, ICounterComposeIncrementDispatcherTrait};

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        usdc_oft: ContractAddress,
        counter: ContractAddress,
        endpoint: ContractAddress,
        received_count: u64,
        last_by: u64,
        last_amount_ld: u256,
        last_recipient: ContractAddress,
        last_guid: Bytes32,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        ComposeExecuted: ComposeExecuted,
        ConfigUpdated: ConfigUpdated,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ComposeExecuted {
        #[key]
        pub guid: Bytes32,
        pub by: u64,
        pub amount_ld: u256,
        pub recipient: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ConfigUpdated {
        pub usdc_oft: ContractAddress,
        pub counter: ContractAddress,
        pub endpoint: ContractAddress,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        usdc_oft: ContractAddress,
        counter: ContractAddress,
        endpoint: ContractAddress,
    ) {
        self.ownable.initializer(owner);
        self.usdc_oft.write(usdc_oft);
        self.counter.write(counter);
        self.endpoint.write(endpoint);
    }

    #[abi(embed_v0)]
    impl ComposerImpl of ILayerZeroComposer<ContractState> {
        fn lz_compose(
            ref self: ContractState,
            from: ContractAddress,
            guid: Bytes32,
            message: ByteArray,
            executor: ContractAddress,
            extra_data: ByteArray,
            value: u256,
        ) {
            let _ = executor;
            let _ = extra_data;
            let _ = value;

            // Caller must be the configured endpoint, and `from` must be our
            // OFT — together this guarantees a legitimate compose dispatch.
            assert(get_caller_address() == self.endpoint.read(), 'BAD_CALLER');
            assert(from == self.usdc_oft.read(), 'BAD_FROM');

            // amount_ld credited to this contract by the OFT _credit hook.
            let amount_ld = OFTComposeMsgCodec::amount_ld(@message);

            // User payload: 64 bytes, abi.encode(uint64 by, bytes32 recipient).
            let payload = OFTComposeMsgCodec::compose_msg(@message);
            assert(payload.len() >= 64_u32, 'BAD_PAYLOAD_LEN');

            // uint64 padded to 32 bytes — value lives in bytes 24..32 (BE).
            let by = read_u64_be_at(@payload, 24);
            // bytes32 recipient — bytes 32..64.
            let recipient_b32 = read_u256_be_at(@payload, 32);
            let recipient = address_from_u256(recipient_b32);
            assert(!recipient.is_zero(), 'ZERO_RECIPIENT');

            // 1) Forward the just-credited mUSDC to the final recipient.
            let oft = self.usdc_oft.read();
            let _ = IERC20Dispatcher { contract_address: oft }.transfer(recipient, amount_ld);

            // 2) Bump the Counter through its permissioned entrypoint.
            let counter = self.counter.read();
            let _ = ICounterComposeIncrementDispatcher { contract_address: counter }
                .compose_increment(by);

            // 3) Record + emit.
            self.received_count.write(self.received_count.read() + 1);
            self.last_by.write(by);
            self.last_amount_ld.write(amount_ld);
            self.last_recipient.write(recipient);
            self.last_guid.write(guid);
            self.emit(ComposeExecuted { guid, by, amount_ld, recipient });
        }
    }

    #[starknet::interface]
    pub trait IComposerAdmin<TState> {
        fn usdc_oft(self: @TState) -> ContractAddress;
        fn counter(self: @TState) -> ContractAddress;
        fn endpoint(self: @TState) -> ContractAddress;
        fn received_count(self: @TState) -> u64;
        fn last_by(self: @TState) -> u64;
        fn last_amount_ld(self: @TState) -> u256;
        fn last_recipient(self: @TState) -> ContractAddress;
        fn last_guid(self: @TState) -> Bytes32;
        fn set_config(
            ref self: TState,
            usdc_oft: ContractAddress,
            counter: ContractAddress,
            endpoint: ContractAddress,
        );
    }

    #[abi(embed_v0)]
    impl AdminImpl of IComposerAdmin<ContractState> {
        fn usdc_oft(self: @ContractState) -> ContractAddress {
            self.usdc_oft.read()
        }
        fn counter(self: @ContractState) -> ContractAddress {
            self.counter.read()
        }
        fn endpoint(self: @ContractState) -> ContractAddress {
            self.endpoint.read()
        }
        fn received_count(self: @ContractState) -> u64 {
            self.received_count.read()
        }
        fn last_by(self: @ContractState) -> u64 {
            self.last_by.read()
        }
        fn last_amount_ld(self: @ContractState) -> u256 {
            self.last_amount_ld.read()
        }
        fn last_recipient(self: @ContractState) -> ContractAddress {
            self.last_recipient.read()
        }
        fn last_guid(self: @ContractState) -> Bytes32 {
            self.last_guid.read()
        }
        fn set_config(
            ref self: ContractState,
            usdc_oft: ContractAddress,
            counter: ContractAddress,
            endpoint: ContractAddress,
        ) {
            self.ownable.assert_only_owner();
            self.usdc_oft.write(usdc_oft);
            self.counter.write(counter);
            self.endpoint.write(endpoint);
            self.emit(ConfigUpdated { usdc_oft, counter, endpoint });
        }
    }

    fn read_u64_be_at(data: @ByteArray, offset: u32) -> u64 {
        let mut acc: u64 = 0;
        let mut i: u32 = 0;
        while i < 8 {
            let b: u64 = data.at(offset + i).unwrap().into();
            acc = acc * 256 + b;
            i += 1;
        }
        acc
    }

    fn read_u256_be_at(data: @ByteArray, offset: u32) -> u256 {
        let mut acc: u256 = 0_u256;
        let mut i: u32 = 0;
        while i < 32 {
            let b: u256 = data.at(offset + i).unwrap().into();
            acc = acc * 256_u256 + b;
            i += 1;
        }
        acc
    }

    fn address_from_u256(v: u256) -> ContractAddress {
        // ContractAddress is a felt252 — the low 251 bits fit. We only accept
        // values whose high bits are zero (StarkNet addresses cannot exceed
        // 2^251 + 17 * 2^192, but in practice the burner address fits in 252 bits).
        let lz: lz_utils::bytes::Bytes32 = lz_utils::bytes::Bytes32 { value: v };
        lz.try_into().unwrap()
    }
}
