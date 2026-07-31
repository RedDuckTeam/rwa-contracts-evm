// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Models the hazard of a vault accepting an arbitrary ERC-20: the token runs code during
///      `transferFrom`, while the vault is half way through its accounting. The callback fires
///      once and disarms itself, so the vault has to reject a single reentrant call rather than
///      an infinite recursion.
contract ReentrantPaymentToken is ERC20 {
    address public target;
    bytes public payload;
    bool public armed;

    /// @dev Bubbles up whatever the reentrant call reverted with, so a test can assert on the
    ///      vault's own error rather than a generic failure.
    error ReentrancyRejected(bytes reason);

    constructor() ERC20("Reentrant USD", "rUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        if (!armed) return;
        armed = false;

        (bool ok, bytes memory reason) = target.call(payload);
        if (!ok) revert ReentrancyRejected(reason);
    }
}
