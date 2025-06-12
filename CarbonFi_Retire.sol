// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title CarbonFi Retirement Contract
 * @dev Contract for retiring CarbonFi NFTs and generating certificate metadata
 */
contract CarbonFiRetirement is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    // Interfaces
    IERC20 public immutable cafiToken;
    IERC1155 public immutable carbonFiNFT;

    // Retirement fee structure
    uint256 public retireFee = 50 * 1e18; // 50 CAFI (18 decimals)
    address public founderWallet;
    address public taxFeeWallet;

    // Pending withdrawals (Pull over Push Pattern)
    mapping(address => uint256) public pendingFounderWithdrawals;
    mapping(address => uint256) public pendingTaxFeeWithdrawals;

    // Retirement tracking
    struct RetirementRecord {
        address retirer;
        uint256 tokenId;
        uint256 amount;
        uint256 timestamp;
        string certificateId;
        string certificateURI;
    }

    mapping(string => RetirementRecord) public retirementCertificates;
    mapping(uint256 => uint256) public totalRetiredByTokenId;

    // Events
    event NFTRetired(
        address indexed retirer,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 feePaid,
        string certificateId,
        string certificateURI
    );

    event FeeDistribution(
        address indexed founder,
        address indexed taxCollector,
        uint256 founderShare,
        uint256 taxFeeAmount
    );

    event FeeWithdrawn(address indexed wallet, uint256 amount);

    constructor(
        address _cafiToken,
        address _carbonFiNFT,
        address _founderWallet,
        address _taxFeeWallet,
        address _initialOwner
    ) Ownable(_initialOwner) ReentrancyGuard() {
        require(_cafiToken != address(0), "Invalid CAFI token");
        require(_carbonFiNFT != address(0), "Invalid NFT contract");
        require(_founderWallet != address(0), "Invalid founder wallet");
        require(_taxFeeWallet != address(0), "Invalid tax fee wallet");

        cafiToken = IERC20(_cafiToken);
        carbonFiNFT = IERC1155(_carbonFiNFT);
        founderWallet = _founderWallet;
        taxFeeWallet = _taxFeeWallet;
    }

    /**
     * @notice Retire NFT dan hasilkan sertifikat
     * @param tokenId ID NFT yang ingin diretire
     * @param amount Jumlah NFT yang ingin diretire
     */
    function retireNFT(uint256 tokenId, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        require(carbonFiNFT.balanceOf(msg.sender, tokenId) >= amount, "Insufficient NFT balance");
        require(carbonFiNFT.isApprovedForAll(msg.sender, address(this)), "Contract not approved");
        require(cafiToken.balanceOf(msg.sender) >= retireFee, "Insufficient CAFI balance");

        // Generate unique certificate ID
        string memory certificateId = string.concat(
            "CRT-",
            Strings.toString(block.chainid),
            "-",
            Strings.toHexString(uint256(uint160(msg.sender))),
            "-",
            Strings.toString(tokenId),
            "-",
            Strings.toString(block.timestamp)
        );

        // Transfer fee
        cafiToken.safeTransferFrom(msg.sender, address(this), retireFee);

        // Distribute fees
        _distributeFee();

        // Burn the NFT
        carbonFiNFT.safeTransferFrom(
            msg.sender,
            0x000000000000000000000000000000000000dEaD,
            tokenId,
            amount,
            ""
        );

        // Record retirement
        string memory certificateURI = string.concat("ipfs://certificates/", certificateId, ".json");

        retirementCertificates[certificateId] = RetirementRecord({
            retirer: msg.sender,
            tokenId: tokenId,
            amount: amount,
            timestamp: block.timestamp,
            certificateId: certificateId,
            certificateURI: certificateURI
        });

        totalRetiredByTokenId[tokenId] += amount;

        emit NFTRetired(
            msg.sender,
            tokenId,
            amount,
            retireFee,
            certificateId,
            certificateURI
        );
    }

    /**
     * @dev Distribusi fee: 10% tax, 90% ke founder
     */
    function _distributeFee() private {
        uint256 fee = retireFee;

        uint256 taxAmount = (fee * 10) / 100;
        uint256 founderAmount = fee - taxAmount;

        pendingTaxFeeWithdrawals[taxFeeWallet] += taxAmount;
        pendingFounderWithdrawals[founderWallet] += founderAmount;

        emit FeeDistribution(founderWallet, taxFeeWallet, founderAmount, taxAmount);
    }

    /**
     * @notice Withdraw pending fees
     */
    function withdrawPendingFees() external nonReentrant {
        uint256 amount = pendingFounderWithdrawals[msg.sender];
        if (amount > 0) {
            pendingFounderWithdrawals[msg.sender] = 0;
            cafiToken.safeTransfer(msg.sender, amount);
            emit FeeWithdrawn(msg.sender, amount);
        }

        amount = pendingTaxFeeWithdrawals[msg.sender];
        if (amount > 0) {
            pendingTaxFeeWithdrawals[msg.sender] = 0;
            cafiToken.safeTransfer(msg.sender, amount);
            emit FeeWithdrawn(msg.sender, amount);
        }
    }

    /**
     * @notice Update retirement fee
     */
    function setRetireFee(uint256 newFee) external onlyOwner {
        retireFee = newFee;
    }

    /**
     * @notice Set founder wallet
     */
    function setFounderWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "Zero address not allowed");
        founderWallet = newWallet;
    }

    /**
     * @notice Set tax fee wallet
     */
    function setTaxFeeWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "Zero address not allowed");
        taxFeeWallet = newWallet;
    }

    /**
     * @notice Get certificate URI (simulasi cetak PDF)
     */
    function getCertificateURI(string memory certificateId) external view returns (string memory) {
        return retirementCertificates[certificateId].certificateURI;
    }

    /**
     * @notice Verify retirement by certificate ID
     */
    function verifyRetirement(string memory certificateId) external view returns (bool) {
        return bytes(retirementCertificates[certificateId].certificateId).length > 0;
    }

    /**
     * @notice Get total retired by token ID
     */
    function getTotalRetired(uint256 tokenId) external view returns (uint256) {
        return totalRetiredByTokenId[tokenId];
    }
}