// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title CAFiFaucet
 * @dev Faucet for distributing CAFi tokens with daily limit and anti-bot protection.
 */
contract CAFiFaucet is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public cafiToken;
    uint256 public constant DAILY_LIMIT = 10_000 * 1e18; // 10,000 CAFi tokens
    uint256 public constant MIN_ETH_BALANCE = 0.001 ether; // Anti-bot measure

    mapping(address => uint256) public lastClaimTime;
    uint256 public todayTotal;
    uint256 public lastResetTime;

    /**
     * @notice Emitted when user claims tokens from the faucet
     */
    event TokensClaimed(address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when owner refills the faucet
     */
    event FaucetRefilled(address indexed owner, uint256 amount);

    /**
     * @notice Emitted when owner withdraws excess tokens
     */
    event ExcessWithdrawn(address indexed owner, uint256 amount);

    constructor(address _cafiToken) Ownable(msg.sender) ReentrancyGuard() {
        require(_cafiToken != address(0), "Invalid token address");
        cafiToken = IERC20(_cafiToken);
        lastResetTime = block.timestamp;
    }

    /**
     * @notice Claim tokens from the faucet (once every 24 hours)
     */
    function claimTokens() external nonReentrant {
        // Reset daily total if 24h passed
        if (block.timestamp >= lastResetTime + 1 days) {
            todayTotal = 0;
            lastResetTime = block.timestamp;
        }

        // ETH balance check (anti-bot)
        require(
            address(msg.sender).balance >= MIN_ETH_BALANCE,
            "Minimum 0.001 ETH balance required to claim"
        );

        // Time since last claim
        uint256 userLastClaim = lastClaimTime[msg.sender];
        require(
            block.timestamp >= userLastClaim + 1 days,
            "You can only claim once every 24 hours"
        );

        // Check faucet has enough tokens
        uint256 currentBalance = cafiToken.balanceOf(address(this));
        require(
            todayTotal + DAILY_LIMIT <= currentBalance,
            "Faucet is empty for today. Please wait for a refill."
        );

        // Update state before transfer
        lastClaimTime[msg.sender] = block.timestamp;
        todayTotal += DAILY_LIMIT;

        // Transfer tokens
        cafiToken.safeTransfer(msg.sender, DAILY_LIMIT);

        emit TokensClaimed(msg.sender, DAILY_LIMIT);
    }

    /**
     * @notice Refill faucet with CAFi tokens (owner only)
     */
    function refillFaucet(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Zero amount not allowed");

        // Transfer tokens into contract
        cafiToken.safeTransferFrom(msg.sender, address(this), amount);

        emit FaucetRefilled(msg.sender, amount);
    }

    /**
     * @notice Withdraw excess tokens (owner only)
     */
    function withdrawExcess() external onlyOwner nonReentrant {
        uint256 currentBalance = cafiToken.balanceOf(address(this));
        uint256 availableToWithdraw = currentBalance - todayTotal;
        require(availableToWithdraw > 0, "No excess tokens to withdraw");

        cafiToken.safeTransfer(owner(), availableToWithdraw);
        emit ExcessWithdrawn(owner(), availableToWithdraw);
    }

    /**
     * @notice Get remaining daily quota in faucet
     */
    function getRemainingDailyQuota() external view returns (uint256) {
        return cafiToken.balanceOf(address(this)) - todayTotal;
    }

    /**
     * @notice Get next claim time for a user
     */
    function getNextClaimTime(address user) external view returns (uint256) {
        return lastClaimTime[user] + 1 days;
    }
}