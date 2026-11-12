// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// A plain ERC-20 for the demo only: it stands in for the coins a real owner already keeps in his wallet. The whole
/// supply is minted once, to the owner, at deploy; no mint, no burn, no admin after that.
contract DemoToken {
    string public constant name = "Demo Token";
    string public constant symbol = "DEMO";
    uint8 public constant decimals = 18;
    uint256 public immutable totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address to_, uint256 supply_) {
        totalSupply = supply_;
        balanceOf[to_] = supply_;
        emit Transfer(address(0), to_, supply_);
    }

    function transfer(address to_, uint256 amount_) external returns (bool) {
        _move(msg.sender, to_, amount_);
        return true;
    }

    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;
        emit Approval(msg.sender, spender_, amount_);
        return true;
    }

    /// Emits no Approval for the spent allowance (unlike OpenZeppelin 4.x): a spender's move is not the owner's act.
    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool) {
        allowance[from_][msg.sender] -= amount_; // past the allowance: checked math reverts
        _move(from_, to_, amount_);
        return true;
    }

    function _move(address from_, address to_, uint256 amount_) internal {
        balanceOf[from_] -= amount_; // past the balance: checked math reverts
        balanceOf[to_] += amount_;
        emit Transfer(from_, to_, amount_);
    }
}
