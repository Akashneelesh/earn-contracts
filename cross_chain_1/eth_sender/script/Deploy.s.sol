// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {StringSender} from "../src/StringSender.sol";

contract Deploy is Script {
    function run() external returns (StringSender sender) {
        address endpoint = vm.envAddress("LZ_ENDPOINT");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);

        vm.startBroadcast(pk);
        sender = new StringSender(endpoint, owner);
        vm.stopBroadcast();

        console2.log("StringSender deployed at:", address(sender));
    }
}
