// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// Watches Origin's Tick on the origin chain and asks for a callback on the destination chain.
contract LoopReactive is AbstractReactive {
    uint256 public constant TICK_TOPIC0 = uint256(keccak256("Tick(address,uint256)"));
    // Whole-transaction limit for the relayer; the proxy keeps 150 000 (Lasna) to 200 000 (Sepolia) of it. See
    // SilenceWatch.CALLBACK_GAS for why 300 000 was too little on Sepolia.
    uint64 public constant CALLBACK_GAS = 1_000_000;

    uint256 public immutable originChainId;
    address public immutable origin;
    uint256 public immutable destinationChainId;
    address public immutable callback;

    constructor(uint256 originChainId_, address origin_, uint256 destinationChainId_, address callback_) payable {
        originChainId = originChainId_;
        origin = origin_;
        destinationChainId = destinationChainId_;
        callback = callback_;
        SYSTEM.subscribe(originChainId_, origin_, TICK_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.topic0 != TICK_TOPIC0 || log_.contractAddress != origin || log_.chainId != originChainId || log_.opCode != 3) {
            return;
        }
        SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0({
            chainId: destinationChainId,
            recipient: callback,
            gasLimit: CALLBACK_GAS,
            // the first argument is a placeholder: the network overwrites it with this contract's address
            payload: abi.encodeWithSignature("onTick(address,uint256,uint256)", address(0), log_.topic2, log_.blockNumber)
        }));
    }

    /// Settles a debt from this contract's balance (a contract in debt is silently skipped).
    function coverDebt() external {
        _coverDebt();
    }
}
