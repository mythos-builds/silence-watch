// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { Origin } from "../src/Origin.sol";
import { LoopReactive } from "../src/LoopReactive.sol";
import { LoopCallback } from "../src/LoopCallback.sol";
import { MockSystem } from "./MockSystem.sol";

/// The whole loop on one simulated Lasna: Tick → react() → callback request → onTick().
contract LoopTest is Test {
    address payable constant SYS = payable(0x8888888888888888888888888888888888888888);
    uint256 constant LASNA = 5318007;
    uint256 constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    // what the Lasna proxy keeps back before forwarding (_extraGas + _maxChargeGas, read 2026-11-11)
    uint256 constant PROXY_RESERVE = 150_000;

    MockSystem sys;
    Origin origin;
    LoopCallback cb;
    LoopReactive rc;

    function setUp() public {
        vm.chainId(LASNA);
        vm.etch(SYS, address(new MockSystem()).code);
        sys = MockSystem(SYS);
        origin = new Origin();
        // the callback must name the reactive contract, which needs the callback: predict its address
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        cb = new LoopCallback(IPayable(SYS), predicted);
        rc = new LoopReactive(LASNA, address(origin), LASNA, address(cb));
        assertEq(address(rc), predicted, "address prediction");
    }

    /// Plays the network once: matching logs go to react(), then the callback requests are delivered.
    function _relay(Vm.Log[] memory logs_) internal returns (uint256 delivered_) {
        MockSystem.Sub[] memory subs = sys.subs();
        for (uint256 i; i < logs_.length; i++) {
            Vm.Log memory l = logs_[i];
            for (uint256 s; s < subs.length; s++) {
                if (subs[s].chainId != block.chainid || subs[s].origin != l.emitter) continue;
                if (subs[s].topic0 != REACTIVE_IGNORE && subs[s].topic0 != uint256(l.topics[0])) continue;
                uint256[4] memory t;
                for (uint256 k; k < l.topics.length; k++) t[k] = uint256(l.topics[k]);
                IReactive.LogRecord memory rec = IReactive.LogRecord({
                    chainId: block.chainid, contractAddress: l.emitter,
                    topic0: t[0], topic1: t[1], topic2: t[2], topic3: t[3],
                    data: l.data, blockNumber: block.number, opCode: l.topics.length,
                    blockHash: 0, txHash: 0, logIndex: i
                });
                vm.prank(SYS);
                IReactive(payable(subs[s].subscriber)).react(rec);
            }
        }
        MockSystem.Req[] memory reqs = sys.takeRequests();
        for (uint256 r; r < reqs.length; r++) {
            assertEq(reqs[r].chainId, block.chainid, "destination chain");
            bytes memory p = reqs[r].payload;
            address requester = reqs[r].requester;
            // the network overwrites the first argument with the reactive contract that asked
            assembly { mstore(add(p, 36), requester) }
            vm.prank(SYS);
            (bool ok, bytes memory err) = reqs[r].recipient.call{ gas: reqs[r].gasLimit - PROXY_RESERVE }(p);
            assertTrue(ok, string(err));
            delivered_++;
        }
    }

    function test_fullLoop() public {
        assertEq(sys.subs().length, 1, "one subscription");
        vm.recordLogs();
        origin.tick(42);
        assertEq(_relay(vm.getRecordedLogs()), 1, "one callback");
        assertEq(cb.handled(), 1);
        assertEq(cb.lastValue(), 42);
    }

    function test_twoTicksTwoCallbacks() public {
        vm.recordLogs();
        origin.tick(1);
        origin.tick(2);
        assertEq(_relay(vm.getRecordedLogs()), 2);
        assertEq(cb.lastValue(), 2);
    }

    function test_otherOriginIgnored() public {
        Origin other = new Origin();
        vm.recordLogs();
        other.tick(7);
        assertEq(_relay(vm.getRecordedLogs()), 0);
        assertEq(cb.handled(), 0);
    }

    function test_reactRejectsAnyoneButSystem() public {
        IReactive.LogRecord memory rec;
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYS));
        rc.react(rec);
    }

    function test_callbackRejectsDirectCall() public {
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYS));
        cb.onTick(address(rc), 1, 1);
    }

    function test_callbackRejectsAnotherReactive() public {
        vm.prank(SYS);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, address(0xBEEF), address(rc)));
        cb.onTick(address(0xBEEF), 1, 1);
    }
}
