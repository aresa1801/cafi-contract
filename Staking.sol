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

    IERC20 public immutable stakingToken;
    IERC20 public rewardToken;

    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant AUTO_COMPOUND_FEE = 50; // 0.5%
    address public feeReceiver;

    uint256[3] public lockPeriods = [30 days, 60 days, 90 days];
    uint256[3] public apyRates = [500, 1000, 1500]; // basis points

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

    uint256 public totalStaked;
    uint256 public rewardPoolBalance;

    event Staked(address indexed user, uint256 amount, uint256 periodIndex, bool autoStake);
    event Claimed(address indexed user, uint256 amount, uint256 stakeIndex);
    event AutoCompounded(address indexed user, uint256 stakeIndex, uint256 compoundedAmount);
    event AutoStakeToggled(address indexed user, uint256 stakeIndex, bool status);
    event RewardTokenUpdated(address indexed newRewardToken);
    event FeeReceiverUpdated(address indexed newFeeReceiver);
    event APYUpdated(uint256 periodIndex, uint256 newAPY);
    event RewardPoolFundsAdded(uint256 amount);
    event WithdrawnRewards(address indexed account, uint256 amount);

    /**
     * @notice Restricts function to externally owned accounts (EOAs)
     */
    modifier onlyEOA() {
        require(tx.origin == msg.sender, "Caller must be EOA");
        _;
    }

    constructor(
        address _stakingTokenAddress,
        address _rewardTokenAddress,
        address _feeReceiver
    ) Ownable(msg.sender) {
        require(_stakingTokenAddress != address(0), "Invalid staking token");
        require(_rewardTokenAddress != address(0), "Invalid reward token");
        require(_feeReceiver != address(0), "Invalid fee receiver");

        stakingToken = IERC20(_stakingTokenAddress);
        rewardToken = IERC20(_rewardTokenAddress);
        feeReceiver = _feeReceiver;
    }

    /**
     * @notice Stake tokens for a fixed period
     * @param amount Amount of tokens to stake
     * @param periodIndex Index of the lock period (0, 1, or 2)
     * @param autoStake Whether to enable auto-staking after unlock
     */
    function stake(uint256 amount, uint256 periodIndex, bool autoStake) external nonReentrant onlyEOA {
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
     * @param account Address of staker
     * @param stakeIndex Index of stake
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
        uint256 apy = apyRates[periodIndex];

        uint256 principal = info.amount + info.compoundedAmount;
        return (principal * apy * timeHeld) / (10000 * SECONDS_PER_YEAR);
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
     * @param stakeIndex Index of stake
     */
    function claimReward(uint256 stakeIndex) external nonReentrant onlyEOA {
        address account = msg.sender;
        require(stakeIndex < stakes[account].length, "Invalid stake index");

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
    function withdrawRewards() external nonReentrant {
        uint256 amount = pendingRewardWithdrawals[msg.sender];
        require(amount > 0, "No rewards to withdraw");

        pendingRewardWithdrawals[msg.sender] = 0;
        rewardToken.safeTransfer(msg.sender, amount);
        emit WithdrawnRewards(msg.sender, amount);
    }

    /**
     * @notice Toggle auto-staking for a stake
     * @param stakeIndex Index of stake
     */
    function toggleAutoStake(uint256 stakeIndex) external {
        address account = msg.sender;
        require(stakeIndex < stakes[account].length, "Invalid stake index");

        StakeInfo storage info = stakes[account][stakeIndex];
        require(!info.claimed, "Already claimed");

        info.autoStaking = !info.autoStaking;
        emit AutoStakeToggled(account, stakeIndex, info.autoStaking);
    }

    /**
     * @notice Compound reward into new stake
     * @param stakeIndex Index of stake
     */
    function compoundReward(uint256 stakeIndex) external nonReentrant onlyEOA {
        address account = msg.sender;
        require(stakeIndex < stakes[account].length, "Invalid stake index");

        StakeInfo storage info = stakes[account][stakeIndex];
        require(!info.claimed, "Already claimed");
        require(info.autoStaking, "Auto-staking disabled");
        require(block.timestamp >= info.unlockTime, "Still locked");

        uint256 reward = calculateReward(account, stakeIndex);
        require(rewardPoolBalance >= reward, "Insufficient reward pool");

        info.stakeTime = block.timestamp;
        info.unlockTime = block.timestamp + (info.unlockTime - info.stakeTime); // same period
        info.compoundedAmount += reward;
        rewardPoolBalance -= reward;

        emit AutoCompounded(account, stakeIndex, info.compoundedAmount);
    }

    /**
     * @notice Add funds to reward pool
     * @param amount Amount to add
     */
    function addRewardPoolFunds(uint256 amount) external onlyOwner {
        require(amount > 0, "Zero amount");
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardPoolBalance += amount;
        emit RewardPoolFundsAdded(amount);
    }

    /**
     * @notice Update APY rate for a period
     * @param periodIndex Index of period
     * @param newAPY New APY in basis points
     */
    function setAPY(uint256 periodIndex, uint256 newAPY) external onlyOwner {
        require(periodIndex < lockPeriods.length, "Invalid period index");
        require(newAPY <= 10000, "APY too high"); // Max 100%
        apyRates[periodIndex] = newAPY;
        emit APYUpdated(periodIndex, newAPY);
    }

    /**
     * @notice Update reward token address
     * @param newRewardToken New reward token address
     */
    function updateRewardToken(address newRewardToken) external onlyOwner {
        require(newRewardToken != address(0), "Invalid reward token");
        rewardToken = IERC20(newRewardToken);
        emit RewardTokenUpdated(newRewardToken);
    }

    /**
     * @notice Update fee receiver address
     * @param newFeeReceiver New fee receiver address
     */
    function updateFeeReceiver(address newFeeReceiver) external onlyOwner {
        require(newFeeReceiver != address(0), "Invalid fee receiver");
        feeReceiver = newFeeReceiver;
        emit FeeReceiverUpdated(newFeeReceiver);
    }

    /**
     * @notice Get active stakes for an account
     */
    function getActiveStakes(address user) external view returns (StakeInfo[] memory) {
        return stakes[user];
    }
}