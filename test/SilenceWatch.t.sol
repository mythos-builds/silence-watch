// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISubscriptionService } from "@reactive/src/interfaces/ISubscriptionService.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { CheckIn } from "../src/CheckIn.sol";
import { SilenceWatch } from "../src/SilenceWatch.sol";
import { MockSystem } from "./MockSystem.sol";

/// Idea A's clock on a simulated Lasna: the test plays the network and hands react() the logs directly.
contract SilenceWatchTest is Test {
    address payable constant SYS = payable(0x8888888888888888888888888888888888888888);
    address constant CRON = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant LASNA = 5318007;
    uint256 constant SEPOLIA = 11155111;
    uint256 constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    // Cron10000, about every 3 hours (docs, 2026-11-11)
    uint256 constant CRON10000 = 0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56;
    uint256 constant SILENCE = 30 days;
    uint256 constant GRACE = 7 days;
    // Lasna, read 2026-11-12: 100 gwei, coefficient 1000/1000, surcharge 100 000 gas, a block every ~1.065 s
    uint256 constant GWEI100 = 100 gwei;
    uint256 constant GAP = 10_647; // Cron10000 at that block time
    address constant OWNER = address(0xA11CE);
    address constant VAULT = address(0x5AFE);
    address constant SEPOLIA_CHECKIN = address(0xC0FFEE);

    MockSystem sys;
    CheckIn checkIn;
    SilenceWatch sw;

    function setUp() public {
        vm.chainId(LASNA);
        vm.warp(1_800_000_000);
        vm.etch(SYS, address(new MockSystem()).code);
        sys = MockSystem(SYS);
        sys.setFees(1000, 100_000);
        checkIn = new CheckIn(OWNER);
        SilenceWatch.Source[] memory src = new SilenceWatch.Source[](2);
        src[0] = SilenceWatch.Source(LASNA, address(checkIn));
        src[1] = SilenceWatch.Source(SEPOLIA, SEPOLIA_CHECKIN);
        sw = new SilenceWatch(OWNER, CRON10000, SILENCE, GRACE, src, LASNA, VAULT);
    }

    function _log(uint256 chainId_, address contract_, uint256 topic0_, uint256 topic1_)
        internal
        view
        returns (IReactive.LogRecord memory rec_)
    {
        rec_ = IReactive.LogRecord({
            chainId: chainId_, contractAddress: contract_,
            topic0: topic0_, topic1: topic1_, topic2: 0, topic3: 0,
            data: "", blockNumber: block.number, opCode: 2,
            blockHash: 0, txHash: 0, logIndex: 0
        });
    }

    function _react(IReactive.LogRecord memory rec_) internal {
        vm.prank(SYS);
        sw.react(rec_);
    }

    function _tick() internal {
        _react(_log(LASNA, CRON, CRON10000, 0));
    }

    function _sign(uint256 chainId_, address source_) internal {
        _react(_log(chainId_, source_, sw.ALIVE_TOPIC0(), uint256(uint160(OWNER))));
    }

    /// The callback requests made since the last call, as their function selectors.
    function _requested() internal returns (bytes4[] memory sel_) {
        MockSystem.Req[] memory reqs = sys.takeRequests();
        sel_ = new bytes4[](reqs.length);
        for (uint256 i; i < reqs.length; i++) {
            assertEq(reqs[i].chainId, LASNA, "vault chain");
            assertEq(reqs[i].recipient, VAULT, "vault");
            assertEq(reqs[i].gasLimit, sw.CALLBACK_GAS(), "gas");
            bytes memory p = reqs[i].payload;
            address placeholder;
            assembly { placeholder := mload(add(p, 36)) }
            assertEq(placeholder, address(0), "first argument left for the network");
            sel_[i] = bytes4(p);
        }
    }

    function _warn() internal {
        vm.warp(block.timestamp + SILENCE);
        _tick();
        assertEq(uint256(sw.stage()), uint256(SilenceWatch.Stage.Warning));
        sys.takeRequests();
    }

    function test_subscribesCronAndEachSource() public view {
        MockSystem.Sub[] memory s = sys.subs();
        assertEq(s.length, 3);
        assertEq(s[0].chainId, LASNA);
        assertEq(s[0].origin, CRON);
        assertEq(s[0].topic0, CRON10000);
        assertEq(s[1].origin, address(checkIn));
        assertEq(s[2].chainId, SEPOLIA);
        assertEq(s[2].origin, SEPOLIA_CHECKIN);
        assertEq(s[2].topic0, sw.ALIVE_TOPIC0());
    }

    function test_quietBeforeSilence() public {
        vm.warp(block.timestamp + SILENCE - 1);
        _tick();
        assertEq(uint256(sw.stage()), uint256(SilenceWatch.Stage.Armed));
        assertEq(_requested().length, 0);
    }

    function test_warnsAfterSilence() public {
        vm.warp(block.timestamp + SILENCE);
        _tick();
        assertEq(uint256(sw.stage()), uint256(SilenceWatch.Stage.Warning));
        assertEq(sw.warnedAt(), block.timestamp);
        bytes4[] memory sel = _requested();
        assertEq(sel.length, 1);
        assertEq(sel[0], bytes4(keccak256("onWarn(address,uint256)")));
    }

    function test_signFromEitherChainResetsTheClock() public {
        vm.warp(block.timestamp + SILENCE - 1);
        _sign(SEPOLIA, SEPOLIA_CHECKIN);
        vm.warp(block.timestamp + SILENCE - 1);
        _sign(LASNA, address(checkIn));
        vm.warp(block.timestamp + SILENCE - 1);
        _tick();
        assertEq(uint256(sw.stage()), uint256(SilenceWatch.Stage.Armed));
        assertEq(_requested().length, 0);
    }

    function test_signDuringGraceCancels() public {
        _warn();
        vm.warp(block.timestamp + GRACE - 1);
        _sign(SEPOLIA, SEPOLIA_CHECKIN);
        assertEq(uint256(sw.stage()), uint256(SilenceWatch.Stage.Armed));
        bytes4[] memory sel = _requested();
        assertEq(sel.length, 1);
        assertEq(sel[0], bytes4(keccak256("onCancel(address,uint256)")));
        // the old warning no longer counts: a tick past its grace end releases nothing
        vm.warp(block.timestamp + 2);
        _tick();
        assertEq(uint256(sw.stage()), uint256(SilenceWatch.Stage.Armed));
        assertEq(_requested().length, 0);
    }

    function test_releasesAfterGraceAndStopsTheTicks() public {
        _warn();
        vm.warp(block.timestamp + GRACE - 1);
        _tick();
        assertEq(uint256(sw.stage()), uint256(SilenceWatch.Stage.Warning), "not before the grace ends");
        vm.warp(block.timestamp + 1);
        vm.expectCall(
            SYS,
            abi.encodeCall(ISubscriptionService.unsubscribe, (LASNA, CRON, CRON10000, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE))
        );
        _tick();
        assertEq(uint256(sw.stage()), uint256(SilenceWatch.Stage.Released));
        bytes4[] memory sel = _requested();
        assertEq(sel.length, 1);
        assertEq(sel[0], bytes4(keccak256("onRelease(address,uint256)")));
    }

    function test_nothingAfterRelease() public {
        _warn();
        vm.warp(block.timestamp + GRACE);
        _tick();
        sys.takeRequests();
        vm.warp(block.timestamp + 1 days);
        _tick();
        _sign(LASNA, address(checkIn));
        assertEq(uint256(sw.stage()), uint256(SilenceWatch.Stage.Released));
        assertEq(_requested().length, 0);
    }

    /// After the release a sign changes nothing, and each source's first one drops that source: its later signs would
    /// only bill us.
    function test_signAfterReleaseDropsThatSource() public {
        _warn();
        vm.warp(block.timestamp + GRACE);
        _tick();
        uint256 last = sw.lastSign();
        vm.warp(block.timestamp + 1 days);
        vm.expectCall(
            SYS,
            abi.encodeCall(
                ISubscriptionService.unsubscribe,
                (SEPOLIA, SEPOLIA_CHECKIN, sw.ALIVE_TOPIC0(), uint256(uint160(OWNER)), REACTIVE_IGNORE, REACTIVE_IGNORE)
            )
        );
        _sign(SEPOLIA, SEPOLIA_CHECKIN);
        assertEq(sw.lastSign(), last, "too late to count");
        assertEq(uint256(sw.stage()), uint256(SilenceWatch.Stage.Released));
    }

    function test_signsBeforeReleaseKeepTheirSources() public {
        vm.expectCall(SYS, abi.encodeWithSelector(ISubscriptionService.unsubscribe.selector), 0);
        _sign(LASNA, address(checkIn));
        _warn();
        _sign(SEPOLIA, SEPOLIA_CHECKIN);
        assertEq(uint256(sw.stage()), uint256(SilenceWatch.Stage.Armed), "the sign cancelled the warning");
    }

    /// Alive-shaped logs that must not count: they would hold the release back forever (and each one bills us).
    function test_fakeSignsIgnored() public {
        uint256 start = sw.lastSign();
        uint256 alive = sw.ALIVE_TOPIC0();
        uint256 owner = uint256(uint160(OWNER));
        vm.warp(block.timestamp + 1 days);
        _react(_log(LASNA, address(0xBAD), alive, owner)); // a contract we never named
        _react(_log(SEPOLIA, address(checkIn), alive, owner)); // our contract's address, on the wrong chain
        _react(_log(LASNA, address(checkIn), alive, uint256(uint160(address(0xB0B))))); // someone else's sign
        _react(_log(LASNA, address(checkIn), uint256(keccak256("Transfer(address,address,uint256)")), owner));
        assertEq(sw.lastSign(), start, "clock untouched");
        // a fake Cron from anywhere else moves nothing either
        vm.warp(start + SILENCE);
        _react(_log(LASNA, address(0xBAD), CRON10000, 0));
        _react(_log(SEPOLIA, CRON, CRON10000, 0));
        assertEq(uint256(sw.stage()), uint256(SilenceWatch.Stage.Armed));
        assertEq(_requested().length, 0);
        assertEq(sw.lastTick(), 0, "fakes and signs measure nothing");
        // and the real silence still counts from the start
        _tick();
        assertEq(uint256(sw.stage()), uint256(SilenceWatch.Stage.Warning));
    }

    /// The real CheckIn's log, as the network would deliver it, matches what SilenceWatch expects.
    function test_realCheckInLogCounts() public {
        vm.warp(block.timestamp + 10 days);
        vm.recordLogs();
        vm.prank(OWNER);
        checkIn.checkIn();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        IReactive.LogRecord memory rec = _log(LASNA, logs[0].emitter, uint256(logs[0].topics[0]), uint256(logs[0].topics[1]));
        _react(rec);
        assertEq(sw.lastSign(), block.timestamp);
        assertEq(checkIn.last(), block.timestamp);
    }

    function test_checkInOnlyOwner() public {
        vm.expectRevert("not owner");
        checkIn.checkIn();
    }

    function test_reactRejectsAnyoneButSystem() public {
        IReactive.LogRecord memory rec;
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYS));
        sw.react(rec);
    }

    /// Two real ticks at Lasna's price; fundedUntil() must not drift between ticks, since nothing is billed then.
    function _twoTicks(uint256 balance_) internal returns (uint256 last_) {
        vm.deal(address(sw), balance_);
        vm.txGasPrice(GWEI100);
        vm.fee(GWEI100);
        _tick();
        assertEq(sw.fundedUntil(), 0, "unknown after one tick");
        vm.warp(block.timestamp + GAP);
        _tick();
        last_ = block.timestamp;
        vm.warp(block.timestamp + 1 hours);
    }

    function test_fundedUntilFromMeasuredTicks() public {
        uint256 last = _twoTicks(2 ether);
        assertEq(sw.lastTick(), last);
        assertEq(sw.tickEvery(), GAP);
        uint256 fee = GWEI100 * (sw.TICK_GAS() + 100_000);
        assertEq(sw.tickFee(), fee);
        assertEq(sw.fundedUntil(), last + (2 ether / fee) * GAP);
    }

    /// Foundry's default gas price and base fee are 0: two ticks but no price gives 0, not a division by zero.
    function test_fundedUntilUnknownWithoutPrice() public {
        _tick();
        vm.warp(block.timestamp + GAP);
        _tick();
        assertEq(sw.tickEvery(), GAP);
        assertEq(sw.fundedUntil(), 0);
    }

    /// The coefficient and the surcharge are read live: the system's owner can change them at any time.
    function test_tickFeeReadsTheSystemSettings() public {
        _twoTicks(1 ether);
        sys.setFees(2000, 150_000);
        assertEq(sw.tickFee(), GWEI100 * 2 * (sw.TICK_GAS() + 150_000));
    }

    /// Reserves prepaid at the system contract count with the balance; a debt is paid from them first, and once it
    /// eats them all, the last tick was the last one paid for.
    function test_fundedUntilCountsReservesAndDebt() public {
        uint256 last = _twoTicks(2 ether);
        uint256 fee = sw.tickFee();
        sys.setReserves(1 ether);
        assertEq(sw.fundedUntil(), last + (3 ether / fee) * GAP);
        sys.setReserves(0);
        sys.setDebt(0.5 ether);
        assertEq(sw.fundedUntil(), last + (1.5 ether / fee) * GAP);
        sys.setDebt(3 ether);
        assertEq(sw.fundedUntil(), last);
    }

    /// The fee's p_base: the greater of the transaction's gas price and the block's base fee.
    function test_tickPriceIsTheHigherOfGasPriceAndBaseFee() public {
        vm.txGasPrice(150 gwei);
        vm.fee(100 gwei);
        _tick();
        assertEq(sw.tickPrice(), 150 gwei);
        vm.txGasPrice(50 gwei);
        vm.fee(120 gwei);
        _tick();
        assertEq(sw.tickPrice(), 120 gwei);
    }

    function test_rejectsEmptyConfig() public {
        SilenceWatch.Source[] memory none = new SilenceWatch.Source[](0);
        vm.expectRevert("config");
        new SilenceWatch(OWNER, CRON10000, SILENCE, GRACE, none, LASNA, VAULT);
    }
}
