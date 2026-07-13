// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FxDesk} from "../src/FxDesk.sol";
import {PolicyVault} from "../src/PolicyVault.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract FxDeskTest is Test {
    FxDesk desk;
    PolicyVault vault;
    MockERC20 usdc;
    MockERC20 eurc;
    address agent = address(0xA9E17);

    function setUp() public {
        usdc = new MockERC20();
        eurc = new MockERC20();
        desk = new FxDesk(address(usdc), address(eurc));
        desk.setRate(855000); // 0.855 EURC / USDC

        vault = new PolicyVault(agent);
        vault.setToken(address(usdc), true);
        vault.setToken(address(eurc), true);
        vault.setTarget(address(desk), true);
        vault.setDailyCap(address(usdc), 100e6);
        vault.setDailyCap(address(eurc), 100e6);

        usdc.mint(address(vault), 20e6);
        eurc.mint(address(desk), 50e6);
    }

    function test_quoteBothDirections() public view {
        assertEq(desk.quote(address(usdc), 10e6), 8_550_000); // 10 USDC -> 8.55 EURC
        assertEq(desk.quote(address(eurc), 8_550_000), 10e6); // division exacte ici
    }

    function test_quoteRejectsUnknownToken() public {
        vm.expectRevert(FxDesk.BadPair.selector);
        desk.quote(address(0xDEAD), 1e6);
    }

    /// Le flow complet de rebalance : agent approuve le desk depuis le vault, puis règle le swap.
    function test_rebalanceViaVaultGuardrails() public {
        vm.startPrank(agent);
        vault.approveTarget(address(usdc), address(desk), 8e6);
        uint256 out = desk.swapFor(address(vault), address(usdc), 8e6);
        vm.stopPrank();

        assertEq(out, 6_840_000); // 8 * 0.855
        assertEq(usdc.balanceOf(address(vault)), 12e6);
        assertEq(eurc.balanceOf(address(vault)), 6_840_000);
        assertEq(usdc.balanceOf(address(desk)), 8e6);
    }

    function test_swapWithoutApprovalFails() public {
        vm.prank(agent);
        vm.expectRevert(bytes("allowance"));
        desk.swapFor(address(vault), address(usdc), 8e6);
    }

    function test_inventoryGuard() public {
        vm.startPrank(agent);
        vault.approveTarget(address(usdc), address(desk), 80e6);
        // 80 USDC -> 68.4 EURC > 50 en stock
        vm.expectRevert(abi.encodeWithSelector(FxDesk.InsufficientInventory.selector, 68_400_000, 50e6));
        desk.swapFor(address(vault), address(usdc), 80e6);
        vm.stopPrank();
    }

    function test_onlyOwnerSetsRateAndWithdraws() public {
        vm.prank(agent);
        vm.expectRevert(FxDesk.NotOwner.selector);
        desk.setRate(1);
        vm.prank(agent);
        vm.expectRevert(FxDesk.NotOwner.selector);
        desk.withdraw(address(eurc), agent, 1);
    }
}
