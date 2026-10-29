// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The trader's opt-in to a rebalance: the swap's hookData ENDS with the 32-byte MAGIC word.
/// Anything before the word is left to whoever else reads hookData (today nobody in Trueo does: the hook's
/// beforeSwap and the validator leave it unnamed, movePoolTick takes none), and a suffix keeps every offset a
/// future reader would abi.decode from byte 0 unchanged. Shorter or different data means "no opt-in"; the check
/// never reverts.
library RebalanceFlag {
    /// @dev keccak256("TrueoRebalancer.optIn.v1")
    bytes32 internal constant MAGIC = 0xd217274b52e15abef088a6b357c3ad97bf9442210f0a77bd7cf0fcaa84d70917;

    function isSet(bytes calldata hookData) internal pure returns (bool) {
        uint256 len = hookData.length;
        if (len < 32) return false;
        return bytes32(hookData[len - 32:]) == MAGIC;
    }

    /// @notice hookData that carries only the opt-in
    function encode() internal pure returns (bytes memory) {
        return abi.encodePacked(MAGIC);
    }

    /// @notice `data` followed by the opt-in
    function append(bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(data, MAGIC);
    }
}
