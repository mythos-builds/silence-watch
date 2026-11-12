// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm, stdError } from "forge-std/Test.sol";
import { DemoToken } from "../src/DemoToken.sol";

contract DemoTokenTest is Test {
    address constant OWNER = address(0xA11CE);
    address constant VAULT = address(0x7A017);
    address constant KID = address(0xB0B);
    uint256 constant SUPPLY = 1000 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    DemoToken token;

    function setUp() public {
        token = new DemoToken(OWNER, SUPPLY);
    }

    function test_mintsTheWholeSupplyToTheOwnerAtDeploy() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), OWNER, SUPPLY);
        DemoToken t = new DemoToken(OWNER, SUPPLY);
        assertEq(t.totalSupply(), SUPPLY);
        assertEq(t.balanceOf(OWNER), SUPPLY);
        assertEq(t.balanceOf(address(this)), 0, "nothing to the deployer");
        assertEq(t.decimals(), 18);
        assertEq(t.symbol(), "DEMO");
    }

    function test_transferMovesTheBalance() public {
        vm.expectEmit(address(token));
        emit Transfer(OWNER, KID, 10);
        vm.prank(OWNER);
        assertTrue(token.transfer(KID, 10));
        assertEq(token.balanceOf(OWNER), SUPPLY - 10);
        assertEq(token.balanceOf(KID), 10);
    }

    function test_transferRevertsPastTheBalance() public {
        vm.prank(OWNER);
        token.transfer(KID, 10);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(KID);
        token.transfer(OWNER, 11);
    }

    function test_approveSetsTheAllowance() public {
        vm.expectEmit(address(token));
        emit Approval(OWNER, VAULT, 300);
        vm.prank(OWNER);
        assertTrue(token.approve(VAULT, 300));
        assertEq(token.allowance(OWNER, VAULT), 300);
        assertEq(token.allowance(VAULT, OWNER), 0);
    }

    function test_transferFromSpendsTheAllowance() public {
        vm.prank(OWNER);
        token.approve(VAULT, 300);
        vm.recordLogs();
        vm.prank(VAULT);
        assertTrue(token.transferFrom(OWNER, KID, 200));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "one Transfer and no Approval");
        assertEq(logs[0].topics[0], Transfer.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(OWNER))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(KID))));
        assertEq(abi.decode(logs[0].data, (uint256)), 200);
        assertEq(token.allowance(OWNER, VAULT), 100);
        assertEq(token.balanceOf(OWNER), SUPPLY - 200);
        assertEq(token.balanceOf(KID), 200);
    }

    function test_transferFromRevertsPastTheAllowanceOrTheBalance() public {
        vm.prank(OWNER);
        token.approve(VAULT, 300);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(VAULT);
        token.transferFrom(OWNER, KID, 301);
        vm.prank(OWNER);
        token.approve(VAULT, type(uint256).max);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(VAULT);
        token.transferFrom(OWNER, KID, SUPPLY + 1);
        vm.expectRevert(stdError.arithmeticError);
        token.transferFrom(OWNER, KID, 1); // this caller has no allowance
        assertEq(token.balanceOf(OWNER), SUPPLY);
    }
}
