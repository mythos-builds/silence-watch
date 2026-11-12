// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// The event source: anyone can emit a Tick.
contract Origin {
    event Tick(address indexed from, uint256 indexed value);

    function tick(uint256 value_) external {
        emit Tick(msg.sender, value_);
    }
}
