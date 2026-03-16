// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentTreasury.sol";
import "../src/interfaces/IStETH.sol";
import "../src/interfaces/IWstETH.sol";

/// @dev Mock stETH with shares-based accounting (rebasing balances)
contract MockStETH {
    mapping(address => uint256) public sharesOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalPooled;
    uint256 public totalShares;

    constructor() {
        totalPooled = 1000 ether;
        totalShares = 1000 ether;
    }

    function balanceOf(address account) public view returns (uint256) {
        if (totalShares == 0) return 0;
        return (sharesOf[account] * totalPooled) / totalShares;
    }

    function submit(address) external payable returns (uint256) {
        uint256 shares = (msg.value * totalShares) / totalPooled;
        sharesOf[msg.sender] += shares;
        totalPooled += msg.value;
        totalShares += shares;
        return balanceOf(msg.sender) - (balanceOf(msg.sender) - msg.value); // simplify: returns ~msg.value
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 sharesToTransfer = (amount * totalShares) / totalPooled;
        require(sharesOf[msg.sender] >= sharesToTransfer, "insufficient");
        sharesOf[msg.sender] -= sharesToTransfer;
        sharesOf[to] += sharesToTransfer;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 sharesToTransfer = (amount * totalShares) / totalPooled;
        require(sharesOf[from] >= sharesToTransfer, "insufficient");
        require(allowance[from][msg.sender] >= amount, "not approved");
        sharesOf[from] -= sharesToTransfer;
        sharesOf[to] += sharesToTransfer;
        allowance[from][msg.sender] -= amount;
        return true;
    }

    /// @dev Simulate a rebase — increases totalPooled (everyone's balance grows)
    function simulateRebase(uint256 rewardETH) external {
        totalPooled += rewardETH;
    }
}

/// @dev Mock wstETH wrapping stETH
contract MockWstETH {
    MockStETH public steth;
    mapping(address => uint256) public balanceOf;

    constructor(address _steth) {
        steth = MockStETH(_steth);
    }

    function wrap(uint256 _stETHAmount) external returns (uint256) {
        uint256 wstETHAmount = getWstETHByStETH(_stETHAmount);
        steth.transferFrom(msg.sender, address(this), _stETHAmount);
        balanceOf[msg.sender] += wstETHAmount;
        return wstETHAmount;
    }

    function unwrap(uint256 _wstETHAmount) external returns (uint256) {
        uint256 stETHAmount = getStETHByWstETH(_wstETHAmount);
        require(balanceOf[msg.sender] >= _wstETHAmount, "insufficient wstETH");
        balanceOf[msg.sender] -= _wstETHAmount;
        steth.transfer(msg.sender, stETHAmount);
        return stETHAmount;
    }

    function getStETHByWstETH(uint256 _wstETHAmount) public view returns (uint256) {
        return (_wstETHAmount * steth.totalPooled()) / steth.totalShares();
    }

    function getWstETHByStETH(uint256 _stETHAmount) public view returns (uint256) {
        return (_stETHAmount * steth.totalShares()) / steth.totalPooled();
    }

    function stEthPerToken() external view returns (uint256) {
        return (steth.totalPooled() * 1e18) / steth.totalShares();
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract AgentTreasuryTest is Test {
    AgentTreasury public treasury;
    MockStETH public steth;
    MockWstETH public wsteth;

    address public owner = address(this);
    address public agent = address(0xA1);
    address public recipient1 = address(0xB1);
    address public recipient2 = address(0xB2);
    address public nobody = address(0xC1);

    function setUp() public {
        // Warp to a reasonable timestamp so cooldown math works
        vm.warp(10_000);

        steth = new MockStETH();
        wsteth = new MockWstETH(address(steth));

        treasury = new AgentTreasury(
            address(steth),
            address(wsteth),
            agent,
            1 ether,       // perTxCap: 1 stETH
            1 hours        // timeWindow: 1 hour
        );

        // Whitelist recipient1
        treasury.setRecipientWhitelist(recipient1, true);
    }

    // ========================
    // CONSTRUCTOR
    // ========================

    function test_constructor() public view {
        assertEq(treasury.owner(), owner);
        assertEq(treasury.agent(), agent);
        assertEq(treasury.perTxCap(), 1 ether);
        assertEq(treasury.timeWindow(), 1 hours);
        assertEq(address(treasury.stETH()), address(steth));
        assertEq(address(treasury.wstETH()), address(wsteth));
    }

    function test_constructor_revert_zeroAddress() public {
        vm.expectRevert(AgentTreasury.ZeroAddress.selector);
        new AgentTreasury(address(0), address(wsteth), agent, 1 ether, 1 hours);

        vm.expectRevert(AgentTreasury.ZeroAddress.selector);
        new AgentTreasury(address(steth), address(0), agent, 1 ether, 1 hours);

        vm.expectRevert(AgentTreasury.ZeroAddress.selector);
        new AgentTreasury(address(steth), address(wsteth), address(0), 1 ether, 1 hours);
    }

    // ========================
    // DEPOSIT
    // ========================

    function test_deposit() public {
        treasury.deposit{value: 10 ether}();

        assertGt(treasury.principalStETH(), 0);
        assertGt(treasury.wstETHBalance(), 0);
        assertEq(treasury.availableYield(), 0); // no yield yet
    }

    function test_deposit_multiple() public {
        treasury.deposit{value: 5 ether}();
        treasury.deposit{value: 5 ether}();

        assertGt(treasury.principalStETH(), 9 ether); // approximately 10, allowing rounding
    }

    function test_deposit_revert_notOwner() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        vm.expectRevert(AgentTreasury.OnlyOwner.selector);
        treasury.deposit{value: 1 ether}();
    }

    function test_deposit_revert_zeroAmount() public {
        vm.expectRevert(AgentTreasury.ZeroAmount.selector);
        treasury.deposit{value: 0}();
    }

    // ========================
    // YIELD ACCRUAL
    // ========================

    function test_yieldAccrues() public {
        treasury.deposit{value: 100 ether}();
        assertEq(treasury.availableYield(), 0);

        // Simulate a rebase (staking rewards)
        steth.simulateRebase(10 ether);

        uint256 yield = treasury.availableYield();
        assertGt(yield, 0);
    }

    function test_currentValueGrowsAfterRebase() public {
        treasury.deposit{value: 100 ether}();
        uint256 valueBefore = treasury.currentValueStETH();

        steth.simulateRebase(5 ether);

        uint256 valueAfter = treasury.currentValueStETH();
        assertGt(valueAfter, valueBefore);
    }

    // ========================
    // AGENT WITHDRAWAL
    // ========================

    function test_agentWithdraw() public {
        treasury.deposit{value: 100 ether}();

        // Simulate yield
        steth.simulateRebase(10 ether);
        uint256 yield = treasury.availableYield();
        assertGt(yield, 0);

        // Agent withdraws some yield (capped at perTxCap)
        uint256 withdrawAmount = yield > treasury.perTxCap() ? treasury.perTxCap() : yield;

        vm.prank(agent);
        treasury.agentWithdraw(recipient1, withdrawAmount);

        assertGt(steth.balanceOf(recipient1), 0);
        assertGt(treasury.totalYieldWithdrawn(), 0);
    }

    function test_agentWithdraw_revert_notAgent() public {
        treasury.deposit{value: 100 ether}();
        steth.simulateRebase(10 ether);

        vm.prank(nobody);
        vm.expectRevert(AgentTreasury.OnlyAgent.selector);
        treasury.agentWithdraw(recipient1, 0.1 ether);
    }

    function test_agentWithdraw_revert_notWhitelisted() public {
        treasury.deposit{value: 100 ether}();
        steth.simulateRebase(10 ether);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentTreasury.RecipientNotWhitelisted.selector, recipient2));
        treasury.agentWithdraw(recipient2, 0.1 ether);
    }

    function test_agentWithdraw_revert_exceedsPerTxCap() public {
        treasury.deposit{value: 100 ether}();
        steth.simulateRebase(10 ether);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentTreasury.ExceedsPerTxCap.selector, 2 ether, 1 ether));
        treasury.agentWithdraw(recipient1, 2 ether);
    }

    function test_agentWithdraw_revert_cooldown() public {
        treasury.deposit{value: 100 ether}();
        steth.simulateRebase(10 ether);

        // First withdrawal succeeds
        vm.prank(agent);
        treasury.agentWithdraw(recipient1, 0.1 ether);

        // Second withdrawal within cooldown fails
        vm.prank(agent);
        vm.expectRevert(); // CooldownNotElapsed
        treasury.agentWithdraw(recipient1, 0.1 ether);

        // After cooldown, it works
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(agent);
        treasury.agentWithdraw(recipient1, 0.1 ether);
    }

    function test_agentWithdraw_revert_insufficientYield() public {
        treasury.deposit{value: 100 ether}();

        // No rebase → no yield
        vm.prank(agent);
        vm.expectRevert(); // InsufficientYield
        treasury.agentWithdraw(recipient1, 0.1 ether);
    }

    function test_agentWithdraw_revert_zeroAmount() public {
        treasury.deposit{value: 100 ether}();
        steth.simulateRebase(10 ether);

        vm.prank(agent);
        vm.expectRevert(AgentTreasury.ZeroAmount.selector);
        treasury.agentWithdraw(recipient1, 0);
    }

    function test_agentCannotTouchPrincipal() public {
        treasury.deposit{value: 100 ether}();

        // Small rebase — only ~0.01 ETH yield
        steth.simulateRebase(0.1 ether);

        uint256 yield = treasury.availableYield();
        assertLt(yield, 1 ether); // yield is small

        // Agent tries to withdraw more than yield (but within cap)
        vm.prank(agent);
        vm.expectRevert(); // InsufficientYield or ExceedsPerTxCap
        treasury.agentWithdraw(recipient1, 1 ether);

        // Principal untouched
        assertGe(treasury.currentValueStETH(), treasury.principalStETH());
    }

    // ========================
    // OWNER WITHDRAWAL
    // ========================

    function test_ownerWithdraw() public {
        treasury.deposit{value: 10 ether}();
        steth.simulateRebase(1 ether);

        uint256 ownerBalBefore = steth.balanceOf(owner);
        treasury.ownerWithdraw();
        uint256 ownerBalAfter = steth.balanceOf(owner);

        assertGt(ownerBalAfter, ownerBalBefore);
        assertEq(treasury.wstETHBalance(), 0);
        assertEq(treasury.principalStETH(), 0);
    }

    function test_ownerWithdraw_revert_notOwner() public {
        treasury.deposit{value: 10 ether}();

        vm.prank(agent);
        vm.expectRevert(AgentTreasury.OnlyOwner.selector);
        treasury.ownerWithdraw();
    }

    function test_ownerWithdraw_revert_empty() public {
        vm.expectRevert(AgentTreasury.ZeroAmount.selector);
        treasury.ownerWithdraw();
    }

    // ========================
    // ADMIN
    // ========================

    function test_setAgent() public {
        address newAgent = address(0xA2);
        treasury.setAgent(newAgent);
        assertEq(treasury.agent(), newAgent);
    }

    function test_setAgent_revert_notOwner() public {
        vm.prank(agent);
        vm.expectRevert(AgentTreasury.OnlyOwner.selector);
        treasury.setAgent(address(0xA2));
    }

    function test_setAgent_revert_zero() public {
        vm.expectRevert(AgentTreasury.ZeroAddress.selector);
        treasury.setAgent(address(0));
    }

    function test_setRecipientWhitelist() public {
        treasury.setRecipientWhitelist(recipient2, true);
        assertTrue(treasury.whitelistedRecipients(recipient2));

        treasury.setRecipientWhitelist(recipient2, false);
        assertFalse(treasury.whitelistedRecipients(recipient2));
    }

    function test_setPerTxCap() public {
        treasury.setPerTxCap(5 ether);
        assertEq(treasury.perTxCap(), 5 ether);
    }

    function test_setTimeWindow() public {
        treasury.setTimeWindow(1 days);
        assertEq(treasury.timeWindow(), 1 days);
    }

    function test_unlimitedCap() public {
        // Set cap to 0 (unlimited)
        treasury.setPerTxCap(0);
        treasury.deposit{value: 100 ether}();
        steth.simulateRebase(10 ether);

        uint256 yield = treasury.availableYield();
        vm.prank(agent);
        treasury.agentWithdraw(recipient1, yield);

        assertGt(steth.balanceOf(recipient1), 0);
    }

    // ========================
    // INVARIANT: principal never decreases from agent actions
    // ========================

    function test_principalInvariant_multipleWithdrawals() public {
        treasury.deposit{value: 100 ether}();
        uint256 principal = treasury.principalStETH();

        // Multiple rebases and withdrawals
        for (uint256 i = 0; i < 5; i++) {
            steth.simulateRebase(2 ether);
            uint256 yield = treasury.availableYield();
            if (yield > 0) {
                uint256 amount = yield > treasury.perTxCap() ? treasury.perTxCap() : yield;
                vm.warp(block.timestamp + 2 hours); // past cooldown
                vm.prank(agent);
                treasury.agentWithdraw(recipient1, amount);
            }
        }

        // Principal value still covered
        assertGe(treasury.currentValueStETH(), treasury.principalStETH());
        assertEq(treasury.principalStETH(), principal);
    }

    // Allow this contract to receive ETH
    receive() external payable {}
}
