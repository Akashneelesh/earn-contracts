// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {StringSender} from "../src/StringSender.sol";
import {MessagingFee, MessagingParams, MessagingReceipt} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

/// Mocks the bits of EndpointV2 that StringSender touches: `quote`, `send`,
/// `setDelegate`, and `eid()`. Lets us assert exactly what payload + options
/// LayerZero would see, without standing up a real DVN/Executor stack.
contract MockEndpoint {
    uint32 public constant LOCAL_EID = 40161; // pretend ETH Sepolia

    MessagingParams public lastSendParams;
    address public lastRefund;
    uint256 public lastValue;
    address public delegate;

    uint256 public quotedNativeFee = 0.0001 ether;

    function eid() external pure returns (uint32) {
        return LOCAL_EID;
    }

    function setDelegate(address d) external {
        delegate = d;
    }

    function quote(MessagingParams calldata, address)
        external
        view
        returns (MessagingFee memory)
    {
        return MessagingFee({nativeFee: quotedNativeFee, lzTokenFee: 0});
    }

    function send(MessagingParams calldata params, address refund)
        external
        payable
        returns (MessagingReceipt memory)
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

contract StringSenderTest is Test {
    using OptionsBuilder for bytes;

    MockEndpoint internal endpoint;
    StringSender internal sender;
    address internal owner = address(0xA11CE);

    uint32 internal constant DST_EID = 30303; // pretend Starknet
    bytes32 internal constant STARKNET_PEER =
        0x0102030405060708090a0b0c0d0e0f10112233445566778899aabbccddeeff00; // 32B

    function setUp() public {
        endpoint = new MockEndpoint();
        sender = new StringSender(address(endpoint), owner);

        vm.prank(owner);
        sender.setPeer(DST_EID, STARKNET_PEER);
    }

    function test_constructor_sets_endpoint_and_owner() public view {
        assertEq(address(sender.endpoint()), address(endpoint));
        assertEq(sender.owner(), owner);
    }

    function test_setPeer_is_owner_only() public {
        bytes32 newPeer = bytes32(uint256(1));
        vm.expectRevert();
        sender.setPeer(DST_EID, newPeer);

        vm.prank(owner);
        sender.setPeer(DST_EID, newPeer);
        assertEq(sender.peers(DST_EID), newPeer);
    }

    function test_quoteSendString_returns_native_fee() public view {
        bytes memory opts = sender.defaultOptions();
        MessagingFee memory fee = sender.quoteSendString(DST_EID, "hello", opts);
        assertEq(fee.nativeFee, 0.0001 ether);
        assertEq(fee.lzTokenFee, 0);
    }

    function test_sendString_forwards_payload_and_peer_to_endpoint() public {
        bytes memory opts = sender.defaultOptions();
        string memory payload = "hello from ethereum";

        MessagingFee memory fee = sender.quoteSendString(DST_EID, payload, opts);

        vm.deal(address(this), fee.nativeFee);
        MessagingReceipt memory r =
            sender.sendString{value: fee.nativeFee}(DST_EID, payload, opts);

        // Sanity: endpoint actually saw a send call with the right peer + payload.
        (uint32 dstEid, bytes32 receiver,,,) = endpoint.lastSendParams();
        assertEq(dstEid, DST_EID, "dst eid forwarded");
        assertEq(receiver, STARKNET_PEER, "peer forwarded as receiver");
        assertEq(endpoint.lastRefund(), address(this), "refund == caller");
        assertEq(endpoint.lastValue(), fee.nativeFee, "native fee forwarded");
        assertGt(uint256(r.guid), 0, "guid produced");
    }

    function test_sendString_without_peer_reverts() public {
        uint32 unknownEid = 99999;
        bytes memory opts = sender.defaultOptions();

        // OApp's _getPeerOrRevert kicks in before the endpoint mock can be reached.
        vm.expectRevert();
        sender.quoteSendString(unknownEid, "x", opts);
    }

    function test_defaultOptions_is_type3_with_executor_gas() public view {
        bytes memory opts = sender.defaultOptions();
        // OptionsBuilder.newOptions() seeds Type 3 (0x0003).
        assertEq(bytes2(opts), bytes2(uint16(3)));
    }
}
