// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// The owner's explicit sign of life on one chain. Only the owner can make it emit Alive, so a log from this
/// contract proves he acted; a log from any other contract proves nothing (anyone can emit any topic).
contract CheckIn {
    event Alive(address indexed owner, uint256 at);

    address public immutable owner;
    /// Read by the vault on this chain before it releases anything (the last guard, see SilenceWatch).
    uint256 public last;

    constructor(address owner_) {
        owner = owner_;
        last = block.timestamp;
    }

    function checkIn() external {
        require(msg.sender == owner, "not owner");
        last = block.timestamp;
        emit Alive(msg.sender, block.timestamp);
    }
}
