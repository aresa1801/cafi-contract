// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

contract CarbonFiMarketplace is Ownable, ReentrancyGuard, ERC1155Holder {
    using SafeERC20 for IERC20;

    IERC20 public immutable cafiToken;
    IERC1155 public immutable carbonFiNFT;

    uint256 public constant FEE_PERCENT = 100; // 1% (100 basis points)
    uint256 public constant MIN_AMOUNT = 1;
    uint256 public constant MIN_PRICE = 1;
    
    address public feeWallet;
    
    struct Listing {
        address seller;
        uint256 tokenId;
        uint256 amount;
        uint256 pricePerItem;
    }

    mapping(uint256 => mapping(address => Listing)) public listings;

    event ItemListed(
        address indexed seller,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 pricePerItem
    );

    event ItemSold(
        address indexed seller,
        address indexed buyer,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 pricePerItem
    );

    event ListingCancelled(
        address indexed seller,
        uint256 indexed tokenId
    );

    event FeeWalletUpdated(address indexed newFeeWallet);

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

        listings[tokenId][msg.sender] = Listing({
            seller: msg.sender,
            tokenId: tokenId,
            amount: amount,
            pricePerItem: pricePerItem
        });

        emit ItemListed(msg.sender, tokenId, amount, pricePerItem);
    }

    function buyItem(
        address seller,
        uint256 tokenId,
        uint256 amount
    ) external nonReentrant {
        Listing storage listing = listings[tokenId][seller];
        require(listing.amount >= amount, "Insufficient amount listed");
        require(
            carbonFiNFT.balanceOf(seller, tokenId) >= amount,
            "Seller no longer owns NFT"
        );

        uint256 totalPrice = listing.pricePerItem * amount;
        uint256 feeAmount = (totalPrice * FEE_PERCENT) / 10000;
        uint256 sellerAmount = totalPrice - feeAmount;

        cafiToken.safeTransferFrom(msg.sender, feeWallet, feeAmount);
        cafiToken.safeTransferFrom(msg.sender, seller, sellerAmount);

        carbonFiNFT.safeTransferFrom(seller, msg.sender, tokenId, amount, "");

        listing.amount -= amount;
        if (listing.amount == 0) {
            delete listings[tokenId][seller];
        }

        emit ItemSold(seller, msg.sender, tokenId, amount, listing.pricePerItem);
    }

    function cancelListing(uint256 tokenId) external nonReentrant {
        require(listings[tokenId][msg.sender].amount > 0, "No active listing");
        delete listings[tokenId][msg.sender];
        emit ListingCancelled(msg.sender, tokenId);
    }

    function setFeeWallet(address _feeWallet) external onlyOwner {
        require(_feeWallet != address(0), "Invalid fee wallet");
        feeWallet = _feeWallet;
        emit FeeWalletUpdated(_feeWallet);
    }

    function emergencyWithdraw(
        address tokenAddress,
        uint256 amount
    ) external onlyOwner {
        IERC20(tokenAddress).safeTransfer(owner(), amount);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC1155Holder) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}