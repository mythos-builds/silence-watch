// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { Origin } from "../src/Origin.sol";
import { LoopReactive } from "../src/LoopReactive.sol";
import { LoopCallback } from "../src/LoopCallback.sol";

/// Deploys the Lasna-only loop: Origin, LoopCallback, LoopReactive (same chain, same deployer).
/// FUND_WEI (optional) is sent to the reactive and the callback contract at deployment.
contract Deploy is Script {
    address payable constant SYS = payable(0x8888888888888888888888888888888888888888);

    function run() external {
        uint256 fund = vm.envOr("FUND_WEI", uint256(0));
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        Origin origin = new Origin();
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        LoopCallback cb = new LoopCallback{ value: fund }(IPayable(SYS), predicted);
        LoopReactive rc = new LoopReactive{ value: fund }(block.chainid, address(origin), block.chainid, address(cb));
        vm.stopBroadcast();
        require(address(rc) == predicted, "reactive address prediction failed");
        console.log("origin  ", address(origin));
        console.log("callback", address(cb));
        console.log("reactive", address(rc));
    }
}
