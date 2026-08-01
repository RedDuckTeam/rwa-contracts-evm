// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {DecimalsConverter} from "../../contracts/libraries/DecimalsConverter.sol";
import {DecimalsConverterTester} from "../../contracts/testers/DecimalsConverterTester.sol";

contract DecimalsConverterTest is Test {
    DecimalsConverterTester internal conv;

    function setUp() public {
        conv = new DecimalsConverterTester();
    }

    function test_WadDecimalsIs18() public view {
        assertEq(conv.wadDecimals(), 18);
    }

    function test_ToWadScalesUp() public view {
        assertEq(conv.toWad(1_000_000, 6), 1e18);
        assertEq(conv.toWad(1e8, 8), 1e18);
        assertEq(conv.toWad(1e18, 18), 1e18);
        assertEq(conv.toWad(0, 6), 0);
    }

    function test_FromWadDownTruncates() public view {
        // 1.0000005 in WAD has more precision than 6 decimals can hold; the remainder is
        // dropped rather than paid out.
        assertEq(conv.fromWadDown(1_000_000_500_000_000_000, 6), 1_000_000);
        assertEq(conv.fromWadDown(999_999_999_999, 6), 0);
        assertEq(conv.fromWadDown(1e18, 18), 1e18);
    }

    function test_RevertWhen_DecimalsAbove18() public {
        vm.expectRevert(abi.encodeWithSelector(DecimalsConverter.DecimalsTooHigh.selector, uint8(19)));
        conv.toWad(1, 19);

        vm.expectRevert(abi.encodeWithSelector(DecimalsConverter.DecimalsTooHigh.selector, uint8(255)));
        conv.fromWadDown(1, 255);
    }

    /// @dev Up-scaling then down-scaling must be the identity: a token amount can always be
    ///      represented exactly in WAD. This is what lets the vaults hold escrow in WAD.
    function testFuzz_RoundTripIsLossless(uint128 amount, uint8 tokenDecimals) public view {
        tokenDecimals = uint8(bound(tokenDecimals, 0, 18));
        uint256 wad = conv.toWad(amount, tokenDecimals);
        assertEq(conv.fromWadDown(wad, tokenDecimals), amount);
    }

}
