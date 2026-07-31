// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

/// @dev The two failure modes matter as much as the happy path: a reverting oracle and a
///      gas-burning one are the DoS vectors the compliance layer must survive.
contract MockSanctionsList {
    error OracleDown();

    enum Mode {
        Normal,
        Revert,
        GasBomb
    }

    Mode public mode;
    mapping(address account => bool sanctioned) private _sanctioned;

    function setMode(Mode newMode) external {
        mode = newMode;
    }

    function setSanctioned(address account, bool sanctioned) external {
        _sanctioned[account] = sanctioned;
    }

    function isSanctioned(address addr) external view returns (bool) {
        if (mode == Mode.Revert) revert OracleDown();
        if (mode == Mode.GasBomb) {
            // Burn everything the caller forwarded. A caller that does not cap gas dies here.
            uint256 acc;
            for (uint256 i; i < type(uint256).max; ++i) {
                acc = uint256(keccak256(abi.encode(acc, i)));
            }
            return acc != 0;
        }
        return _sanctioned[addr];
    }
}
