// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

/// @dev Three independently switchable hazards: an `approve` that returns nothing, an optional
///      transfer fee, and its own blacklist. Deliberately not built on OZ's ERC20, so `approve`
///      can drop its return value.
contract MockUSDT {
    error InsufficientBalance();
    error InsufficientAllowance();
    error BlockedAccount(address account);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    string public constant NAME = "Mock Tether USD";
    string public constant SYMBOL = "USDT";
    uint8 public constant DECIMALS = 6;

    uint256 public totalSupply;
    uint256 public transferFeeBps;

    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 value)) public allowance;
    /// @dev Mirrors USDC/USDT issuer controls.
    mapping(address account => bool blocked) public isBlocked;

    function name() external pure returns (string memory) {
        return NAME;
    }

    function symbol() external pure returns (string memory) {
        return SYMBOL;
    }

    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    function setTransferFeeBps(uint256 bps) external {
        transferFeeBps = bps;
    }

    function setBlocked(address account, bool blocked) external {
        isBlocked[account] = blocked;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @dev Returns nothing, exactly like USDT on mainnet.
    function approve(address spender, uint256 value) external {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        if (isBlocked[from]) revert BlockedAccount(from);
        if (isBlocked[to]) revert BlockedAccount(to);
        if (balanceOf[from] < value) revert InsufficientBalance();

        uint256 fee = (value * transferFeeBps) / 10_000;
        uint256 received = value - fee;

        balanceOf[from] -= value;
        balanceOf[to] += received;
        if (fee != 0) totalSupply -= fee;

        emit Transfer(from, to, received);
    }
}
