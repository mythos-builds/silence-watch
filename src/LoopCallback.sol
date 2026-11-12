// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

/// Receives the callback the reactive contract asked for.
contract LoopCallback is AbstractCallback {
    event Handled(uint256 indexed value, uint256 originBlock, uint256 at);

    uint256 public handled;
    uint256 public lastValue;

    constructor(IPayable callbackProxy_, address reactive_) payable AbstractCallback(callbackProxy_, reactive_) {}

    function onTick(address reactive_, uint256 value_, uint256 originBlock_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        handled += 1;
        lastValue = value_;
        emit Handled(value_, originBlock_, block.timestamp);
    }

    function coverDebt() external {
        _coverDebt();
    }
}
