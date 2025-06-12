// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title CarbonFi (CAFI)
 * @dev ERC20 Token for CarbonFi with Max Wallet Limit and Excluded Addresses
 */
contract CarbonFi is ERC20, Ownable, Pausable {
    using SafeERC20 for IERC20;

    uint256 public constant INITIAL_SUPPLY = 999_999_999 * 1e18; // 999.999.999 tokens
    uint256 public constant MAX_WALLET = (INITIAL_SUPPLY * 5) / 100; // 5% of supply

    mapping(address => bool) public excludedFromMaxWallet;
    address[5] private _excludedWallets; // Private untuk hindari akses langsung
    uint256 private _excludedWalletsCount; // Counter state variable

    /**
     * @notice Emitted when an account is excluded from max wallet limit
     */
    event ExcludedFromMaxWallet(address indexed account);

    /**
     * @notice Emitted when an account is included back into max wallet restriction
     */
    event IncludedInMaxWallet(address indexed account);

    /**
     * @notice Emitted when token is burned by owner
     */
    event OwnerBurned(address indexed account, uint256 amount);

    constructor() ERC20("CarbonFi", "CAFI") Ownable(msg.sender) {
        _mint(owner(), INITIAL_SUPPLY);
    }

    /**
     * @notice Exclude account from max wallet restriction
     * @param account Address to exclude
     */
    function excludeFromMaxWallet(address account) external onlyOwner {
        require(account != address(0), "Zero address not allowed");
        require(!excludedFromMaxWallet[account], "Already excluded");
        require(excludedWalletsCount() < 5, "Max 5 excluded wallets allowed");

        excludedFromMaxWallet[account] = true;

        bool added = false;
        for (uint256 i = 0; i < 5; i++) {
            if (_excludedWallets[i] == address(0)) {
                _excludedWallets[i] = account;
                _excludedWalletsCount += 1;
                added = true;
                break;
            }
        }
        require(added, "Excluded list full");

        emit ExcludedFromMaxWallet(account);
    }

    /**
     * @notice Include account in max wallet restriction
     * @param account Address to include
     */
    function includeInMaxWallet(address account) external onlyOwner {
        require(account != address(0), "Zero address not allowed");
        require(excludedFromMaxWallet[account], "Not excluded");

        excludedFromMaxWallet[account] = false;

        bool removed = false;
        for (uint256 i = 0; i < 5; i++) {
            if (_excludedWallets[i] == account) {
                _excludedWallets[i] = address(0);
                _excludedWalletsCount -= 1;
                removed = true;
                break;
            }
        }
        require(removed, "Account not found in excluded list");

        emit IncludedInMaxWallet(account);
    }

    /**
     * @notice Pause all token transfers
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause all token transfers
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Burn tokens from a specific account (owner only)
     * @param account Account to burn from
     * @param amount Amount to burn
     */
    function ownerBurnFrom(address account, uint256 amount) external onlyOwner {
        require(account != address(0), "Zero address not allowed");
        require(amount > 0, "Zero amount not allowed");

        _burn(account, amount);
        emit OwnerBurned(account, amount);
    }

    /**
     * @notice Transfer tokens and enforce max wallet limit
     */
    function transfer(address to, uint256 amount) public override whenNotPaused returns (bool) {
        _checkMaxWallet(to, amount);
        return super.transfer(to, amount);
    }

    /**
     * @notice Transfer tokens from one account to another
     */
    function transferFrom(address from, address to, uint256 amount) public override whenNotPaused returns (bool) {
        _checkMaxWallet(to, amount);
        return super.transferFrom(from, to, amount);
    }

    /**
     * @dev Internal check for max wallet limit
     */
    function _checkMaxWallet(address to, uint256 amount) internal view {
        if (!excludedFromMaxWallet[to]) {
            require(balanceOf(to) + amount <= MAX_WALLET, "Max wallet limit exceeded");
        }
    }

    /**
     * @dev Count how many excluded wallets are set (via state variable)
     */
    function excludedWalletsCount() public view returns (uint256) {
        return _excludedWalletsCount;
    }

    /**
     * @dev Get excluded wallet at index
     */
    function getExcludedWallet(uint256 index) public view returns (address) {
        require(index < 5, "Index out of bounds");
        address account = _excludedWallets[index];
        require(account != address(0), "Account not found");
        return account;
    }
}