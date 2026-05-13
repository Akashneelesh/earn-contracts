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

    function test_defaultAbaOptions_uses_1m_executor_gas() public view {
        bytes memory expected =
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(1_000_000, 0);
        bytes memory got = trigger.defaultAbaOptions();
        assertEq(got, expected);
    }

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

        uint64 decodedSn = 0;
        for (uint256 i = 1; i <= 8; i++) decodedSn = (decodedSn << 8) | uint64(uint8(message[i]));
        assertEq(decodedSn, bySn);

        uint64 decodedEth = 0;
        for (uint256 i = 9; i <= 16; i++) decodedEth = (decodedEth << 8) | uint64(uint8(message[i]));
        assertEq(decodedEth, byEth);
    }

    function test_quoteAbaIncrement_returns_nonzero_fee() public view {
        bytes memory options = trigger.defaultAbaOptions();
        MessagingFee memory fee = trigger.quoteAbaIncrement(DST_EID, 5, 3, options);
        assertGt(fee.nativeFee, 0);
        assertEq(fee.lzTokenFee, 0);
    }

    function test_lzReceive_plain_payload_increments_count() public {
        uint64 by = 9;
        bytes memory msgBytes = abi.encode(by);
        Origin memory origin = Origin({srcEid: DST_EID, sender: SN_PEER, nonce: 1});
        bytes32 guid = bytes32(uint256(0xabc));
        vm.prank(address(endpoint));
        trigger.lzReceive(origin, guid, msgBytes, address(0), bytes(""));
        assertEq(trigger.count(), by);
        assertEq(trigger.lastIncrementBy(), by);
        assertEq(trigger.lastSrcEid(), DST_EID);
    }
}
