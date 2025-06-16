// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

contract CarbonFiMarketplace is Ownable2Step, ReentrancyGuard, ERC1155Holder {
    using SafeERC20 for IERC20;

    // ========== CONSTANTS ==========
    uint256 public constant FEE_PERCENT = 100; // 1% (100 basis points)
    uint256 public constant FEE_DENOMINATOR = 10000; // 100% = 10000 bps
    uint256 public constant MIN_AMOUNT = 1;
    uint256 public constant MIN_PRICE = 1e15; // 0.001 CAFI minimum price

    // ========== IMMUTABLES ==========
    IERC20 public immutable cafiToken;
    IERC1155 public immutable carbonFiNFT;

    // ========== STATE VARIABLES ==========
    address public feeWallet;
    
    struct Listing {
        address seller;
        uint256 tokenId;
        uint256 amount;
        uint256 pricePerItem;
        uint256 listingFeePaid;
    }

    mapping(uint256 => mapping(address => Listing)) public listings;

    // ========== EVENTS ==========
    event ItemListed(
        address indexed seller,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 pricePerItem,
        uint256 listingFee
    );

    event ItemSold(
        address indexed seller,
        address indexed buyer,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 pricePerItem,
        uint256 buyFee
    );

    event ListingCancelled(
        address indexed seller,
        uint256 indexed tokenId,
        uint256 refundedFee
    );

    event FeeWalletUpdated(address indexed newFeeWallet);

    // ========== MODIFIERS ==========
    modifier validListing(address seller, uint256 tokenId, uint256 amount) {
        Listing storage listing = listings[tokenId][seller];
        require(listing.amount >= amount, "Insufficient amount listed");
        require(
            carbonFiNFT.balanceOf(address(this), tokenId) >= amount,
            "NFT not available in escrow"
        );
        _;
    }

    // ========== CONSTRUCTOR ==========
    constructor(
        address _cafiToken,
        address _carbonFiNFT,
        address _feeWallet
    ) Ownable(msg.sender) {
        require(_cafiToken != address(0), "Invalid CAFI token");
        require(_carbonFiNFT != address(0), "Invalid NFT contract");
        require(_feeWallet != address(0), "Invalid fee wallet");
        
        cafiToken = IERC20(_cafiToken);
        carbonFiNFT = IERC1155(_carbonFiNFT);
        feeWallet = _feeWallet;
    }

    // ========== MAIN FUNCTIONS ==========

    /**
     * @notice List NFTs with 1% listing fee of total value
     * @dev Transfers NFT to escrow and collects 1% fee of (amount × price)
     */
    function listItem(
        uint256 tokenId,
        uint256 amount,
        uint256 pricePerItem
    ) external nonReentrant {
        require(amount >= MIN_AMOUNT, "Amount too small");
        require(pricePerItem >= MIN_PRICE, "Price too low");
        require(
            carbonFiNFT.balanceOf(msg.sender, tokenId) >= amount,
            "Insufficient NFT balance"
        );
        require(
            carbonFiNFT.isApprovedForAll(msg.sender, address(this)),
            "Marketplace not approved"
        );

        // Calculate 1% listing fee
        uint256 totalValue = amount * pricePerItem;
        uint256 listingFee = (totalValue * FEE_PERCENT) / FEE_DENOMINATOR;

        // Transfer fee and NFT
        cafiToken.safeTransferFrom(msg.sender, feeWallet, listingFee);
        carbonFiNFT.safeTransferFrom(msg.sender, address(this), tokenId, amount, "");

        // Create listing
        listings[tokenId][msg.sender] = Listing({
            seller: msg.sender,
            tokenId: tokenId,
            amount: amount,
            pricePerItem: pricePerItem,
            listingFeePaid: listingFee
        });

        emit ItemListed(msg.sender, tokenId, amount, pricePerItem, listingFee);
    }

    /**
     * @notice Buy NFTs with 1% transaction fee
     * @dev Transfers 99% to seller, 1% to fee wallet, and NFT to buyer
     */
    function buyItem(
        address seller,
        uint256 tokenId,
        uint256 amount
    ) external nonReentrant validListing(seller, tokenId, amount) {
        Listing storage listing = listings[tokenId][seller];

        // Calculate payment amounts
        uint256 totalPrice = listing.pricePerItem * amount;
        uint256 buyFee = (totalPrice * FEE_PERCENT) / FEE_DENOMINATOR;
        uint256 sellerAmount = totalPrice - buyFee;

        // Transfer payments
        cafiToken.safeTransferFrom(msg.sender, feeWallet, buyFee);
        cafiToken.safeTransferFrom(msg.sender, seller, sellerAmount);

        // Transfer NFT
        carbonFiNFT.safeTransferFrom(address(this), msg.sender, tokenId, amount, "");

        // Update listing
        listing.amount -= amount;
        if (listing.amount == 0) {
            delete listings[tokenId][seller];
        }

        emit ItemSold(seller, msg.sender, tokenId, amount, listing.pricePerItem, buyFee);
    }

    /**
     * @notice Cancel listing and refund proportional fee
     */
    function cancelListing(uint256 tokenId) external nonReentrant {
        Listing memory listing = listings[tokenId][msg.sender];
        require(listing.amount > 0, "No active listing");

        // Calculate refund (1% of remaining value)
        uint256 remainingValue = listing.amount * listing.pricePerItem;
        uint256 refundAmount = (remainingValue * FEE_PERCENT) / FEE_DENOMINATOR;

        // Return NFT and refund
        carbonFiNFT.safeTransferFrom(address(this), msg.sender, tokenId, listing.amount, "");
        if (refundAmount > 0) {
            cafiToken.safeTransferFrom(feeWallet, msg.sender, refundAmount);
        }

        delete listings[tokenId][msg.sender];
        emit ListingCancelled(msg.sender, tokenId, refundAmount);
    }

    // ========== ADMIN FUNCTIONS ==========
    function setFeeWallet(address newFeeWallet) external onlyOwner {
        require(newFeeWallet != address(0), "Invalid wallet");
        feeWallet = newFeeWallet;
        emit FeeWalletUpdated(newFeeWallet);
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
}