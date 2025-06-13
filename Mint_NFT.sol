// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title CarbonNFT
 * @dev ERC1155 NFT contract for carbon offsetting projects with approval mechanism and fee distribution
 */
contract CarbonNFT is ERC1155, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ===================== Structs =====================
    struct ProjectData {
        string projectName;
        string projectType;
        string location;
        uint256 carbonReduction;
        string methodology;
        string documentHash;
        string imageHash;
    }

    struct Verifier {
        string name;
        address wallet;
        bool isActive;
    }

    struct MintParams {
        string projectName;
        string projectType;
        string location;
        uint256 carbonReduction;
        string methodology;
        string documentHash;
        string imageHash;
    }

    // ===================== State Variables =====================
    uint256 public constant MAX_NAME_LENGTH = 100;
    uint256 public constant MAX_VERIFIER_NAME_LENGTH = 50;

    uint256 public mintFee = 1000 * 1e18; // 1000 CAFI tokens
    address public immutable taxWallet;
    address public immutable managementWallet;
    address public immutable cafiToken;

    bool public autoApproveEnabled = true;
    bool public paused;

    uint256 private _currentTokenId = 1;
    Verifier[7] public verifiers;

    mapping(uint256 => ProjectData) public projects;
    mapping(uint256 => mapping(address => bool)) public approvals;

    // ===================== Events =====================
    event VerifierUpdated(uint256 indexed index, string name, address indexed wallet);
    event ProjectMinted(uint256 indexed tokenId, address indexed minter, string projectName);
    event ApprovalChanged(uint256 indexed tokenId, address indexed verifier, bool approved);
    event MintFeeUpdated(uint256 newFee);
    event AutoApproveToggled(bool status);
    event ContractPaused(bool status);

    // ===================== Modifiers =====================
    modifier onlyEOA() {
        require(tx.origin == msg.sender, "Only EOA can call");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract paused");
        _;
    }

    // ===================== Constructor =====================
    constructor(
        string memory _metadataURI,
        address _cafiToken,
        address _taxWallet,
        address _managementWallet
    ) ERC1155(_metadataURI) Ownable(msg.sender) ReentrancyGuard() {
        require(_cafiToken != address(0), "Invalid CAFI token");
        require(_taxWallet != address(0), "Invalid tax wallet");
        require(_managementWallet != address(0), "Invalid management wallet");

        cafiToken = _cafiToken;
        taxWallet = _taxWallet;
        managementWallet = _managementWallet;
    }

    // ===================== Core Functions =====================
    function mintCarbonNFT(MintParams calldata params, uint256 _verifierIndex)
        external
        nonReentrant
        whenNotPaused
        onlyEOA
    {
        // Input validation
        require(bytes(params.projectName).length > 0 && bytes(params.projectName).length <= MAX_NAME_LENGTH, "Invalid project name");
        require(params.carbonReduction > 0, "Carbon reduction must be > 0");
        require(_verifierIndex < 7, "Invalid verifier index");

        // Get current token ID before increment
        uint256 tokenId = _currentTokenId;

        // Check allowance
        uint256 allowance = IERC20(cafiToken).allowance(msg.sender, address(this));
        require(allowance >= mintFee, "Insufficient CAFI allowance");

        // Verifier checks
        Verifier memory v = verifiers[_verifierIndex];
        if (!autoApproveEnabled) {
            require(v.wallet != address(0), "Verifier not registered");
            require(approvals[tokenId][v.wallet], "Not approved by verifier");
        }

        // Transfer fee
        IERC20(cafiToken).safeTransferFrom(msg.sender, address(this), mintFee);
        _distributeFee(v.wallet);

        // Store project data
        projects[tokenId] = ProjectData({
            projectName: params.projectName,
            projectType: params.projectType,
            location: params.location,
            carbonReduction: params.carbonReduction,
            methodology: params.methodology,
            documentHash: params.documentHash,
            imageHash: params.imageHash
        });

        // Increment after storing data
        _currentTokenId += 1;

        // Mint NFT
        _mint(msg.sender, tokenId, 1, "");

        emit ProjectMinted(tokenId, msg.sender, params.projectName);
    }

    // ===================== Fee Distribution =====================
    function _distributeFee(address _verifierWallet) private {
        uint256 totalFee = mintFee;
        uint256 verifierShare = (totalFee * 20) / 100;
        uint256 taxShare = (totalFee * 10) / 100;
        uint256 managementShare = totalFee - verifierShare - taxShare;

        if (_verifierWallet != address(0)) {
            IERC20(cafiToken).safeTransfer(_verifierWallet, verifierShare);
        } else {
            managementShare += verifierShare;
        }

        IERC20(cafiToken).safeTransfer(taxWallet, taxShare);
        IERC20(cafiToken).safeTransfer(managementWallet, managementShare);
    }

    // ===================== Admin Functions =====================
    function setVerifier(
        uint256 _index,
        string calldata _name,
        address _wallet
    ) external onlyOwner {
        require(_index < 7, "Invalid index");
        require(bytes(_name).length <= MAX_VERIFIER_NAME_LENGTH, "Name too long");
        require(_wallet != address(0), "Zero address not allowed");

        verifiers[_index] = Verifier(_name, _wallet, true);
        emit VerifierUpdated(_index, _name, _wallet);
    }

    function setMintFee(uint256 _newFee) external onlyOwner {
        require(_newFee > 0, "Fee must > 0");
        mintFee = _newFee;
        emit MintFeeUpdated(_newFee);
    }

    function toggleAutoApprove() external onlyOwner {
        autoApproveEnabled = !autoApproveEnabled;
        emit AutoApproveToggled(autoApproveEnabled);
    }

    function togglePause() external onlyOwner {
        paused = !paused;
        emit ContractPaused(paused);
    }

    // ===================== Approval Functions =====================
    function approveProject(uint256 _tokenId, bool _approved) external nonReentrant {
        bool isVerifier = false;
        for (uint256 i = 0; i < verifiers.length; i++) {
            if (verifiers[i].wallet == msg.sender && verifiers[i].isActive) {
                isVerifier = true;
                break;
            }
        }
        require(isVerifier, "Not an active verifier");

        approvals[_tokenId][msg.sender] = _approved;
        emit ApprovalChanged(_tokenId, msg.sender, _approved);
    }

    // ===================== Utility Functions =====================
    function estimateMintGas() external pure returns (uint256) {
        return 200_000;
    }

    function getCurrentTokenId() external view returns (uint256) {
        return _currentTokenId;
    }

    function getVerifier(uint256 index) external view returns (Verifier memory) {
        require(index < 7, "Index out of bounds");
        return verifiers[index];
    }

    function isApprovedByVerifier(uint256 tokenId, address verifierAddress) external view returns (bool) {
        return approvals[tokenId][verifierAddress];
    }
}