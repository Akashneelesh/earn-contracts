// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {OFT} from "@layerzerolabs/oapp-evm/contracts/oft/OFT.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockUsdcOft
/// @notice Demo-only USDC stand-in implemented as a LayerZero V2 OFT.
///         6 decimals on both sides so sharedDecimals == localDecimals and
///         there is no dust loss when bridging. A public faucet() lets the
///         browser burner mint itself test tokens without an owner round-trip.
contract MockUsdcOft is OFT {
    uint256 public constant FAUCET_CAP = 10_000 * 10 ** 6; // 10,000 mUSDC per call

    constructor(address _endpoint, address _owner)
        OFT("Mock USDC", "mUSDC", _endpoint, _owner)
        Ownable(_owner)
    {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint up to FAUCET_CAP mUSDC to the caller. Demo only.
    function faucet(uint256 amount) external {
        require(amount > 0 && amount <= FAUCET_CAP, "faucet cap");
        _mint(msg.sender, amount);
    }
}
