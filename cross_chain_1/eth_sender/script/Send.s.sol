// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {StringSender} from "../src/StringSender.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

/// @notice Sends a one-off string to Starknet via the deployed StringSender.
contract Send is Script {
    function run() external {
        address senderAddr = vm.envAddress("SENDER_ADDRESS");
        uint32 dstEid = uint32(vm.envUint("DST_EID_STARKNET"));
        string memory value = vm.envOr("MESSAGE", string("hello from ethereum"));
        uint256 pk = vm.envUint("PRIVATE_KEY");

        StringSender sender = StringSender(senderAddr);
        bytes memory opts = sender.defaultOptions();

        MessagingFee memory fee = sender.quoteSendString(dstEid, value, opts);
        console2.log("Required native fee (wei):", fee.nativeFee);

        vm.startBroadcast(pk);
        MessagingReceipt memory r = sender.sendString{value: fee.nativeFee}(dstEid, value, opts);
        vm.stopBroadcast();

        console2.log("Sent. Track delivery on https://testnet.layerzeroscan.com/ using guid:");
        console2.logBytes32(r.guid);
    }
}
