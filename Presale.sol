// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract CarbonFiPresale is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ======== TOKEN CONFIG ========
    IERC20 public immutable usdt; // USDT di Arbitrum
    IERC20 public immutable cafi; // CAFI token
    address public immutable treasury;

    uint256 public constant TOTAL_PRESALE_SUPPLY = 10_000_000 * 1e18; // 1% dari 999.999.999
    uint256 public constant MAX_BUY_PER_WALLET = 1_000_000 * 1e18;
    uint256 public constant PRESALE_DURATION = 90 days;

    // ======== STAGE CONFIG ========
    struct Stage {
        uint256 totalAmount;
        uint256 soldAmount;
        uint256 price; // USDT per 1 CAFI (18 decimals)
        bool isActive;
    }

    Stage[] public stages;
    uint256 public currentStage;
    uint256 public presaleStartTime;
    bool public presaleEnded;

    // ======== TRACKING ========
    uint256 public totalSold;
    mapping(address => uint256) public userPurchases;

    // ======== EVENTS ========
    event TokensPurchased(address indexed buyer, uint256 amount, uint256 usdtAmount);
    event StageAdvanced(uint256 newStage);
    event PresaleEnded(uint256 totalSold, uint256 remainingBalance);
    event TokensClaimed(address indexed user, uint256 amount);

    // ======== MODIFIERS ========
    modifier onlyActivePresale() {
        require(!presaleEnded, "Presale sudah berakhir");
        require(block.timestamp >= presaleStartTime, "Presale belum dimulai");
        require(block.timestamp <= presaleStartTime + PRESALE_DURATION, "Presale sudah berakhir");
        _;
    }

    // ======== CONSTRUCTOR ========
    constructor(
        address _usdt,
        address _cafi,
        address _treasury,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_usdt != address(0) && _cafi != address(0) && _treasury != address(0), "Alamat tidak valid");
        
        usdt = IERC20(_usdt);
        cafi = IERC20(_cafi);
        treasury = _treasury;

        // Setup stages
        stages.push(Stage(4_000_000 * 1e18, 0, 0.05 * 1e18, false)); // $0.05
        stages.push(Stage(3_000_000 * 1e18, 0, 0.075 * 1e18, false)); // $0.075
        stages.push(Stage(3_000_000 * 1e18, 0, 0.1 * 1e18, false)); // $0.10
    }

    // ======== CORE FUNCTIONS ========
    function startPresale() external onlyOwner {
        require(presaleStartTime == 0, "Presale sudah dimulai");
        presaleStartTime = block.timestamp;
        stages[0].isActive = true;
    }

    function buyTokens(uint256 amount) external nonReentrant onlyActivePresale {
        require(amount > 0, "Jumlah tidak valid");
        require(
            userPurchases[msg.sender] + amount <= MAX_BUY_PER_WALLET,
            "Melebihi batas pembelian"
        );

        Stage storage current = stages[currentStage];
        require(current.isActive, "Stage tidak aktif");
        require(current.soldAmount + amount <= current.totalAmount, "Melebihi kuota stage");

        uint256 usdtAmount = amount * current.price / 1e18;
        
        // Transfer USDT dari pembeli
        usdt.safeTransferFrom(msg.sender, treasury, usdtAmount);

        // Update records
        current.soldAmount += amount;
        totalSold += amount;
        userPurchases[msg.sender] += amount;

        // Auto-claim jika stage selesai
        if (current.soldAmount >= current.totalAmount) {
            _advanceStage();
        }

        emit TokensPurchased(msg.sender, amount, usdtAmount);
    }

    function claimTokens() external nonReentrant {
        require(presaleEnded || block.timestamp > presaleStartTime + PRESALE_DURATION, "Belum bisa claim");
        
        uint256 amount = userPurchases[msg.sender];
        require(amount > 0, "Tidak ada token untuk di-claim");

        userPurchases[msg.sender] = 0;
        cafi.safeTransfer(msg.sender, amount);

        emit TokensClaimed(msg.sender, amount);
    }

    // ======== ADMIN FUNCTIONS ========
    function endPresale() external onlyOwner {
        require(!presaleEnded, "Presale sudah diakhiri");
        
        presaleEnded = true;
        uint256 remaining = cafi.balanceOf(address(this));
        
        if (remaining > 0) {
            cafi.safeTransfer(owner(), remaining);
        }

        emit PresaleEnded(totalSold, remaining);
    }

    // ======== INTERNAL FUNCTIONS ========
    function _advanceStage() internal {
        stages[currentStage].isActive = false;
        
        if (currentStage < stages.length - 1) {
            currentStage++;
            stages[currentStage].isActive = true;
            emit StageAdvanced(currentStage);
        } else {
            presaleEnded = true;
            emit PresaleEnded(totalSold, cafi.balanceOf(address(this)));
        }
    }

    // ======== VIEW FUNCTIONS ========
    function getCurrentStageInfo() external view returns (
        uint256 stage,
        uint256 price,
        uint256 available,
        uint256 sold
    ) {
        Stage memory current = stages[currentStage];
        return (
            currentStage,
            current.price,
            current.totalAmount - current.soldAmount,
            current.soldAmount
        );
    }

    function getPresaleTimeLeft() external view returns (uint256) {
        if (presaleStartTime == 0) return 0;
        if (block.timestamp >= presaleStartTime + PRESALE_DURATION) return 0;
        return (presaleStartTime + PRESALE_DURATION) - block.timestamp;
    }
}