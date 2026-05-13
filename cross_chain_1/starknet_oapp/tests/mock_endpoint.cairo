// Mock endpoint for snforge tests.
// Implements the full IEndpointV2 surface that OAppCore calls at runtime:
//   - set_delegate  (called in OAppCore::initializer)
//   - quote         (called by _quote)
//   - send          (called by _lz_send)
// All other IEndpointV2 methods are stubs that panic with 'not_implemented'.

use layerzero::common::structs::messaging::{MessageReceipt, MessagingFee, MessagingParams, Payee};
use layerzero::common::structs::packet::Origin;
use layerzero::endpoint::interfaces::endpoint_v2::ExecutionState;
use lz_utils::bytes::Bytes32;
use starknet::ContractAddress;

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
    use layerzero::endpoint::interfaces::endpoint_v2::IEndpointV2;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use super::{
        Bytes32, ContractAddress, ExecutionState, MessageReceipt, MessagingFee, MessagingParams,
        Origin, Payee,
    };

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
        fn last_send_dst_eid(self: @ContractState) -> u32 {
            self.last_send_dst_eid.read()
        }
        fn last_send_message(self: @ContractState) -> ByteArray {
            self.last_send_message.read()
        }
        fn last_send_options(self: @ContractState) -> ByteArray {
            self.last_send_options.read()
        }
        fn send_call_count(self: @ContractState) -> u32 {
            self.send_call_count.read()
        }
        fn set_quoted_fee(ref self: ContractState, native_fee: u256) {
            self.quoted_native_fee.write(native_fee);
        }
    }

    // Full IEndpointV2 implementation required by OAppCore dispatcher calls.
    // Parameter names must exactly match the trait definition (Cairo 2.16 requirement).
    #[abi(embed_v0)]
    impl EndpointV2Impl of IEndpointV2<ContractState> {
        fn send(
            ref self: ContractState, params: MessagingParams, refund_address: ContractAddress,
        ) -> MessageReceipt {
            let _ = refund_address;
            self.send_call_count.write(self.send_call_count.read() + 1);
            self.last_send_dst_eid.write(params.dst_eid);
            self.last_send_message.write(params.message.clone());
            self.last_send_options.write(params.options.clone());
            MessageReceipt {
                guid: Bytes32 { value: 0xdeadbeef_u256 },
                nonce: 1,
                payees: array![
                    Payee {
                        receiver: starknet::get_caller_address(),
                        native_amount: self.quoted_native_fee.read(),
                        lz_token_amount: 0,
                    },
                ],
            }
        }

        fn quote(
            self: @ContractState, params: MessagingParams, sender: ContractAddress,
        ) -> MessagingFee {
            let _ = params;
            let _ = sender;
            MessagingFee { native_fee: self.quoted_native_fee.read(), lz_token_fee: 0 }
        }

        // OAppCore initializer calls this; no-op is fine for tests.
        fn set_delegate(ref self: ContractState, delegate: ContractAddress) {
            let _ = delegate;
        }

        fn get_delegate(self: @ContractState, oapp: ContractAddress) -> ContractAddress {
            let _ = oapp;
            panic!("not_implemented")
        }

        fn get_eid(self: @ContractState) -> u32 {
            panic!("not_implemented")
        }

        fn get_lz_token(self: @ContractState) -> ContractAddress {
            panic!("not_implemented")
        }

        fn set_lz_token(ref self: ContractState, lz_token_address: ContractAddress) {
            let _ = lz_token_address;
            panic!("not_implemented")
        }

        fn verify(
            ref self: ContractState,
            origin: Origin,
            receiver: ContractAddress,
            payload_hash: Bytes32,
        ) {
            let _ = origin;
            let _ = receiver;
            let _ = payload_hash;
            panic!("not_implemented")
        }

        fn lz_receive(
            ref self: ContractState,
            origin: Origin,
            receiver: ContractAddress,
            guid: Bytes32,
            message: ByteArray,
            extra_data: ByteArray,
            value: u256,
        ) {
            let _ = origin;
            let _ = receiver;
            let _ = guid;
            let _ = message;
            let _ = extra_data;
            let _ = value;
            panic!("not_implemented")
        }

        fn lz_receive_alert(
            ref self: ContractState,
            origin: Origin,
            receiver: ContractAddress,
            guid: Bytes32,
            gas: u256,
            value: u256,
            message: ByteArray,
            extra_data: ByteArray,
            reason: Array<felt252>,
        ) {
            let _ = origin;
            let _ = receiver;
            let _ = guid;
            let _ = gas;
            let _ = value;
            let _ = message;
            let _ = extra_data;
            let _ = reason;
            panic!("not_implemented")
        }

        fn clear(
            ref self: ContractState,
            origin: Origin,
            receiver: ContractAddress,
            guid: Bytes32,
            message: ByteArray,
        ) {
            let _ = origin;
            let _ = receiver;
            let _ = guid;
            let _ = message;
            panic!("not_implemented")
        }

        fn initializable(self: @ContractState, origin: Origin, receiver: ContractAddress) -> bool {
            let _ = origin;
            let _ = receiver;
            panic!("not_implemented")
        }

        fn verifiable(self: @ContractState, origin: Origin, receiver: ContractAddress) -> bool {
            let _ = origin;
            let _ = receiver;
            panic!("not_implemented")
        }

        fn verifiable_with_receive_lib(
            self: @ContractState,
            origin: Origin,
            receiver: ContractAddress,
            receive_lib: ContractAddress,
        ) -> bool {
            let _ = origin;
            let _ = receiver;
            let _ = receive_lib;
            panic!("not_implemented")
        }

        fn executable(
            self: @ContractState, origin: Origin, receiver: ContractAddress,
        ) -> ExecutionState {
            let _ = origin;
            let _ = receiver;
            panic!("not_implemented")
        }
    }
}
