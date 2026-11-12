// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { console } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { CheckIn } from "../src/CheckIn.sol";
import { SilenceWatch } from "../src/SilenceWatch.sol";
import { HeirVault, ICheckIn } from "../src/HeirVault.sol";
import { DemoToken } from "../src/DemoToken.sol";
import { DeployHeir } from "./DeployHeir.s.sol";

/// Deploys idea A across two chains, one deployer: CheckIn, HeirVault (and DemoToken) on the home chain, where the
/// owner keeps his tokens; SilenceWatch on Reactive. The vault names the watch before it exists: the deployer's next
/// CREATE address on Reactive, read from that chain's nonce first, so send nothing else from that key on Reactive
/// until the script is done.
/// Env: as DeployHeir (FUND_VAULT is paid in the home chain's coin), plus HOME_RPC and REACTIVE_RPC · CALLBACK_PROXY
/// (the home chain's proxy; filled in for the testnets the docs list).
contract DeployHeirCross is DeployHeir {
    function run() external override {
        uint256 reactive = vm.createSelectFork(vm.envString("REACTIVE_RPC"));
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        vm.stopBroadcast();
        Config memory c = _config(deployer);
        address watchAt = vm.computeCreateAddress(deployer, vm.getNonce(deployer));

        vm.createSelectFork(vm.envString("HOME_RPC"));
        uint256 home = block.chainid;
        address proxy = vm.envOr("CALLBACK_PROXY", address(0));
        if (proxy == address(0)) proxy = _proxy(home);
        vm.startBroadcast();
        CheckIn checkIn = new CheckIn(c.owner);
        HeirVault vault = new HeirVault{ value: c.fundVault }(
            IPayable(payable(proxy)), watchAt, ICheckIn(address(checkIn)), c.silence + c.grace, c.heirs
        );
        DemoToken demo;
        if (c.demoToken) {
            demo = new DemoToken(c.owner, DEMO_SUPPLY);
            if (c.owner == deployer) demo.approve(address(vault), DEMO_SUPPLY);
        }
        vm.stopBroadcast();

        vm.selectFork(reactive);
        SilenceWatch.Source[] memory src = new SilenceWatch.Source[](c.extra.length + 1);
        src[0] = SilenceWatch.Source(home, address(checkIn));
        for (uint256 i; i < c.extra.length; i++) {
            src[i + 1] = c.extra[i];
        }
        vm.startBroadcast();
        SilenceWatch watch = new SilenceWatch{ value: c.fundWatch }(
            c.owner, c.cronTopic, c.silence, c.grace, src, home, address(vault)
        );
        vm.stopBroadcast();
        require(address(watch) == watchAt, "watch address prediction failed");
        console.log("home chain", home);
        console.log("owner   ", c.owner);
        console.log("checkIn ", address(checkIn));
        console.log("vault   ", address(vault));
        console.log("proxy   ", proxy);
        console.log("watch   ", address(watch), "(Reactive)");
        console.log("cron    ", c.cronTopic == CRON10000 ? "Cron10000" : "Cron100");
        console.log("silence, grace (s)", c.silence, c.grace);
        console.log("sources, heirs", src.length, c.heirs.length);
        if (c.demoToken) {
            console.log("demo    ", address(demo));
            console.log(c.owner == deployer ? "demo: vault approved" : "demo: the owner must approve the vault");
        }
    }

    /// The home chain's callback proxy (dev.reactive.network/origins-and-destinations, testnets, read 2026-11-12).
    function _proxy(uint256 chainId_) internal pure returns (address) {
        if (chainId_ == 11155111) return 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4; // Ethereum Sepolia
        if (chainId_ == 84532) return 0x476F44b11F5C942c58f4c8E3d0300E5710743585; // Base Sepolia
        if (chainId_ == 1301) return 0x775c9B990ADe401060B78D0e98684eEf8d2466C1; // Unichain Sepolia
        revert("CALLBACK_PROXY: unknown home chain");
    }
}
