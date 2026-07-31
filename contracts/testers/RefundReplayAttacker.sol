// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {RwaToken} from "../token/RwaToken.sol";

/// @notice Stands in for a RedemptionVault holding `REFUND_VAULT_ROLE`, and tries to make
///         the refund carve-out authorise more than one transfer.
/// @dev The refund ticket lives in EIP-1153 transient storage, which is scoped to the
///      TRANSACTION rather than the call frame. If `_update` did not consume it, every
///      subsequent transfer in the same transaction would inherit the bypass. This
///      contract is the adversary that would exploit exactly that, so its tests are
///      regression guards for the ticket's one-shot property — not incidental coverage.
contract RefundReplayAttacker {
    RwaToken public immutable token;

    constructor(RwaToken token_) {
        token = token_;
    }

    /// @notice A legitimate refund. Must succeed even while transfers are paused.
    function refund(address to, uint256 amount) external {
        token.refundFromVault(to, amount);
    }

    /// @notice Refund, then attempt an ordinary transfer in the SAME transaction.
    /// @dev The second leg must hit the full gate set and revert whenever it would.
    function refundThenTransfer(address to, uint256 refundAmount, uint256 transferAmount) external {
        token.refundFromVault(to, refundAmount);
        token.transfer(to, transferAmount);
    }

    /// @notice Two refunds in one transaction. Both are separately authorised, so both
    ///         must succeed — the ticket is single-USE, not once-per-transaction.
    function refundTwice(address to, uint256 first, uint256 second) external {
        token.refundFromVault(to, first);
        token.refundFromVault(to, second);
    }

    /// @notice Refunds one amount, then attempts to move a different one.
    /// @dev Complements {refundThenTransfer}: the bypass must not survive into a transfer of
    ///      any size, not merely one of the same size.
    function refundThenTransferDifferentAmount(address to, uint256 ticketed, uint256 attempted) external {
        token.refundFromVault(to, ticketed);
        token.transfer(to, attempted);
    }

    /// @notice Enforcement transfer, then an ordinary transfer in the SAME transaction.
    /// @dev `forcedTransfer` is the STRONGER bypass — it skips sanctions and the frozen
    ///      check, neither of which the refund path skips — so its ticket needs the same
    ///      one-shot guarantee and the same regression test.
    function forceThenTransfer(address from, address to, uint256 forcedAmount, uint256 transferAmount) external {
        token.forcedTransfer(from, to, forcedAmount);
        token.transfer(to, transferAmount);
    }

    /// @notice Two enforcement transfers in one transaction. Both are separately
    ///         authorised, so both must succeed.
    function forceTwice(address from, address to, uint256 first, uint256 second) external {
        token.forcedTransfer(from, to, first);
        token.forcedTransfer(from, to, second);
    }
}
