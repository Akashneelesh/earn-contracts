// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {StringSender} from "../src/StringSender.sol";

/// @notice Registers the Starknet OApp as the peer for DST_EID_STARKNET.
contract SetPeer is Script {
    function run() external {
        address senderAddr = vm.envAddress("SENDER_ADDRESS");
        uint32 dstEid = uint32(vm.envUint("DST_EID_STARKNET"));
        bytes32 peer = vm.envBytes32("STARKNET_PEER_BYTES32");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        StringSender(senderAddr).setPeer(dstEid, peer);
        vm.stopBroadcast();

        console2.log("Set peer:");
        console2.log("  dstEid:", dstEid);
        console2.logBytes32(peer);
    }
}
