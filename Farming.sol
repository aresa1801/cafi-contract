// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title CAFIFarming
 * @dev Contract for farming rewards based on staking packages with adjustable APY.
 */
contract CAFIFarming is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Struct untuk paket farming
    struct FarmPackage {
        address stakeToken;     // Token yang diterima untuk staking
        uint256 duration;       // Durasi staking (dalam detik)
        uint256 apy;            // APY dalam basis points (e.g., 1500 = 15%)
        uint256 minStake;      // Minimal jumlah staking
        bool isActive;
    }

    // Struct untuk stake user
    struct UserStake {
        uint256 packageId;
        uint256 amount;
        uint256 startTime;
        uint256 lastClaimTime;
        bool isAutoFarming;
    }

    // Token contracts
    IERC20 public immutable cafiToken;

    // Paket farming
    FarmPackage[] public farmPackages;

    // Mapping user stakes
    mapping(address => UserStake[]) public userStakes;

    // Auto-farming pool
    uint256 public autoFarmingPool;
    uint256 public autoFarmingFee = 50; // 0.5%
    address public treasuryWallet;

    // Events
    event Staked(address indexed user, uint256 packageId, uint256 amount);
    event Unstaked(address indexed user, uint256 stakeIndex, uint256 amount, uint256 reward);
    event RewardClaimed(address indexed user, uint256 stakeIndex, uint256 amount);
    event AutoFarmingToggled(address indexed user, uint256 stakeIndex, bool status);
    event PackageAdded(uint256 packageId, address stakeToken, uint256 duration, uint256 apy, uint256 minStake, bool isActive);
    event PackageAPYUpdated(uint256 packageId, uint256 oldAPY, uint256 newAPY);
    event FeeReceiverUpdated(address indexed newTreasury);

    constructor(
        address _cafiToken,
        address _treasuryWallet,
        address _initialOwner
    ) Ownable(_initialOwner) ReentrancyGuard() {
        require(_cafiToken != address(0), "Invalid CAFI token");
        require(_treasuryWallet != address(0), "Invalid treasury wallet");

        cafiToken = IERC20(_cafiToken);
        treasuryWallet = _treasuryWallet;
    }

    /**
     * @notice Proteksi tambahan: hanya EOA yang boleh memanggil fungsi ini
     */
    modifier onlyEOA() {
        require(tx.origin == msg.sender, "Only EOA can call");
        _;
    }

    /**
     * @notice Stake token ke farming berdasarkan package ID
     */
    function stake(uint256 packageId, uint256 amount) external nonReentrant onlyEOA {
        FarmPackage memory package = farmPackages[packageId];
        require(package.isActive, "Package not active");
        require(amount >= package.minStake, "Amount too low");

        IERC20(package.stakeToken).safeTransferFrom(msg.sender, address(this), amount);

        userStakes[msg.sender].push(UserStake({
            packageId: packageId,
            amount: amount,
            startTime: block.timestamp,
            lastClaimTime: block.timestamp,
            isAutoFarming: false
        }));

        emit Staked(msg.sender, packageId, amount);
    }

    /**
     * @notice Klaim reward dari farming
     */
    function claimReward(uint256 stakeIndex) external nonReentrant onlyEOA {
        UserStake storage userStake = userStakes[msg.sender][stakeIndex];
        require(userStake.amount > 0, "No active stake");

        uint256 reward = calculateReward(msg.sender, stakeIndex);
        require(reward > 0, "No reward to claim");

        userStake.lastClaimTime = block.timestamp;

        if (userStake.isAutoFarming) {
            userStake.amount += reward;
        } else {
            cafiToken.safeTransfer(msg.sender, reward);
        }

        emit RewardClaimed(msg.sender, stakeIndex, reward);
    }

    /**
     * @notice Withdraw stake + reward
     */
    function unstake(uint256 stakeIndex) external nonReentrant onlyEOA {
        UserStake storage currentStake = userStakes[msg.sender][stakeIndex];
        require(currentStake.amount > 0, "No active stake");

        FarmPackage memory package = farmPackages[currentStake.packageId];
        require(block.timestamp >= currentStake.startTime + package.duration, "Still locked");

        uint256 reward = calculateReward(msg.sender, stakeIndex);
        uint256 totalAmount = currentStake.amount;

        delete userStakes[msg.sender][stakeIndex];

        // Transfer stake token kembali
        IERC20(package.stakeToken).safeTransfer(msg.sender, totalAmount);

        // Transfer reward
        if (reward > 0) {
            cafiToken.safeTransfer(msg.sender, reward);
        }

        emit Unstaked(msg.sender, stakeIndex, totalAmount, reward);
    }

    /**
     * @notice Toggle mode auto farming
     */
    function toggleAutoFarming(uint256 stakeIndex) external nonReentrant onlyEOA {
        UserStake storage stakeData = userStakes[msg.sender][stakeIndex];
        require(stakeData.amount > 0, "No active stake");

        stakeData.isAutoFarming = !stakeData.isAutoFarming;
        emit AutoFarmingToggled(msg.sender, stakeIndex, stakeData.isAutoFarming);
    }

    /**
     * @notice Hitung reward
     */
    function calculateReward(address user, uint256 stakeIndex) public view returns (uint256) {
        UserStake memory userStake = userStakes[user][stakeIndex];
        if (userStake.amount == 0) return 0;

        FarmPackage memory package = farmPackages[userStake.packageId];
        uint256 timeStaked = block.timestamp - userStake.lastClaimTime;
        uint256 rewardPerYear = (userStake.amount * package.apy) / 10000;
        return (rewardPerYear * timeStaked) / 365 days;
    }

    /**
     * @notice Tambahkan paket farming baru
     */
    function addFarmPackage(
        address stakeToken,
        uint256 duration,
        uint256 apy,
        uint256 minStake
    ) external onlyOwner {
        farmPackages.push(FarmPackage({
            stakeToken: stakeToken,
            duration: duration,
            apy: apy,
            minStake: minStake,
            isActive: true
        }));
        emit PackageAdded(farmPackages.length - 1, stakeToken, duration, apy, minStake, true);
    }

    /**
     * @notice Aktif/nonaktifkan paket farming
     */
    function toggleFarmPackage(uint256 packageId, bool isActive) external onlyOwner {
        require(packageId < farmPackages.length, "Invalid package ID");
        farmPackages[packageId].isActive = isActive;
    }

    /**
     * @notice Atur ulang APY untuk paket tertentu
     */
    function setAPY(uint256 packageId, uint256 newAPY) external onlyOwner {
        require(packageId < farmPackages.length, "Invalid package ID");
        FarmPackage storage package = farmPackages[packageId];
        uint256 oldAPY = package.apy;
        package.apy = newAPY;

        emit PackageAPYUpdated(packageId, oldAPY, newAPY);
    }

    /**
     * @notice Set fee untuk auto farming
     */
    function setAutoFarmingFee(uint256 fee) external onlyOwner {
        require(fee <= 1000, "Max fee is 10%");
        autoFarmingFee = fee;
    }

    /**
     * @notice Update wallet penerima fee
     */
    function setTreasuryWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "Zero address not allowed");
        treasuryWallet = newWallet;
        emit FeeReceiverUpdated(newWallet);
    }

    /**
     * @notice Owner dapat menarik biaya auto farming
     */
    function withdrawFees() external onlyOwner {
        uint256 amount = autoFarmingPool;
        require(amount > 0, "No fees to withdraw");
        autoFarmingPool = 0;
        cafiToken.safeTransfer(treasuryWallet, amount);
    }
}