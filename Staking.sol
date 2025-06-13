// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title AutoStaking
 * @dev Contract for staking tokens with fixed lock periods and auto-compounding rewards.
 */
contract AutoStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Token contracts
    IERC20 public immutable stakingToken;
    IERC20 public rewardToken;

    // Constants
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant AUTO_COMPOUND_FEE = 50; // 0.5%
    uint256 public constant MAX_APY = 10000; // 100%

    // Staking parameters
    uint256[3] public lockPeriods = [30 days, 60 days, 90 days];
    uint256[3] public apyRates = [500, 1000, 1500]; // basis points

    // User stakes
    struct StakeInfo {
        uint256 amount;
        uint256 stakeTime;
        uint256 unlockTime;
        bool claimed;
        bool autoStaking;
        uint256 compoundedAmount;
    }

    mapping(address => StakeInfo[]) public stakes;
    mapping(address => uint256) public pendingRewardWithdrawals;

    // Global stats
    uint256 public totalStaked;
    uint256 public rewardPoolBalance;
    address public feeReceiver;

    // Events
    event Staked(address indexed user, uint256 amount, uint256 periodIndex, bool autoStake);
    event Claimed(address indexed user, uint256 amount, uint256 stakeIndex);
    event WithdrawnRewards(address indexed account, uint256 amount);
    event AutoStakeToggled(address indexed user, uint256 stakeIndex, bool status);
    event RewardTokenUpdated(address indexed newRewardToken);
    event FeeReceiverUpdated(address indexed newFeeReceiver);
    event APYUpdated(uint256 periodIndex, uint256 newAPY);
    event RewardPoolFundsAdded(address indexed sender, uint256 amount);
    event AutoCompounded(address indexed user, uint256 stakeIndex, uint256 compoundedAmount);
    event ContractPaused(bool indexed isPaused); // 🔥 Penambahan event

    // Modifiers
    modifier onlyEOA() {
        require(tx.origin == msg.sender, "Only EOA can call");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract paused");
        _;
    }

    // Paused state
    bool public paused;

    constructor(
        address _stakingTokenAddress,
        address _rewardTokenAddress,
        address _feeReceiver
    ) Ownable(msg.sender) ReentrancyGuard() {
        require(_stakingTokenAddress != address(0), "Invalid staking token");
        require(_rewardTokenAddress != address(0), "Invalid reward token");
        require(_feeReceiver != address(0), "Invalid fee receiver");

        stakingToken = IERC20(_stakingTokenAddress);
        rewardToken = IERC20(_rewardTokenAddress);
        feeReceiver = _feeReceiver;
    }

    // ===================== Core Functions =====================
    /**
     * @notice Stake tokens for a fixed period
     */
    function stake(uint256 amount, uint256 periodIndex, bool autoStake) external nonReentrant onlyEOA whenNotPaused {
        require(periodIndex < lockPeriods.length, "Invalid period index");
        require(amount > 0, "Zero amount");

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 unlockTime = block.timestamp + lockPeriods[periodIndex];

        stakes[msg.sender].push(StakeInfo({
            amount: amount,
            stakeTime: block.timestamp,
            unlockTime: unlockTime,
            claimed: false,
            autoStaking: autoStake,
            compoundedAmount: 0
        }));

        totalStaked += amount;

        emit Staked(msg.sender, amount, periodIndex, autoStake);
    }

    /**
     * @notice Calculate accrued reward for a stake
     */
    function calculateReward(address account, uint256 stakeIndex) public view returns (uint256) {
        require(account != address(0), "Invalid account");
        require(stakeIndex < stakes[account].length, "Invalid stake index");

        StakeInfo memory info = stakes[account][stakeIndex];
        require(!info.claimed, "Already claimed");

        uint256 endTime = info.unlockTime;
        if (info.autoStaking && block.timestamp > endTime) {
            endTime = block.timestamp;
        }

        uint256 timeHeld = endTime - info.stakeTime;
        uint256 periodIndex = getPeriodIndex(info.unlockTime - info.stakeTime);
        uint256 principal = info.amount + info.compoundedAmount;

        return (principal * apyRates[periodIndex] * timeHeld) / (10000 * SECONDS_PER_YEAR);
    }

    /**
     * @notice Get period index from duration
     */
    function getPeriodIndex(uint256 duration) internal view returns (uint256) {
        for (uint256 i = 0; i < lockPeriods.length; i++) {
            if (duration == lockPeriods[i]) {
                return i;
            }
        }
        revert("Unsupported lock period");
    }

    /**
     * @notice Claim reward for a specific stake
     */
    function claimReward(uint256 stakeIndex) external nonReentrant onlyEOA whenNotPaused {
        address account = msg.sender;
        StakeInfo storage info = stakes[account][stakeIndex];
        require(!info.claimed, "Already claimed");
        require(block.timestamp >= info.unlockTime, "Still locked");

        uint256 reward = calculateReward(account, stakeIndex);
        require(rewardPoolBalance >= reward, "Insufficient reward pool");

        info.claimed = true;

        if (info.autoStaking && info.compoundedAmount > 0) {
            uint256 totalToTransfer = info.compoundedAmount + reward;
            uint256 fee = (totalToTransfer * AUTO_COMPOUND_FEE) / 10000;
            uint256 userAmount = totalToTransfer - fee;

            pendingRewardWithdrawals[account] += userAmount;
            pendingRewardWithdrawals[feeReceiver] += fee;
            rewardPoolBalance -= totalToTransfer;
        } else {
            pendingRewardWithdrawals[account] += reward;
            rewardPoolBalance -= reward;
        }

        emit Claimed(account, reward, stakeIndex);
    }

    /**
     * @notice Withdraw pending rewards
     */
    function withdrawRewards() external nonReentrant whenNotPaused {
        uint256 amount = pendingRewardWithdrawals[msg.sender];
        require(amount > 0, "No rewards to withdraw");

        pendingRewardWithdrawals[msg.sender] = 0;
        rewardToken.safeTransfer(msg.sender, amount);

        emit WithdrawnRewards(msg.sender, amount);
    }

    /**
     * @notice Toggle auto-staking for a stake
     */
    function toggleAutoStake(uint256 stakeIndex) external whenNotPaused {
        address account = msg.sender;
        require(stakeIndex < stakes[account].length, "Invalid stake index");

        StakeInfo storage info = stakes[account][stakeIndex];
        require(!info.claimed, "Already claimed");

        info.autoStaking = !info.autoStaking;
        emit AutoStakeToggled(account, stakeIndex, info.autoStaking);
    }

    /**
     * @notice Compound reward into new stake
     */
    function compoundReward(uint256 stakeIndex) external nonReentrant onlyEOA whenNotPaused {
        address account = msg.sender;
        require(stakeIndex < stakes[account].length, "Invalid stake index");

        StakeInfo storage info = stakes[account][stakeIndex];
        require(!info.claimed, "Already claimed");
        require(info.autoStaking, "Auto-staking disabled");
        require(block.timestamp >= info.unlockTime, "Still locked");

        uint256 reward = calculateReward(account, stakeIndex);
        require(rewardPoolBalance >= reward, "Insufficient reward pool");

        info.stakeTime = block.timestamp;
        info.unlockTime = block.timestamp + (info.unlockTime - info.stakeTime); // Same period
        info.compoundedAmount += reward;
        rewardPoolBalance -= reward;

        emit AutoCompounded(account, stakeIndex, info.compoundedAmount);
    }

    /**
     * @notice Add funds to reward pool
     */
    function addRewardPoolFunds(uint256 amount) external onlyOwner {
        require(amount > 0, "Zero amount");
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardPoolBalance += amount;

        emit RewardPoolFundsAdded(msg.sender, amount);
    }

    /**
     * @notice Update APY rate for a period
     */
    function setAPY(uint256 periodIndex, uint256 newAPY) external onlyOwner {
        require(periodIndex < lockPeriods.length, "Invalid period index");
        require(newAPY <= MAX_APY, "APY too high"); // Max 100%

        apyRates[periodIndex] = newAPY;
        emit APYUpdated(periodIndex, newAPY);
    }

    /**
     * @notice Update reward token address
     */
    function updateRewardToken(address newRewardToken) external onlyOwner {
        require(newRewardToken != address(0), "Zero address not allowed");
        rewardToken = IERC20(newRewardToken);
        emit RewardTokenUpdated(newRewardToken);
    }

    /**
     * @notice Update fee receiver address
     */
    function updateFeeReceiver(address newFeeReceiver) external onlyOwner {
        require(newFeeReceiver != address(0), "Zero address not allowed");
        feeReceiver = newFeeReceiver;
        emit FeeReceiverUpdated(newFeeReceiver);
    }

    /**
     * @notice Toggle contract pause
     */
    function togglePause() external onlyOwner {
        paused = !paused;
        emit ContractPaused(paused);
    }

    /**
     * @notice Get active stakes for an account
     */
    function getActiveStakes(address user) external view returns (StakeInfo[] memory) {
        return stakes[user];
    }

    /**
     * @notice Get current reward pool balance
     */
    function getRewardPoolBalance() external view returns (uint256) {
        return rewardPoolBalance;
    }

    /**
     * @notice Get fee receiver address
     */
    function getFeeReceiver() external view returns (address) {
        return feeReceiver;
    }

    /**
     * @notice Get lock period in seconds
     */
    function getLockPeriod(uint256 index) external view returns (uint256) {
        require(index < lockPeriods.length, "Invalid period index");
        return lockPeriods[index];
    }

    /**
     * @notice Estimate mint gas
     */
    function estimateMintGas() external pure returns (uint256) {
        return 200_000;
    }
}