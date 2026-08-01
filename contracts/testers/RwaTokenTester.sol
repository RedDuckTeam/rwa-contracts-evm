// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {RwaToken} from "../token/RwaToken.sol";

/// @dev Lets the base contract's semantics be tested independently of the wBOND product.
contract RwaTokenTester is RwaToken {
    function initialize(
        string memory name_,
        string memory symbol_,
        address registry,
        address complianceRegistry_,
        bool startPaused
    ) external initializer {
        __RwaToken_init(name_, symbol_, registry, complianceRegistry_, startPaused);
    }
}
