// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title PolicyVault — stablecoin treasury with on-chain guardrails for an autonomous agent.
/// @notice The owner defines hard rules (token/payee/target allowlists, per-token daily caps).
///         The agent can only act inside those rules. The owner can always withdraw everything.
contract PolicyVault {
    address public owner;
    address public agent;

    mapping(address => bool) public allowedToken; // tokens the agent may move (USDC, EURC)
    mapping(address => bool) public allowedPayee; // outbound payment recipients
    mapping(address => bool) public allowedTarget; // contracts the agent may grant allowances to (e.g. StableFX escrow)
    mapping(address => uint256) public dailyCap; // per-token daily spend limit (0 = agent blocked)
    mapping(address => uint256) public spentToday; // per-token spend in that token's current day window
    mapping(address => uint256) public lastSpendDay; // per-token day of the last spend

    event OwnerSet(address owner);
    event AgentSet(address agent);
    event TokenAllowed(address token, bool allowed);
    event PayeeAllowed(address payee, bool allowed);
    event TargetAllowed(address target, bool allowed);
    event DailyCapSet(address token, uint256 cap);
    event Paid(address indexed token, address indexed to, uint256 amount, string memo);
    event TargetApproved(address indexed token, address indexed target, uint256 amount);
    event OwnerWithdraw(address indexed token, address indexed to, uint256 amount);

    error NotOwner();
    error NotAgent();
    error TokenNotAllowed();
    error PayeeNotAllowed();
    error TargetNotAllowed();
    error DailyCapExceeded(uint256 requested, uint256 remaining);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAgent() {
        if (msg.sender != agent) revert NotAgent();
        _;
    }

    constructor(address _agent) {
        owner = msg.sender;
        agent = _agent;
        emit AgentSet(_agent);
    }

    // ---- owner: policy management ----

    function setOwner(address _owner) external onlyOwner {
        require(_owner != address(0), "zero owner");
        owner = _owner;
        emit OwnerSet(_owner);
    }

    function setAgent(address _agent) external onlyOwner {
        agent = _agent;
        emit AgentSet(_agent);
    }

    function setToken(address token, bool allowed) external onlyOwner {
        allowedToken[token] = allowed;
        emit TokenAllowed(token, allowed);
    }

    function setPayee(address payee, bool allowed) external onlyOwner {
        allowedPayee[payee] = allowed;
        emit PayeeAllowed(payee, allowed);
    }

    function setTarget(address target, bool allowed) external onlyOwner {
        allowedTarget[target] = allowed;
        emit TargetAllowed(target, allowed);
    }

    function setDailyCap(address token, uint256 cap) external onlyOwner {
        dailyCap[token] = cap;
        emit DailyCapSet(token, cap);
    }

    /// @notice The owner escape hatch: withdraw any token, any amount, no policy checks.
    function ownerWithdraw(address token, address to, uint256 amount) external onlyOwner {
        require(IERC20(token).transfer(to, amount), "transfer failed");
        emit OwnerWithdraw(token, to, amount);
    }

    // ---- agent: constrained actions ----

    /// @notice Outbound payment to an allowlisted payee, within the token's daily cap.
    function pay(address token, address to, uint256 amount, string calldata memo) external onlyAgent {
        if (!allowedToken[token]) revert TokenNotAllowed();
        if (!allowedPayee[to]) revert PayeeNotAllowed();
        _spend(token, amount);
        require(IERC20(token).transfer(to, amount), "transfer failed");
        emit Paid(token, to, amount, memo);
    }

    /// @notice Grant an allowance to an allowlisted contract (e.g. StableFX escrow) for a
    ///         rebalance. Counts against the daily cap so approvals can't bypass it.
    function approveTarget(address token, address target, uint256 amount) external onlyAgent {
        if (!allowedToken[token]) revert TokenNotAllowed();
        if (!allowedTarget[target]) revert TargetNotAllowed();
        _spend(token, amount);
        require(IERC20(token).approve(target, amount), "approve failed");
        emit TargetApproved(token, target, amount);
    }

    // ---- internals ----

    function _spend(address token, uint256 amount) internal {
        uint256 day = block.timestamp / 1 days;
        uint256 spent = lastSpendDay[token] == day ? spentToday[token] : 0;
        uint256 cap = dailyCap[token];
        if (spent + amount > cap) revert DailyCapExceeded(amount, cap > spent ? cap - spent : 0);
        spentToday[token] = spent + amount;
        lastSpendDay[token] = day;
    }

    function remainingToday(address token) external view returns (uint256) {
        uint256 day = block.timestamp / 1 days;
        uint256 spent = lastSpendDay[token] == day ? spentToday[token] : 0;
        uint256 cap = dailyCap[token];
        return cap > spent ? cap - spent : 0;
    }
}
