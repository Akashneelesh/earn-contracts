// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {MockUsdcOft} from "../src/MockUsdcOft.sol";

contract DeployMockUsdcOft is Script {
    function run() external returns (MockUsdcOft oft) {
        address endpoint = vm.envAddress("LZ_ENDPOINT");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);

        vm.startBroadcast(pk);
        oft = new MockUsdcOft(endpoint, owner);
        vm.stopBroadcast();

        console2.log("MockUsdcOft deployed at:", address(oft));
        console2.log("Owner:", owner);
    }
}
