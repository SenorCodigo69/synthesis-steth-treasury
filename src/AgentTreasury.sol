// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IStETH.sol";
import "./interfaces/IWstETH.sol";

/// @title AgentTreasury
/// @notice Lets a human give an AI agent a yield-bearing operating budget backed by stETH.
///         Principal is structurally inaccessible to the agent — only accrued staking yield
///         flows to the agent's spendable balance. Spending permissions are enforced at the
///         contract level: recipient whitelist, per-transaction cap, and time window cooldown.
/// @dev Uses wstETH internally for clean accounting (non-rebasing). Yield is calculated as
///      the difference between the current stETH value of held wstETH and the recorded principal.
contract AgentTreasury {
    // --- Immutables ---
    IStETH public immutable stETH;
    IWstETH public immutable wstETH;

    // --- State ---
    address public owner;
    address public agent;

    uint256 public principalStETH;      // stETH value at deposit time (snapshot)
    uint256 public wstETHBalance;       // wstETH shares held by this contract
    uint256 public totalYieldWithdrawn; // cumulative yield withdrawn by agent (in stETH terms)

    // --- Permissions ---
    mapping(address => bool) public whitelistedRecipients;
    uint256 public perTxCap;            // max stETH per agent withdrawal (0 = unlimited)
    uint256 public timeWindow;          // min seconds between agent withdrawals
    uint256 public lastWithdrawal;      // timestamp of last agent withdrawal

    // --- Events ---
    event Deposited(address indexed depositor, uint256 ethAmount, uint256 stETHReceived, uint256 wstETHMinted);
    event YieldWithdrawn(address indexed agent, address indexed recipient, uint256 stETHAmount);
    event OwnerWithdrawn(address indexed owner, uint256 wstETHAmount, uint256 stETHAmount);
    event AgentUpdated(address indexed oldAgent, address indexed newAgent);
    event RecipientWhitelisted(address indexed recipient, bool status);
    event PerTxCapUpdated(uint256 oldCap, uint256 newCap);
    event TimeWindowUpdated(uint256 oldWindow, uint256 newWindow);

    // --- Errors ---
    error OnlyOwner();
    error OnlyAgent();
    error RecipientNotWhitelisted(address recipient);
    error ExceedsPerTxCap(uint256 requested, uint256 cap);
    error CooldownNotElapsed(uint256 nextAllowed);
    error InsufficientYield(uint256 requested, uint256 available);
    error ZeroAddress();
    error ZeroAmount();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyAgent() {
        if (msg.sender != agent) revert OnlyAgent();
        _;
    }

    constructor(
        address _stETH,
        address _wstETH,
        address _agent,
        uint256 _perTxCap,
        uint256 _timeWindow
    ) {
        if (_stETH == address(0) || _wstETH == address(0) || _agent == address(0)) revert ZeroAddress();

        stETH = IStETH(_stETH);
        wstETH = IWstETH(_wstETH);
        owner = msg.sender;
        agent = _agent;
        perTxCap = _perTxCap;
        timeWindow = _timeWindow;
    }

    // ========================
    // DEPOSIT (Owner only)
    // ========================

    /// @notice Deposit ETH into the treasury. Stakes via Lido, wraps to wstETH.
    ///         Can be called multiple times — principal accumulates.
    function deposit() external payable onlyOwner {
        if (msg.value == 0) revert ZeroAmount();

        // 1. Stake ETH via Lido → receive stETH
        uint256 stETHReceived = stETH.submit{value: msg.value}(address(0));

        // 2. Approve wstETH contract to wrap our stETH
        stETH.approve(address(wstETH), stETHReceived);

        // 3. Wrap stETH → wstETH
        uint256 wstETHMinted = wstETH.wrap(stETHReceived);

        // 4. Update accounting
        principalStETH += stETHReceived;
        wstETHBalance += wstETHMinted;

        emit Deposited(msg.sender, msg.value, stETHReceived, wstETHMinted);
    }

    // ========================
    // YIELD VIEWS
    // ========================

    /// @notice Current stETH value of all held wstETH
    function currentValueStETH() public view returns (uint256) {
        if (wstETHBalance == 0) return 0;
        return wstETH.getStETHByWstETH(wstETHBalance);
    }

    /// @notice Accrued yield available for the agent to withdraw (in stETH)
    function availableYield() public view returns (uint256) {
        uint256 currentValue = currentValueStETH();
        if (currentValue <= principalStETH) return 0;
        return currentValue - principalStETH;
    }

    // ========================
    // AGENT WITHDRAWAL (yield only)
    // ========================

    /// @notice Agent withdraws accrued yield to a whitelisted recipient.
    /// @param recipient Address to receive the stETH yield
    /// @param stETHAmount Amount of stETH yield to withdraw
    function agentWithdraw(address recipient, uint256 stETHAmount) external onlyAgent {
        if (stETHAmount == 0) revert ZeroAmount();
        if (!whitelistedRecipients[recipient]) revert RecipientNotWhitelisted(recipient);
        if (perTxCap > 0 && stETHAmount > perTxCap) revert ExceedsPerTxCap(stETHAmount, perTxCap);
        if (block.timestamp < lastWithdrawal + timeWindow) {
            revert CooldownNotElapsed(lastWithdrawal + timeWindow);
        }

        uint256 yield = availableYield();
        if (stETHAmount > yield) revert InsufficientYield(stETHAmount, yield);

        // Convert stETH amount to wstETH for unwrapping
        uint256 wstETHNeeded = wstETH.getWstETHByStETH(stETHAmount);

        // Unwrap wstETH → stETH
        uint256 stETHUnwrapped = wstETH.unwrap(wstETHNeeded);
        wstETHBalance -= wstETHNeeded;

        // Transfer stETH to recipient
        bool success = stETH.transfer(recipient, stETHUnwrapped);
        if (!success) revert TransferFailed();

        // Update state
        totalYieldWithdrawn += stETHUnwrapped;
        lastWithdrawal = block.timestamp;

        // Invariant: remaining value must still cover principal
        assert(currentValueStETH() >= principalStETH);

        emit YieldWithdrawn(msg.sender, recipient, stETHUnwrapped);
    }

    // ========================
    // OWNER WITHDRAWAL (everything)
    // ========================

    /// @notice Owner withdraws all funds (principal + any remaining yield).
    ///         Full exit — unwraps all wstETH and returns stETH to owner.
    function ownerWithdraw() external onlyOwner {
        uint256 wstETHToWithdraw = wstETHBalance;
        if (wstETHToWithdraw == 0) revert ZeroAmount();

        // Unwrap all wstETH → stETH
        uint256 stETHReturned = wstETH.unwrap(wstETHToWithdraw);

        // Reset accounting
        wstETHBalance = 0;
        principalStETH = 0;

        // Transfer stETH to owner
        bool success = stETH.transfer(owner, stETHReturned);
        if (!success) revert TransferFailed();

        emit OwnerWithdrawn(owner, wstETHToWithdraw, stETHReturned);
    }

    // ========================
    // OWNER ADMIN
    // ========================

    /// @notice Update the agent address
    function setAgent(address _agent) external onlyOwner {
        if (_agent == address(0)) revert ZeroAddress();
        emit AgentUpdated(agent, _agent);
        agent = _agent;
    }

    /// @notice Whitelist or remove a recipient address
    function setRecipientWhitelist(address recipient, bool status) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        whitelistedRecipients[recipient] = status;
        emit RecipientWhitelisted(recipient, status);
    }

    /// @notice Update the per-transaction cap (0 = unlimited)
    function setPerTxCap(uint256 _perTxCap) external onlyOwner {
        emit PerTxCapUpdated(perTxCap, _perTxCap);
        perTxCap = _perTxCap;
    }

    /// @notice Update the time window between agent withdrawals
    function setTimeWindow(uint256 _timeWindow) external onlyOwner {
        emit TimeWindowUpdated(timeWindow, _timeWindow);
        timeWindow = _timeWindow;
    }
}
