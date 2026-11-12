// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

/// @title FinchainProbe
/// @notice A deliberately small contract for the chain's EVM acceptance: one storage word written and read back
///         through the public RPC, one event. It belongs to no covenant and to no agent runtime; it exists so that
///         "an ordinary developer can deploy, write and read a contract on this chain" is demonstrated on its own.
contract FinchainProbe {
    uint256 public value;
    uint256 public writes;
    address public deployer;

    event Set(address indexed by, uint256 value, uint256 writes);

    constructor() {
        deployer = msg.sender;
    }

    function set(uint256 newValue) external {
        value = newValue;
        writes += 1;
        emit Set(msg.sender, newValue, writes);
    }
}
