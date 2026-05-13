// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {MockUsdcOft} from "../src/MockUsdcOft.sol";

/// @notice Registers the Starknet MockUsdcOft as the peer for DST_EID_STARKNET
///         on the EVM MockUsdcOft. The Starknet side must mirror this with
///         scripts/23_wire_oft_peers.sh.
contract SetOftPeer is Script {
    function run() external {
        address oftAddr = vm.envAddress("MOCK_USDC_OFT_EVM");
        uint32 dstEid = uint32(vm.envUint("DST_EID_STARKNET"));
        bytes32 peer = vm.envBytes32("MOCK_USDC_OFT_STARKNET_BYTES32");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        MockUsdcOft(oftAddr).setPeer(dstEid, peer);
        vm.stopBroadcast();

        console2.log("OFT peer set:");
        console2.log("  oft:", oftAddr);
        console2.log("  dstEid:", dstEid);
        console2.logBytes32(peer);
    }
}
