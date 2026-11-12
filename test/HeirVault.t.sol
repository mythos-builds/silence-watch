// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { CheckIn } from "../src/CheckIn.sol";
import { SilenceWatch } from "../src/SilenceWatch.sol";
import { HeirVault, ICheckIn } from "../src/HeirVault.sol";
import { DemoToken } from "../src/DemoToken.sol";
import { MockSystem } from "./MockSystem.sol";

/// A plain ERC-20 with two bad habits on demand: return nothing (USDT style) or return false.
contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public noReturn;
    bool public returnsFalse;

    function setMode(bool noReturn_, bool returnsFalse_) external {
        noReturn = noReturn_;
        returnsFalse = returnsFalse_;
    }

    function mint(address to_, uint256 amount_) external {
        balanceOf[to_] += amount_;
    }

    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;
        return true;
    }

    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool) {
        if (returnsFalse) return false;
        require(allowance[from_][msg.sender] >= amount_ && balanceOf[from_] >= amount_, "token");
        allowance[from_][msg.sender] -= amount_;
        balanceOf[from_] -= amount_;
        balanceOf[to_] += amount_;
        if (noReturn) assembly { return(0, 0) }
        return true;
    }
}

contract HeirVaultTest is Test {
    address payable constant SYS = payable(0x8888888888888888888888888888888888888888);
    address constant CRON = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant LASNA = 5318007;
    uint256 constant CRON10000 = 0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56;
    uint256 constant SILENCE = 30 days;
    uint256 constant GRACE = 7 days;
    address constant OWNER = address(0xA11CE);
    address constant KID1 = address(0xB0B);
    address constant KID2 = address(0xCA7);

    MockSystem sys;
    CheckIn checkIn;
    SilenceWatch sw;
    HeirVault vault;
    MockToken token;

    function setUp() public {
        vm.chainId(LASNA);
        vm.warp(1_800_000_000);
        vm.etch(SYS, address(new MockSystem()).code);
        sys = MockSystem(SYS);
        checkIn = new CheckIn(OWNER);
        // the watch and the vault name each other: the vault goes first, naming the address the watch will get next
        address watchAt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        HeirVault.Heir[] memory h = new HeirVault.Heir[](2);
        h[0] = HeirVault.Heir(KID1, 2);
        h[1] = HeirVault.Heir(KID2, 1);
        vault = new HeirVault(IPayable(SYS), watchAt, ICheckIn(address(checkIn)), SILENCE + GRACE, h);
        SilenceWatch.Source[] memory src = new SilenceWatch.Source[](1);
        src[0] = SilenceWatch.Source(LASNA, address(checkIn));
        sw = new SilenceWatch(OWNER, CRON10000, SILENCE, GRACE, src, LASNA, address(vault));
        assertEq(address(sw), watchAt, "predicted watch address");
        token = new MockToken();
        token.mint(OWNER, 3000);
        vm.prank(OWNER);
        token.approve(address(vault), type(uint256).max);
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

    function _tick() internal {
        vm.prank(SYS);
        sw.react(_log(LASNA, CRON, CRON10000, 0));
    }

    /// Plays the network: hands each pending callback to its recipient as the proxy, with the requester written into
    /// the first argument and only the gas the proxy forwards.
    function _deliver() internal {
        MockSystem.Req[] memory reqs = sys.takeRequests();
        for (uint256 i; i < reqs.length; i++) {
            bytes memory p = reqs[i].payload;
            address requester = reqs[i].requester;
            assembly { mstore(add(p, 36), requester) }
            vm.prank(SYS);
            (bool ok,) = reqs[i].recipient.call{ gas: reqs[i].gasLimit - 150_000 }(p);
            assertTrue(ok, "callback failed");
        }
    }

    function _release() internal {
        vm.prank(SYS);
        vault.onRelease(address(sw), block.timestamp);
    }

    function _released() internal {
        vm.warp(block.timestamp + SILENCE + GRACE);
        _release();
        assertEq(uint256(vault.stage()), uint256(HeirVault.Stage.Released));
    }

    function test_fullLoopReleasesAndPaysByShare() public {
        vm.warp(block.timestamp + SILENCE);
        _tick();
        _deliver();
        assertEq(uint256(vault.stage()), uint256(HeirVault.Stage.Warning));
        vm.warp(block.timestamp + GRACE);
        _tick();
        _deliver();
        assertEq(uint256(vault.stage()), uint256(HeirVault.Stage.Released));
        vm.prank(address(0xD00D)); // anyone may start the payout
        vault.distribute(address(token));
        assertEq(token.balanceOf(KID1), 2000);
        assertEq(token.balanceOf(KID2), 1000);
        assertEq(token.balanceOf(OWNER), 0);
    }

    function test_signDuringGraceCancelsAtTheVault() public {
        vm.warp(block.timestamp + SILENCE);
        _tick();
        _deliver();
        vm.prank(OWNER);
        checkIn.checkIn();
        IReactive.LogRecord memory alive = _log(LASNA, address(checkIn), sw.ALIVE_TOPIC0(), uint256(uint160(OWNER)));
        vm.prank(SYS); // the network carries his Alive log to the watch
        sw.react(alive);
        _deliver();
        assertEq(uint256(vault.stage()), uint256(HeirVault.Stage.Armed));
        vm.expectRevert("not released");
        vault.distribute(address(token));
    }

    /// He checked in here, but his Alive log never reached the watch: the watch releases, the vault refuses.
    function test_signStuckInTransitRefusesTheRelease() public {
        vm.warp(block.timestamp + SILENCE);
        _tick();
        _deliver();
        vm.warp(block.timestamp + GRACE - 1 hours);
        vm.prank(OWNER);
        checkIn.checkIn(); // its log is lost on the way
        uint256 signedAt = block.timestamp;
        vm.warp(block.timestamp + 1 hours);
        _tick();
        assertEq(uint256(sw.stage()), uint256(SilenceWatch.Stage.Released), "the watch was fooled");
        vm.recordLogs();
        _deliver();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(vault));
        assertEq(logs[0].topics[0], HeirVault.ReleaseRefused.selector);
        assertEq(logs[0].data, abi.encode(block.timestamp, signedAt));
        assertEq(uint256(vault.stage()), uint256(HeirVault.Stage.Refused));
        vm.expectRevert("not released");
        vault.distribute(address(token));
        assertEq(token.balanceOf(OWNER), 3000);
    }

    function test_refusesOneSecondShortOfQuiet() public {
        vm.prank(OWNER);
        checkIn.checkIn();
        vm.warp(block.timestamp + SILENCE + GRACE - 1);
        _release();
        assertEq(uint256(vault.stage()), uint256(HeirVault.Stage.Refused));
    }

    function test_releasesAtExactlyQuiet() public {
        vm.prank(OWNER);
        checkIn.checkIn();
        _released();
        assertEq(vault.releasedAt(), block.timestamp);
    }

    function test_onlyTheProxyCarryingTheWatch() public {
        vm.warp(block.timestamp + SILENCE + GRACE);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYS));
        vault.onRelease(address(sw), block.timestamp);
        vm.prank(SYS);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, address(0xBAD), address(sw)));
        vault.onRelease(address(0xBAD), block.timestamp);
        vm.prank(SYS);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, address(0xBAD), address(sw)));
        vault.onWarn(address(0xBAD), block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYS));
        vault.onCancel(address(sw), block.timestamp);
        assertEq(uint256(vault.stage()), uint256(HeirVault.Stage.Armed));
    }

    function test_releaseIsFinal() public {
        _released();
        uint256 at = vault.releasedAt();
        vm.warp(block.timestamp + 1 days);
        _release();
        vm.prank(SYS);
        vault.onWarn(address(sw), block.timestamp);
        vm.prank(SYS);
        vault.onCancel(address(sw), block.timestamp);
        assertEq(vault.releasedAt(), at);
        assertEq(uint256(vault.stage()), uint256(HeirVault.Stage.Released));
    }

    function test_movesTheSmallerOfAllowanceAndBalance() public {
        _released();
        vm.prank(OWNER);
        token.approve(address(vault), 300);
        vault.distribute(address(token));
        assertEq(token.balanceOf(KID1), 200);
        assertEq(token.balanceOf(KID2), 100);
        assertEq(token.balanceOf(OWNER), 2700);
    }

    function test_laterFundsGoToTheHeirsToo() public {
        _released();
        vault.distribute(address(token));
        token.mint(OWNER, 31);
        vault.distribute(address(token));
        assertEq(token.balanceOf(KID1), 2020);
        assertEq(token.balanceOf(KID2), 1011, "the last heir takes the dust");
        vm.expectRevert("nothing to move");
        vault.distribute(address(token));
    }

    /// The demo video's token, end to end: minted to the owner, an allowance to the vault, paid out by share.
    function test_demoTokenPaysOutByShare() public {
        DemoToken demo = new DemoToken(OWNER, 1000 ether);
        vm.prank(OWNER);
        demo.approve(address(vault), 1000 ether);
        _released();
        vault.distribute(address(demo));
        assertEq(demo.balanceOf(KID1), 666666666666666666666);
        assertEq(demo.balanceOf(KID2), 333333333333333333334, "the last heir takes the dust");
        assertEq(demo.balanceOf(OWNER), 0);
        assertEq(demo.allowance(OWNER, address(vault)), 0);
    }

    function test_noReturnTokenWorksFalseStopsAll() public {
        _released();
        token.setMode(true, false);
        vault.distribute(address(token));
        assertEq(token.balanceOf(KID1), 2000);
        token.mint(OWNER, 30);
        token.setMode(false, true);
        vm.expectRevert("transfer failed");
        vault.distribute(address(token));
        assertEq(token.balanceOf(OWNER), 30);
    }

    /// Deploys through an external call: with this Foundry setup a reverting `new` under expectRevert ends the test
    /// function at once, so the later checks would never run.
    function deployVault(uint256 quiet_, HeirVault.Heir[] memory heirs_) external returns (HeirVault) {
        return new HeirVault(IPayable(SYS), address(sw), ICheckIn(address(checkIn)), quiet_, heirs_);
    }

    function _rejects(uint256 quiet_, HeirVault.Heir[] memory heirs_, string memory why_) internal {
        try this.deployVault(quiet_, heirs_) {
            assertTrue(false, "a bad config was deployed");
        } catch (bytes memory err_) {
            assertEq(err_, abi.encodeWithSignature("Error(string)", why_), why_);
        }
    }

    function test_rejectsBadConfig() public {
        _rejects(1, new HeirVault.Heir[](0), "config");
        HeirVault.Heir[] memory h = new HeirVault.Heir[](1);
        h[0] = HeirVault.Heir(KID1, 1);
        _rejects(0, h, "config");
        h[0] = HeirVault.Heir(OWNER, 1);
        _rejects(1, h, "heir");
        h[0] = HeirVault.Heir(address(0), 1);
        _rejects(1, h, "heir");
        h[0] = HeirVault.Heir(KID1, 0);
        _rejects(1, h, "heir");
        h[0] = HeirVault.Heir(KID1, 1);
        assertEq(this.deployVault(1, h).owner(), OWNER, "owner comes from the CheckIn");
    }
}
