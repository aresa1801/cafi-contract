// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title CarbonNFT - Carbon Offset Certificate
 * @notice ERC1155 implementation where 1 token = 1 ton of CO₂ offset
 * @dev Features batch minting, verifier approvals, and fee distribution
 */
contract CarbonNFT is ERC1155, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    // ========== CONSTANTS ==========
    uint256 public constant MAX_NAME_LENGTH = 100;
    uint256 public constant MAX_VERIFIER_NAME_LENGTH = 50;
    uint256 public constant MAX_BATCH_SIZE = 100_000; // Max 100,000 tons per transaction
    uint256 public constant MAX_DURATION = 3650 days; // ~10 years maximum
    uint256 public constant VERIFIER_COUNT = 7; // Fixed number of verifiers

    // ========== STATE VARIABLES ==========
    uint256 public mintFeePerTon = 1000 * 1e18; // 1000 CAFI tokens per ton
    address public immutable taxWallet; // 10% fee
    address public immutable managementWallet; // 70% fee
    IERC20 public immutable cafiToken; // Payment token

    bool public autoApproveEnabled = true; // Bypass verifier approval if true
    uint256 private _currentTokenId = 1; // Auto-incrementing token ID

    // Project data structure
    struct ProjectData {
        string projectName;
        string projectType;
        string location;
        uint256 carbonReduction; // Total tons minted
        string methodology;
        string documentHash;
        string imageCID; // IPFS content identifier
        uint256 startDate;
        uint256 endDate;
        address creator;
    }

    // Verifier data structure
    struct Verifier {
        string name;
        address wallet;
        bool isActive;
    }

    // Mint parameters structure to avoid stack too deep
    struct MintParams {
        string projectName;
        string projectType;
        string location;
        uint256 carbonTons;
        string methodology;
        string documentHash;
        string imageCID;
        uint256 durationDays;
        uint256 verifierIndex;
    }

    Verifier[VERIFIER_COUNT] public verifiers;
    mapping(uint256 => ProjectData) private _projects;
    mapping(uint256 => mapping(address => bool)) private _approvals;

    // ========== EVENTS ==========
    event VerifierUpdated(uint256 indexed index, string name, address indexed wallet);
    event ProjectMinted(
        uint256 indexed tokenId,
        address indexed creator,
        string projectName,
        uint256 carbonTons,
        uint256 startDate,
        uint256 endDate,
        string imageCID
    );
    event ApprovalChanged(uint256 indexed tokenId, address indexed verifier, bool approved);
    event MintFeeUpdated(uint256 newFeePerTon);
    event AutoApproveToggled(bool status);
    event EmergencyWithdraw(address indexed token, uint256 amount);

    // ========== MODIFIERS ==========
    modifier onlyEOA() {
        require(tx.origin == msg.sender, "CarbonNFT: Only EOA");
        _;
    }

    modifier validVerifierIndex(uint256 index) {
        require(index < VERIFIER_COUNT, "CarbonNFT: Invalid verifier");
        _;
    }

    // ========== CONSTRUCTOR ==========
    constructor(
        string memory _baseURI,
        address _cafiToken,
        address _taxWallet,
        address _managementWallet,
        address _initialOwner
    ) ERC1155(_baseURI) Ownable(_initialOwner) {
        require(_cafiToken != address(0), "CarbonNFT: Invalid CAFI");
        require(_taxWallet != address(0), "CarbonNFT: Invalid tax wallet");
        require(_managementWallet != address(0), "CarbonNFT: Invalid mgmt wallet");
        require(_initialOwner != address(0), "CarbonNFT: Invalid owner");

        cafiToken = IERC20(_cafiToken);
        taxWallet = _taxWallet;
        managementWallet = _managementWallet;
    }

    // ========== CORE FUNCTIONS ==========

    /**
     * @notice Mint new carbon offset certificates using params struct
     * @param params MintParams struct containing all minting parameters
     */
    function mintCarbonNFT(MintParams calldata params) 
        external 
        nonReentrant 
        whenNotPaused 
        onlyEOA 
        validVerifierIndex(params.verifierIndex) 
    {
        // Input validation
        require(bytes(params.projectName).length > 0, "CarbonNFT: Name required");
        require(bytes(params.projectName).length <= MAX_NAME_LENGTH, "CarbonNFT: Name too long");
        require(params.carbonTons > 0 && params.carbonTons <= MAX_BATCH_SIZE, "CarbonNFT: Invalid tons");
        require(params.durationDays >= 1 && params.durationDays * 1 days <= MAX_DURATION, "CarbonNFT: Invalid duration");
        require(bytes(params.imageCID).length > 0, "CarbonNFT: Image CID required");

        uint256 tokenId = _currentTokenId++;
        uint256 totalFee = mintFeePerTon * params.carbonTons;
        uint256 endDate = block.timestamp + (params.durationDays * 1 days);

        // Fee collection and verification
        _validateAndCollectFees(params.verifierIndex, totalFee);

        // Create project record
        _projects[tokenId] = ProjectData({
            projectName: params.projectName,
            projectType: params.projectType,
            location: params.location,
            carbonReduction: params.carbonTons,
            methodology: params.methodology,
            documentHash: params.documentHash,
            imageCID: params.imageCID,
            startDate: block.timestamp,
            endDate: endDate,
            creator: msg.sender
        });

        // Mint tokens (1 NFT = 1 Ton CO₂)
        _mint(msg.sender, tokenId, params.carbonTons, "");

        emit ProjectMinted(
            tokenId,
            msg.sender,
            params.projectName,
            params.carbonTons,
            block.timestamp,
            endDate,
            params.imageCID
        );
    }

    // ========== INTERNAL FUNCTIONS ==========

    /**
     * @dev Validate verifier and collect minting fees
     */
    function _validateAndCollectFees(uint256 verifierIndex, uint256 totalFee) private {
        Verifier memory v = verifiers[verifierIndex];
        if (!autoApproveEnabled) {
            require(v.wallet != address(0), "CarbonNFT: Verifier inactive");
            require(_approvals[_currentTokenId][v.wallet], "CarbonNFT: Not approved");
        }

        uint256 allowance = cafiToken.allowance(msg.sender, address(this));
        require(allowance >= totalFee, "CarbonNFT: Insufficient allowance");
        cafiToken.safeTransferFrom(msg.sender, address(this), totalFee);
        
        _distributeFees(totalFee, v.wallet);
    }

    /**
     * @dev Distribute fees to verifier, tax, and management wallets
     */
    function _distributeFees(uint256 totalFee, address verifier) private {
        uint256 verifierShare = (totalFee * 20) / 100;
        uint256 taxShare = (totalFee * 10) / 100;
        uint256 managementShare = totalFee - verifierShare - taxShare;

        if (verifier != address(0)) {
            cafiToken.safeTransfer(verifier, verifierShare);
        } else {
            managementShare += verifierShare;
        }

        cafiToken.safeTransfer(taxWallet, taxShare);
        cafiToken.safeTransfer(managementWallet, managementShare);
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Add or update a verifier
     * @param index Verifier index (0-6)
     * @param name Verifier organization name
     * @param wallet Verifier wallet address
     */
    function setVerifier(
        uint256 index,
        string calldata name,
        address wallet
    ) external onlyOwner validVerifierIndex(index) {
        require(bytes(name).length <= MAX_VERIFIER_NAME_LENGTH, "CarbonNFT: Name too long");
        require(wallet != address(0), "CarbonNFT: Invalid wallet");
        
        verifiers[index] = Verifier(name, wallet, true);
        emit VerifierUpdated(index, name, wallet);
    }

    /**
     * @notice Update minting fee per ton
     * @param newFee New fee amount in CAFI tokens (per ton)
     */
    function setMintFeePerTon(uint256 newFee) external onlyOwner {
        require(newFee > 0, "CarbonNFT: Fee must > 0");
        mintFeePerTon = newFee;
        emit MintFeeUpdated(newFee);
    }

    /**
     * @notice Toggle automatic approval bypass
     */
    function toggleAutoApprove() external onlyOwner {
        autoApproveEnabled = !autoApproveEnabled;
        emit AutoApproveToggled(autoApproveEnabled);
    }

    /**
     * @notice Pause/unpause contract
     */
    function togglePause() external onlyOwner {
        paused() ? _unpause() : _pause();
    }

    /**
     * @notice Emergency withdraw tokens
     * @param token Token contract address
     */
    function emergencyWithdraw(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(owner(), balance);
        emit EmergencyWithdraw(token, balance);
    }

    // ========== VERIFIER FUNCTIONS ==========

    /**
     * @notice Approve/reject a project
     * @param tokenId Project token ID
     * @param approved Approval status
     */
    function approveProject(uint256 tokenId, bool approved) external {
        bool isVerifier = false;
        for (uint256 i = 0; i < VERIFIER_COUNT; i++) {
            if (verifiers[i].wallet == msg.sender && verifiers[i].isActive) {
                isVerifier = true;
                break;
            }
        }
        require(isVerifier, "CarbonNFT: Not verifier");
        
        _approvals[tokenId][msg.sender] = approved;
        emit ApprovalChanged(tokenId, msg.sender, approved);
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Get NFT metadata URI
     * @param tokenId Project token ID
     * @return Metadata URI string
     */
    function uri(uint256 tokenId) public view override returns (string memory) {
        require(_projects[tokenId].endDate > 0, "CarbonNFT: Nonexistent token");
        return string(abi.encodePacked(super.uri(tokenId), _projects[tokenId].imageCID));
    }

    /**
     * @notice Get project details
     * @param tokenId Project token ID
     * @return Project data structure
     */
    function getProject(uint256 tokenId) external view returns (ProjectData memory) {
        return _projects[tokenId];
    }

    /**
     * @notice Check verifier approval status
     * @param tokenId Project token ID
     * @param verifier Verifier address
     * @return Approval status
     */
    function isApproved(uint256 tokenId, address verifier) external view returns (bool) {
        return _approvals[tokenId][verifier];
    }

    /**
     * @notice Get current token ID counter
     * @return Current token ID
     */
    function getCurrentTokenId() external view returns (uint256) {
        return _currentTokenId;
    }
}