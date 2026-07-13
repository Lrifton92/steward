// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PolicyVault} from "../src/PolicyVault.sol";

contract MockERC20 {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name) {
        name = _name;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract PolicyVaultTest is Test {
    PolicyVault vault;
    MockERC20 usdc;
    MockERC20 eurc;

    address owner = address(this);
    address agent = address(0xA9E17);
    address payee = address(0xBEEF);
    address escrow = address(0xE5C60);
    address stranger = address(0xBAD);

    function setUp() public {
        vault = new PolicyVault(agent);
        usdc = new MockERC20("USDC");
        eurc = new MockERC20("EURC");
        usdc.mint(address(vault), 1_000e6);
        eurc.mint(address(vault), 1_000e6);

        vault.setToken(address(usdc), true);
        vault.setPayee(payee, true);
        vault.setTarget(escrow, true);
        vault.setDailyCap(address(usdc), 100e6);
    }

    // ---- roles ----

    function test_onlyAgentCanPay() public {
        vm.prank(stranger);
        vm.expectRevert(PolicyVault.NotAgent.selector);
        vault.pay(address(usdc), payee, 1e6, "x");

        vm.prank(owner);
        vm.expectRevert(PolicyVault.NotAgent.selector);
        vault.pay(address(usdc), payee, 1e6, "x");
    }

    function test_onlyOwnerCanSetPolicy() public {
        vm.prank(agent);
        vm.expectRevert(PolicyVault.NotOwner.selector);
        vault.setDailyCap(address(usdc), type(uint256).max);

        vm.prank(stranger);
        vm.expectRevert(PolicyVault.NotOwner.selector);
        vault.setPayee(stranger, true);
    }

    // ---- pay ----

    function test_payHappyPath() public {
        vm.prank(agent);
        vault.pay(address(usdc), payee, 40e6, "invoice-1");
        assertEq(usdc.balanceOf(payee), 40e6);
        assertEq(vault.remainingToday(address(usdc)), 60e6);
    }

    function test_payRejectsUnknownPayee() public {
        vm.prank(agent);
        vm.expectRevert(PolicyVault.PayeeNotAllowed.selector);
        vault.pay(address(usdc), stranger, 1e6, "x");
    }

    function test_payRejectsUnknownToken() public {
        vm.prank(agent);
        vm.expectRevert(PolicyVault.TokenNotAllowed.selector);
        vault.pay(address(eurc), payee, 1e6, "x");
    }

    // ---- daily cap ----

    function test_dailyCapEnforced() public {
        vm.startPrank(agent);
        vault.pay(address(usdc), payee, 80e6, "a");
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.DailyCapExceeded.selector, 30e6, 20e6));
        vault.pay(address(usdc), payee, 30e6, "b");
        vm.stopPrank();
    }

    function test_dailyCapResetsNextDay() public {
        vm.prank(agent);
        vault.pay(address(usdc), payee, 100e6, "a");
        assertEq(vault.remainingToday(address(usdc)), 0);

        vm.warp(block.timestamp + 1 days);
        assertEq(vault.remainingToday(address(usdc)), 100e6);
        vm.prank(agent);
        vault.pay(address(usdc), payee, 100e6, "b");
        assertEq(usdc.balanceOf(payee), 200e6);
    }

    function test_capsArePerToken() public {
        vault.setToken(address(eurc), true);
        vault.setDailyCap(address(eurc), 50e6);

        vm.startPrank(agent);
        vault.pay(address(usdc), payee, 100e6, "usdc-full");
        vault.pay(address(eurc), payee, 50e6, "eurc-full");
        vm.stopPrank();
        assertEq(vault.remainingToday(address(usdc)), 0);
        assertEq(vault.remainingToday(address(eurc)), 0);
    }

    function test_zeroCapBlocksAgent() public {
        vault.setToken(address(eurc), true); // no cap set => 0
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.DailyCapExceeded.selector, 1e6, 0));
        vault.pay(address(eurc), payee, 1e6, "x");
    }

    // ---- approveTarget ----

    function test_approveTargetHappyPath() public {
        vm.prank(agent);
        vault.approveTarget(address(usdc), escrow, 60e6);
        assertEq(usdc.allowance(address(vault), escrow), 60e6);
        assertEq(vault.remainingToday(address(usdc)), 40e6);
    }

    function test_approveTargetRejectsUnknownTarget() public {
        vm.prank(agent);
        vm.expectRevert(PolicyVault.TargetNotAllowed.selector);
        vault.approveTarget(address(usdc), stranger, 1e6);
    }

    function test_approveCountsAgainstCap() public {
        vm.startPrank(agent);
        vault.approveTarget(address(usdc), escrow, 80e6);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.DailyCapExceeded.selector, 30e6, 20e6));
        vault.pay(address(usdc), payee, 30e6, "x");
        vm.stopPrank();
    }

    // ---- owner escape hatch ----

    function test_ownerWithdrawIgnoresPolicy() public {
        // eurc is not even an allowed token, no cap — owner still withdraws freely
        vault.ownerWithdraw(address(eurc), owner, 1_000e6);
        assertEq(eurc.balanceOf(owner), 1_000e6);
    }

    function test_setOwnerTransfersControl() public {
        vault.setOwner(payee);
        vm.expectRevert(PolicyVault.NotOwner.selector);
        vault.setDailyCap(address(usdc), 1);
        vm.prank(payee);
        vault.setDailyCap(address(usdc), 1);
    }

    function test_setOwnerRejectsZeroAndStrangers() public {
        vm.expectRevert(bytes("zero owner"));
        vault.setOwner(address(0));
        vm.prank(stranger);
        vm.expectRevert(PolicyVault.NotOwner.selector);
        vault.setOwner(stranger);
    }

    function test_ownerWithdrawOnlyOwner() public {
        vm.prank(agent);
        vm.expectRevert(PolicyVault.NotOwner.selector);
        vault.ownerWithdraw(address(usdc), agent, 1e6);
    }
}
