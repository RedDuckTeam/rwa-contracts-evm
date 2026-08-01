// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {RwaToken} from "../../token/RwaToken.sol";

/// @dev The reference product, and intentionally almost empty: a fork's product contract
///      fixes the name and symbol and nothing else. A fork editing {RwaToken} instead of this
///      file has almost certainly taken a wrong turn.
///
///      If several products share one {AccessRegistry}, this subclass MUST also override
///      `minterRole`, `burnerRole` and `refundVaultRole` with product-namespaced ids.
contract WbondToken is RwaToken {
    function initialize(
        address registry,
        address complianceRegistry_,
        bool startPaused
    ) external initializer {
        __RwaToken_init("Whitelabel Bond Token", "wBOND", registry, complianceRegistry_, startPaused);
    }
}
