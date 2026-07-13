// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title FxDesk — minimal onchain FX settlement desk for USDC<->EURC.
/// @notice Plays the market-maker role of an RFQ desk: the owner posts a rate, takers
///         settle atomically against the desk's inventory. Steward's FX executor is
///         pluggable — this desk can be swapped for Circle's StableFX FxEscrow once
///         institutional access is granted, without touching the vault or the agent's
///         policy logic.
contract FxDesk {
    address public owner;
    IERC20 public immutable usdc;
    IERC20 public immutable eurc;

    /// EURC per 1 USDC, 6 decimals (e.g. 855000 = 0.855). Reverse direction uses 1/rate.
    uint256 public rateUsdcToEurc;

    event RateSet(uint256 rate);
    event Swapped(address indexed payer, address tokenIn, uint256 amountIn, uint256 amountOut);

    error NotOwner();
    error BadPair();
    error RateUnset();
    error InsufficientInventory(uint256 needed, uint256 available);

    constructor(address _usdc, address _eurc) {
        owner = msg.sender;
        usdc = IERC20(_usdc);
        eurc = IERC20(_eurc);
    }

    function setRate(uint256 rate) external {
        if (msg.sender != owner) revert NotOwner();
        rateUsdcToEurc = rate;
        emit RateSet(rate);
    }

    /// @notice Quote the output amount for a given input (view, no state change).
    function quote(address tokenIn, uint256 amountIn) public view returns (uint256) {
        if (rateUsdcToEurc == 0) revert RateUnset();
        if (tokenIn == address(usdc)) return (amountIn * rateUsdcToEurc) / 1e6;
        if (tokenIn == address(eurc)) return (amountIn * 1e6) / rateUsdcToEurc;
        revert BadPair();
    }

    /// @notice Settle a swap for `payer`: pulls tokenIn from the payer's allowance and
    ///         sends tokenOut from the desk's inventory back to the payer.
    ///         Callable by anyone — the payer's allowance is the authorization.
    function swapFor(address payer, address tokenIn, uint256 amountIn) external returns (uint256 amountOut) {
        amountOut = quote(tokenIn, amountIn);
        IERC20 tin = IERC20(tokenIn);
        IERC20 tout = tokenIn == address(usdc) ? eurc : usdc;
        uint256 inv = tout.balanceOf(address(this));
        if (inv < amountOut) revert InsufficientInventory(amountOut, inv);
        require(tin.transferFrom(payer, address(this), amountIn), "pull failed");
        require(tout.transfer(payer, amountOut), "payout failed");
        emit Swapped(payer, tokenIn, amountIn, amountOut);
    }

    /// Owner can withdraw desk inventory.
    function withdraw(address token, address to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        require(IERC20(token).transfer(to, amount), "transfer failed");
    }
}
