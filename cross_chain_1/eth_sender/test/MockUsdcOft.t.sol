// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {MockUsdcOft} from "../src/MockUsdcOft.sol";
import {MessagingFee, MessagingParams, MessagingReceipt} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {SendParam, OFTLimit, OFTReceipt, OFTFeeDetail} from "@layerzerolabs/oapp-evm/contracts/oft/interfaces/IOFT.sol";

contract MockEndpoint {
    uint32 public constant LOCAL_EID = 40161;
    MessagingParams public lastSendParams;
    address public delegate;
    uint256 public quotedNativeFee = 0.0001 ether;

    function eid() external pure returns (uint32) { return LOCAL_EID; }
    function setDelegate(address d) external { delegate = d; }
    function quote(MessagingParams calldata, address) external view returns (MessagingFee memory) {
        return MessagingFee({nativeFee: quotedNativeFee, lzTokenFee: 0});
    }
    function send(MessagingParams calldata params, address) external payable returns (MessagingReceipt memory) {
        lastSendParams = params;
        return MessagingReceipt({guid: keccak256(abi.encode(params)), nonce: 1, fee: MessagingFee(msg.value, 0)});
    }
}

contract MockUsdcOftTest is Test {
    using OptionsBuilder for bytes;

    MockEndpoint internal endpoint;
    MockUsdcOft internal oft;
    address internal owner = address(0xA11CE);
    address internal user = address(0xBEEF);

    function setUp() public {
        endpoint = new MockEndpoint();
        vm.prank(owner);
        oft = new MockUsdcOft(address(endpoint), owner);
    }

    function test_decimals_is_6() public view {
        assertEq(oft.decimals(), 6);
    }

    function test_shared_decimals_is_6() public view {
        assertEq(oft.sharedDecimals(), 6);
    }

    function test_conversion_rate_is_1() public view {
        assertEq(oft.decimalConversionRate(), 1);
    }

    function test_faucet_mints_to_caller() public {
        vm.prank(user);
        oft.faucet(1000 * 1e6);
        assertEq(oft.balanceOf(user), 1000 * 1e6);
    }

    function test_faucet_respects_cap() public {
        vm.prank(user);
        vm.expectRevert(bytes("faucet cap"));
        oft.faucet(10_001 * 1e6);
    }

    function test_faucet_rejects_zero() public {
        vm.prank(user);
        vm.expectRevert(bytes("faucet cap"));
        oft.faucet(0);
    }

    function test_setPeer_only_owner() public {
        bytes32 peer = bytes32(uint256(0xdeadbeef));
        vm.prank(user);
        vm.expectRevert();
        oft.setPeer(40500, peer);

        vm.prank(owner);
        oft.setPeer(40500, peer);
        assertEq(oft.peers(40500), peer);
    }

    function test_quoteSend_with_compose_options_returns_nonzero_fee() public {
        bytes32 peer = bytes32(uint256(0xC0FFEE));
        vm.prank(owner);
        oft.setPeer(40500, peer);

        bytes memory extraOptions = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(200_000, 0)
            .addExecutorLzComposeOption(0, 200_000, 0);

        SendParam memory sp = SendParam({
            dstEid: 40500,
            to: bytes32(uint256(uint160(user))),
            amountLD: 1_000_000,
            minAmountLD: 1_000_000,
            extraOptions: extraOptions,
            composeMsg: abi.encode(uint64(5), bytes32(uint256(uint160(user)))),
            oftCmd: ""
        });

        MessagingFee memory fee = oft.quoteSend(sp, false);
        assertGt(fee.nativeFee, 0);
        assertEq(fee.lzTokenFee, 0);
    }

    function test_send_with_compose_calls_endpoint() public {
        bytes32 peer = bytes32(uint256(0xC0FFEE));
        vm.prank(owner);
        oft.setPeer(40500, peer);

        vm.prank(user);
        oft.faucet(10 * 1e6);

        bytes memory extraOptions = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(200_000, 0)
            .addExecutorLzComposeOption(0, 200_000, 0);

        SendParam memory sp = SendParam({
            dstEid: 40500,
            to: bytes32(uint256(0xCA11ED)),
            amountLD: 1_000_000,
            minAmountLD: 1_000_000,
            extraOptions: extraOptions,
            composeMsg: abi.encode(uint64(7), bytes32(uint256(uint160(user)))),
            oftCmd: ""
        });

        MessagingFee memory fee = oft.quoteSend(sp, false);

        vm.deal(user, 1 ether);
        vm.prank(user);
        oft.send{value: fee.nativeFee}(sp, fee, user);

        // Burned 1 mUSDC out of 10
        assertEq(oft.balanceOf(user), 9 * 1e6);
    }
}
