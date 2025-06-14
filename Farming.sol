// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title CAFIFarming - Secure Staking Platform
 * @notice Implements time-locked staking with auto-compounding rewards
 * @dev Features adjustable APY packages with strict security controls
 */
contract CAFIFarming is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ========== STRUCT DECLARATIONS ==========
    struct FarmPackage {
        address stakeTokenAddress;
        uint256 lockDuration;
        uint256 apyBps; // APY in basis points (1% = 100bps)
        uint256 minimumStakeAmount;
        bool isActive;
    }

    struct UserStake {
        uint256 packageId;
        uint256 stakedAmount;
        uint256 stakeStartTimestamp;
        uint256 lastRewardClaimTimestamp;
        bool isAutoCompounding;
    }

    // ========== CONSTANTS ==========
    uint256 public constant MAX_FEE_BPS = 1000; // 10% maximum fee
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant BPS_DENOMINATOR = 10000; // Basis points denominator

    // ========== IMMUTABLE STATE ==========
    IERC20 public immutable rewardToken;

    // ========== MUTABLE STATE ==========
    FarmPackage[] private farmPackages;
    address public feeCollector;
    uint256 public autoCompoundFeeBps = 50; // 0.5% fee
    uint256 public feePoolBalance;

    // ========== MAPPINGS ==========
    mapping(address => UserStake[]) private userStakes;

    // ========== EVENTS ==========
    event StakeCreated(
        address indexed user,
        uint256 indexed packageId,
        uint256 amount,
        uint256 startTime
    );
    event StakeWithdrawn(
        address indexed user,
        uint256 indexed stakeId,
        uint256 principal,
        uint256 reward
    );
    event RewardClaimed(
        address indexed user,
        uint256 indexed stakeId,
        uint256 amount
    );
    event AutoCompoundToggled(
        address indexed user,
        uint256 indexed stakeId,
        bool isEnabled
    );
    event PackageConfigured(
        uint256 indexed packageId,
        address stakeToken,
        uint256 duration,
        uint256 apyBps,
        uint256 minStake
    );
    event PackageStatusChanged(uint256 indexed packageId, bool isActive);
    event FeeParametersUpdated(uint256 newFeeBps, address newCollector);
    event FeesWithdrawn(address collector, uint256 amount);

    // ========== MODIFIERS ==========
    modifier validPackage(uint256 packageId) {
        require(packageId < farmPackages.length, "Invalid package ID");
        _;
    }

    modifier validStake(address user, uint256 stakeId) {
        require(stakeId < userStakes[user].length, "Invalid stake ID");
        require(userStakes[user][stakeId].stakedAmount > 0, "Inactive stake");
        _;
    }

    modifier positiveAmount(uint256 amount) {
        require(amount > 0, "Amount must be positive");
        _;
    }

    // ========== CONSTRUCTOR ==========
    constructor(
        address rewardTokenAddress,
        address initialFeeCollector,
        address initialOwner
    ) Ownable(initialOwner) {
        require(rewardTokenAddress != address(0), "Invalid reward token");
        require(initialFeeCollector != address(0), "Invalid fee collector");

        rewardToken = IERC20(rewardTokenAddress);
        feeCollector = initialFeeCollector;
    }

    // ========== USER FUNCTIONS ==========
    function createStake(uint256 packageId, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        validPackage(packageId)
        positiveAmount(amount)
    {
        FarmPackage storage package = farmPackages[packageId];
        require(package.isActive, "Package inactive");
        require(amount >= package.minimumStakeAmount, "Insufficient stake amount");

        IERC20(package.stakeTokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        userStakes[msg.sender].push(
            UserStake({
                packageId: packageId,
                stakedAmount: amount,
                stakeStartTimestamp: block.timestamp,
                lastRewardClaimTimestamp: block.timestamp,
                isAutoCompounding: false
            })
        );

        emit StakeCreated(msg.sender, packageId, amount, block.timestamp);
    }

    function claimStakeRewards(uint256 stakeId)
        external
        nonReentrant
        validStake(msg.sender, stakeId)
    {
        UserStake storage stakeInfo = userStakes[msg.sender][stakeId];
        uint256 rewardAmount = _calculateAccruedRewards(msg.sender, stakeId);
        require(rewardAmount > 0, "No rewards available");

        stakeInfo.lastRewardClaimTimestamp = block.timestamp;

        if (stakeInfo.isAutoCompounding) {
            stakeInfo.stakedAmount += rewardAmount;
        } else {
            rewardToken.safeTransfer(msg.sender, rewardAmount);
        }

        emit RewardClaimed(msg.sender, stakeId, rewardAmount);
    }

    function withdrawStake(uint256 stakeId)
        external
        nonReentrant
        validStake(msg.sender, stakeId)
    {
        UserStake memory stakeInfo = userStakes[msg.sender][stakeId];
        FarmPackage memory package = farmPackages[stakeInfo.packageId];

        require(
            block.timestamp >= stakeInfo.stakeStartTimestamp + package.lockDuration,
            "Stake still locked"
        );

        uint256 rewardAmount = _calculateAccruedRewards(msg.sender, stakeId);
        uint256 principalAmount = stakeInfo.stakedAmount;

        // Clear stake before transfers to prevent reentrancy
        delete userStakes[msg.sender][stakeId];

        // Transfer principal
        IERC20(package.stakeTokenAddress).safeTransfer(msg.sender, principalAmount);

        // Transfer rewards if any
        if (rewardAmount > 0) {
            rewardToken.safeTransfer(msg.sender, rewardAmount);
        }

        emit StakeWithdrawn(msg.sender, stakeId, principalAmount, rewardAmount);
    }

    function toggleAutoCompound(uint256 stakeId)
        external
        nonReentrant
        validStake(msg.sender, stakeId)
    {
        UserStake storage stakeInfo = userStakes[msg.sender][stakeId];
        stakeInfo.isAutoCompounding = !stakeInfo.isAutoCompounding;
        emit AutoCompoundToggled(msg.sender, stakeId, stakeInfo.isAutoCompounding);
    }

    // ========== VIEW FUNCTIONS ==========
    function calculatePendingRewards(address user, uint256 stakeId)
        external
        view
        returns (uint256)
    {
        return _calculateAccruedRewards(user, stakeId);
    }

    function _calculateAccruedRewards(address user, uint256 stakeId)
        internal
        view
        returns (uint256)
    {
        UserStake memory stakeInfo = userStakes[user][stakeId];
        if (stakeInfo.stakedAmount == 0) return 0;

        FarmPackage memory package = farmPackages[stakeInfo.packageId];
        uint256 elapsedTime = block.timestamp - stakeInfo.lastRewardClaimTimestamp;
        
        return (stakeInfo.stakedAmount * package.apyBps * elapsedTime) / 
               (SECONDS_PER_YEAR * BPS_DENOMINATOR);
    }

    function getActivePackageCount() external view returns (uint256) {
        return farmPackages.length;
    }

    function getPackageDetails(uint256 packageId)
        external
        view
        validPackage(packageId)
        returns (FarmPackage memory)
    {
        return farmPackages[packageId];
    }

    function getUserStakes(address user) external view returns (UserStake[] memory) {
        return userStakes[user];
    }

    // ========== ADMIN FUNCTIONS ==========
    function configureNewPackage(
        address stakeToken,
        uint256 duration,
        uint256 apyBps,
        uint256 minStake
    ) external onlyOwner {
        require(stakeToken != address(0), "Invalid stake token");
        require(duration > 0, "Invalid duration");
        require(apyBps > 0 && apyBps <= BPS_DENOMINATOR, "Invalid APY");

        farmPackages.push(
            FarmPackage({
                stakeTokenAddress: stakeToken,
                lockDuration: duration,
                apyBps: apyBps,
                minimumStakeAmount: minStake,
                isActive: true
            })
        );

        emit PackageConfigured(
            farmPackages.length - 1,
            stakeToken,
            duration,
            apyBps,
            minStake
        );
    }

    function updatePackageStatus(uint256 packageId, bool isActive)
        external
        onlyOwner
        validPackage(packageId)
    {
        farmPackages[packageId].isActive = isActive;
        emit PackageStatusChanged(packageId, isActive);
    }

    function updatePackageAPY(uint256 packageId, uint256 newApyBps)
        external
        onlyOwner
        validPackage(packageId)
    {
        require(newApyBps > 0 && newApyBps <= BPS_DENOMINATOR, "Invalid APY");
        farmPackages[packageId].apyBps = newApyBps;
        emit PackageConfigured(
            packageId,
            farmPackages[packageId].stakeTokenAddress,
            farmPackages[packageId].lockDuration,
            newApyBps,
            farmPackages[packageId].minimumStakeAmount
        );
    }

    function updateFeeParameters(uint256 newFeeBps, address newCollector)
        external
        onlyOwner
    {
        require(newFeeBps <= MAX_FEE_BPS, "Fee too high");
        require(newCollector != address(0), "Invalid collector");
        
        autoCompoundFeeBps = newFeeBps;
        feeCollector = newCollector;
        emit FeeParametersUpdated(newFeeBps, newCollector);
    }

    function withdrawAccumulatedFees() external {
        require(msg.sender == feeCollector, "Not authorized");
        uint256 amount = feePoolBalance;
        require(amount > 0, "No fees available");

        feePoolBalance = 0;
        rewardToken.safeTransfer(feeCollector, amount);
        emit FeesWithdrawn(feeCollector, amount);
    }

    function emergencyPause() external onlyOwner {
        _pause();
    }

    function emergencyUnpause() external onlyOwner {
        _unpause();
    }
}