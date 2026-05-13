// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OAppOptionsType3} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CounterTrigger
/// @notice Bidirectional counter. triggerIncrement() sends a remote-increment to
///         the Cairo Counter; _lzReceive() accepts inbound increments from Starknet
///         and applies them to this contract's local `count`.
///         Matching counterpart: cross_chain/starknet_oapp/src/counter.cairo
contract CounterTrigger is OApp, OAppOptionsType3 {
    using OptionsBuilder for bytes;

    uint16 public constant SEND = 1;
    uint16 public constant SEND_ABA = 2;
    uint8 public constant ABA_TAG = 0x01;

    uint64 public count;
    uint64 public lastIncrementBy;
    uint32 public lastSrcEid;

    event IncrementTriggered(uint32 indexed dstEid, bytes32 guid, uint64 by);
    event IncrementReceived(uint32 indexed srcEid, bytes32 guid, uint64 by, uint64 newCount);
    event AbaIncrementTriggered(uint32 indexed dstEid, bytes32 guid, uint64 bySn, uint64 byEth);

    constructor(address _endpoint, address _owner)
        OApp(_endpoint, _owner)
        Ownable(_owner)
    {}

    /// @notice Quote the native fee for triggering a remote increment.
    function quoteTriggerIncrement(
        uint32 _dstEid,
        uint64 _by,
        bytes calldata _options
    ) external view returns (MessagingFee memory fee) {
        bytes memory payload = abi.encode(_by); // 32 bytes, big-endian, right-aligned
        fee = _quote(_dstEid, payload, combineOptions(_dstEid, SEND, _options), false);
    }

    /// @notice The button. Sends a message that increments the remote counter by `_by`.
    /// @dev    `msg.value` must be >= quoteTriggerIncrement(...). Defaults to 1 if `_by==0`.
    function triggerIncrement(
        uint32 _dstEid,
        uint64 _by,
        bytes calldata _options
    ) external payable returns (MessagingReceipt memory receipt) {
        uint64 by = _by == 0 ? 1 : _by;
        bytes memory payload = abi.encode(by);
        receipt = _lzSend(
            _dstEid,
            payload,
            combineOptions(_dstEid, SEND, _options),
            MessagingFee(msg.value, 0),
            payable(msg.sender)
        );
        emit IncrementTriggered(_dstEid, receipt.guid, by);
    }

    /// @notice Convenience: default options with 200k gas on the destination executor.
    function defaultOptions() external pure returns (bytes memory) {
        return OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
    }

    /// @notice Default options for ABA increment messages: 1M gas on the destination executor.
    function defaultAbaOptions() external pure returns (bytes memory) {
        return OptionsBuilder.newOptions().addExecutorLzReceiveOption(1_000_000, 0);
    }

    /// @notice Quote the native fee for triggering an ABA increment.
    function quoteAbaIncrement(
        uint32 _dstEid,
        uint64 _bySn,
        uint64 _byEth,
        bytes calldata _options
    ) external view returns (MessagingFee memory fee) {
        bytes memory payload = abi.encodePacked(ABA_TAG, _bySn, _byEth);
        fee = _quote(_dstEid, payload, combineOptions(_dstEid, SEND_ABA, _options), false);
    }

    /// @notice Send an ABA increment: increments Cairo counter by `_bySn`, Cairo bounces
    ///         back a plain 32-byte message causing this contract to increment by `_byEth`.
    function triggerAbaIncrement(
        uint32 _dstEid,
        uint64 _bySn,
        uint64 _byEth,
        bytes calldata _options
    ) external payable returns (MessagingReceipt memory receipt) {
        bytes memory payload = abi.encodePacked(ABA_TAG, _bySn, _byEth);
        receipt = _lzSend(
            _dstEid,
            payload,
            combineOptions(_dstEid, SEND_ABA, _options),
            MessagingFee(msg.value, 0),
            payable(msg.sender)
        );
        emit AbaIncrementTriggered(_dstEid, receipt.guid, _bySn, _byEth);
    }

    /// @dev Called by the LayerZero endpoint when the Starknet peer fires a
    ///      trigger_increment(). The payload is `abi.encode(uint64)`.
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata /* _extraData */
    ) internal override {
        uint64 by = abi.decode(_message, (uint64));
        unchecked { count += by; }
        lastIncrementBy = by;
        lastSrcEid = _origin.srcEid;
        emit IncrementReceived(_origin.srcEid, _guid, by, count);
    }
}
