// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OAppOptionsType3} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title StringSender
/// @notice Bidirectional LayerZero V2 OApp: sends strings to Starknet AND
///         receives strings back. Matching counterpart is
///         cross_chain/starknet_oapp/src/string_receiver.cairo.
contract StringSender is OApp, OAppOptionsType3 {
    using OptionsBuilder for bytes;

    uint16 public constant SEND = 1;

    string public lastMessage;
    uint32 public lastSrcEid;
    uint64 public messageCount;

    event StringSent(uint32 indexed dstEid, bytes32 guid, string value);
    event StringReceived(uint32 indexed srcEid, bytes32 guid, string value);

    constructor(address _endpoint, address _owner)
        OApp(_endpoint, _owner)
        Ownable(_owner)
    {}

    /// @notice Quote the native fee for sending `_value` to `_dstEid`.
    /// @dev Call this off-chain (eth_call) to learn how much ETH to attach.
    function quoteSendString(
        uint32 _dstEid,
        string calldata _value,
        bytes calldata _options
    ) external view returns (MessagingFee memory fee) {
        bytes memory payload = abi.encode(_value);
        fee = _quote(_dstEid, payload, combineOptions(_dstEid, SEND, _options), false);
    }

    /// @notice Send `_value` to the Starknet OApp registered for `_dstEid`.
    /// @dev `msg.value` must be >= the fee returned by `quoteSendString`.
    function sendString(
        uint32 _dstEid,
        string calldata _value,
        bytes calldata _options
    ) external payable returns (MessagingReceipt memory receipt) {
        bytes memory payload = abi.encode(_value);
        receipt = _lzSend(
            _dstEid,
            payload,
            combineOptions(_dstEid, SEND, _options),
            MessagingFee(msg.value, 0),
            payable(msg.sender)
        );
        emit StringSent(_dstEid, receipt.guid, _value);
    }

    /// @notice Convenience: default options with 200k gas on the destination executor.
    function defaultOptions() external pure returns (bytes memory) {
        return OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
    }

    /// @dev Called by the LayerZero endpoint when a message arrives from the
    ///      Starknet peer. OApp's parent already verified caller==endpoint and
    ///      origin.sender==peers[origin.srcEid] before reaching here.
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata /* _extraData */
    ) internal override {
        // Cairo encodes a `ByteArray` directly (no abi.encode wrapper),
        // so we treat the payload as raw UTF-8 bytes.
        string memory value = string(_message);
        lastMessage = value;
        lastSrcEid = _origin.srcEid;
        unchecked { messageCount += 1; }
        emit StringReceived(_origin.srcEid, _guid, value);
    }
}
