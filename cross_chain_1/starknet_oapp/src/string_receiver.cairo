// LayerZero V2 OApp on Starknet — bidirectional.
//
// Receives strings from EVM AND sends strings back. The matching EVM contract is
// cross_chain/eth_sender/src/StringSender.sol (which has its own _lzReceive
// implementation, so it can both send and receive).
//
// Pattern source: https://docs.layerzero.network/v2/developers/starknet/oapp/overview
// Reference impl: @layerzerolabs/protocol-starknet-v2/layerzero/src/oapps/counter/counter.cairo

#[starknet::contract]
pub mod StringReceiver {
    use layerzero::Origin;
    use layerzero::common::structs::messaging::{MessageReceipt, MessagingFee};
    use layerzero::oapps::counter::options::executor_lz_receive_option;
    use layerzero::oapps::oapp::oapp_core::OAppCoreComponent;
    use lz_utils::bytes::Bytes32;
    use openzeppelin::access::ownable::OwnableComponent;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address};

    #[starknet::interface]
    pub trait IStringReceiverViews<TState> {
        fn last_message(self: @TState) -> ByteArray;
        fn last_src_eid(self: @TState) -> u32;
        fn message_count(self: @TState) -> u64;
        fn quote_send_string(
            self: @TState, dst_eid: u32, message: ByteArray, gas_limit: u128,
        ) -> MessagingFee;
        fn send_string(
            ref self: TState, dst_eid: u32, message: ByteArray, gas_limit: u128,
        ) -> MessageReceipt;
    }

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
        last_message: ByteArray,
        last_src_eid: u32,
        message_count: u64,
        #[substorage(v0)]
        oapp_core: OAppCoreComponent::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        MessageReceived: MessageReceived,
        MessageSent: MessageSent,
        #[flat]
        OAppCoreEvent: OAppCoreComponent::Event,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MessageReceived {
        #[key]
        pub src_eid: u32,
        pub guid: Bytes32,
        pub message: ByteArray,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MessageSent {
        #[key]
        pub dst_eid: u32,
        pub guid: Bytes32,
        pub message: ByteArray,
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
            let mut contract = self.get_contract_mut();
            contract.last_message.write(message.clone());
            contract.last_src_eid.write(origin.src_eid);
            contract.message_count.write(contract.message_count.read() + 1);
            contract.emit(MessageReceived { src_eid: origin.src_eid, guid, message });
        }
    }

    #[abi(embed_v0)]
    impl Views of IStringReceiverViews<ContractState> {
        fn last_message(self: @ContractState) -> ByteArray {
            self.last_message.read()
        }

        fn last_src_eid(self: @ContractState) -> u32 {
            self.last_src_eid.read()
        }

        fn message_count(self: @ContractState) -> u64 {
            self.message_count.read()
        }

        // Quote how much STRK (native_token) the caller needs to approve to this
        // contract before calling send_string. View function — no state writes.
        fn quote_send_string(
            self: @ContractState, dst_eid: u32, message: ByteArray, gas_limit: u128,
        ) -> MessagingFee {
            let options = executor_lz_receive_option(gas_limit, 0);
            self.oapp_core._quote(dst_eid, message, options, false)
        }

        // Send `message` to the peer registered for `dst_eid`. Caller must have
        // approved this contract for at least `quote_send_string(...).native_fee`
        // STRK first. Returns a MessageReceipt with the guid for tracking.
        fn send_string(
            ref self: ContractState, dst_eid: u32, message: ByteArray, gas_limit: u128,
        ) -> MessageReceipt {
            let caller = get_caller_address();
            let options = executor_lz_receive_option(gas_limit, 0);
            let fee = self.oapp_core._quote(dst_eid, message.clone(), options.clone(), false);
            let receipt = self
                .oapp_core
                ._lz_send(caller, dst_eid, message.clone(), options, fee, caller);
            self.emit(MessageSent { dst_eid, guid: receipt.guid, message });
            receipt
        }
    }
}
