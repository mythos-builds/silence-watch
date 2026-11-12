// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { CheckIn } from "../src/CheckIn.sol";
import { SilenceWatch } from "../src/SilenceWatch.sol";
import { HeirVault, ICheckIn } from "../src/HeirVault.sol";
import { DemoToken } from "../src/DemoToken.sol";

/// Deploys idea A on Lasna, one deployer: CheckIn, then HeirVault, then SilenceWatch. The watch and the vault name
/// each other, so the vault goes first with the address the watch will get next (deployer nonce + 1).
/// Env: HEIRS + SHARES (comma lists, required) · OWNER (default: the deployer) · CRON = 10000 (about 3 h, the real
/// run) or 100 (about 2 min, the demo video) · SILENCE, GRACE in seconds (default 30 days, 7 days) · SOURCE_CHAINS +
/// SOURCE_CHECKINS (optional comma lists: CheckIns already deployed on other chains) · FUND_WATCH, FUND_VAULT in wei
/// (the watch pays for its ticks, the vault for the callbacks it receives; either one in debt stops silently) ·
/// DEMO_TOKEN = 1 (the demo video) also deploys DemoToken, its whole supply minted to the owner, and approves the vault
/// for all of it when the owner is the deployer (otherwise the owner approves it himself).
contract DeployHeir is Script {
    address payable constant SYS = payable(0x8888888888888888888888888888888888888888);
    // dev.reactive.network/reactive-contracts « Subscribing To CRON Events »; = keccak256("Cron100(uint256)") and so on
    uint256 constant CRON100 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 constant CRON10000 = 0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56;
    uint256 constant DEMO_SUPPLY = 1000 ether;

    struct Config {
        address owner;
        uint256 cronTopic;
        uint256 silence;
        uint256 grace;
        HeirVault.Heir[] heirs;
        SilenceWatch.Source[] extra;
        uint256 fundWatch;
        uint256 fundVault;
        bool demoToken;
    }

    function run() external virtual {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        Config memory c = _config(deployer);
        CheckIn checkIn = new CheckIn(c.owner);
        address watchAt = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        HeirVault vault = new HeirVault{ value: c.fundVault }(
            IPayable(SYS), watchAt, ICheckIn(address(checkIn)), c.silence + c.grace, c.heirs
        );
        SilenceWatch.Source[] memory src = new SilenceWatch.Source[](c.extra.length + 1);
        src[0] = SilenceWatch.Source(block.chainid, address(checkIn));
        for (uint256 i; i < c.extra.length; i++) {
            src[i + 1] = c.extra[i];
        }
        SilenceWatch watch = new SilenceWatch{ value: c.fundWatch }(
            c.owner, c.cronTopic, c.silence, c.grace, src, block.chainid, address(vault)
        );
        // after the watch, so the three contracts above keep the nonces the vault's prediction counted on
        DemoToken demo;
        if (c.demoToken) {
            demo = new DemoToken(c.owner, DEMO_SUPPLY);
            if (c.owner == deployer) demo.approve(address(vault), DEMO_SUPPLY);
        }
        vm.stopBroadcast();
        require(address(watch) == watchAt, "watch address prediction failed");
        console.log("owner   ", c.owner);
        console.log("checkIn ", address(checkIn));
        console.log("vault   ", address(vault));
        console.log("watch   ", address(watch));
        console.log("cron    ", c.cronTopic == CRON10000 ? "Cron10000" : "Cron100");
        console.log("silence, grace (s)", c.silence, c.grace);
        console.log("sources, heirs", src.length, c.heirs.length);
        if (c.demoToken) {
            console.log("demo    ", address(demo));
            console.log(c.owner == deployer ? "demo: vault approved" : "demo: the owner must approve the vault");
        }
    }

    function _config(address deployer_) internal view returns (Config memory c) {
        c.owner = vm.envOr("OWNER", deployer_);
        uint256 cron = vm.envOr("CRON", uint256(10000));
        require(cron == 10000 || cron == 100, "CRON: 10000 or 100");
        c.cronTopic = cron == 10000 ? CRON10000 : CRON100;
        c.silence = vm.envOr("SILENCE", uint256(30 days));
        c.grace = vm.envOr("GRACE", uint256(7 days));
        address[] memory to = vm.envAddress("HEIRS", ",");
        uint256[] memory share = vm.envUint("SHARES", ",");
        require(to.length == share.length, "HEIRS and SHARES lengths differ");
        c.heirs = new HeirVault.Heir[](to.length);
        for (uint256 i; i < to.length; i++) {
            c.heirs[i] = HeirVault.Heir(to[i], share[i]);
        }
        uint256[] memory chains = vm.envOr("SOURCE_CHAINS", ",", new uint256[](0));
        address[] memory checkIns = vm.envOr("SOURCE_CHECKINS", ",", new address[](0));
        require(chains.length == checkIns.length, "SOURCE_CHAINS and SOURCE_CHECKINS lengths differ");
        c.extra = new SilenceWatch.Source[](chains.length);
        for (uint256 i; i < chains.length; i++) {
            c.extra[i] = SilenceWatch.Source(chains[i], checkIns[i]);
        }
        c.fundWatch = vm.envOr("FUND_WATCH", uint256(0));
        c.fundVault = vm.envOr("FUND_VAULT", uint256(0));
        uint256 demo = vm.envOr("DEMO_TOKEN", uint256(0));
        require(demo <= 1, "DEMO_TOKEN: 0 or 1");
        c.demoToken = demo == 1;
    }
}
