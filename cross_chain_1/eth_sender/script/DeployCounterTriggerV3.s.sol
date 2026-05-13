// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {CounterTrigger} from "../src/CounterTrigger.sol";

contract DeployCounterTriggerV3 is Script {
    function run() external returns (CounterTrigger trigger) {
        address endpoint = vm.envAddress("LZ_ENDPOINT");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);

        vm.startBroadcast(pk);
        trigger = new CounterTrigger(endpoint, owner);
        vm.stopBroadcast();

        console2.log("CounterTrigger v3 deployed at:", address(trigger));
    }
}
