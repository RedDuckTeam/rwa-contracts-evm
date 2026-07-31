import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import hardhatUpgradesPlugin from "@openzeppelin/hardhat-upgrades";
import contractSizerPlugin from "@solidstate/hardhat-contract-sizer";
import { configVariable, defineConfig } from "hardhat/config";

// Every profile pins `evmVersion: "cancun"`: the token's privileged refund path
// relies on EIP-1153 transient storage, as does `ReentrancyGuardTransient` in
// the vaults.
const EVM_VERSION = "cancun";

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin, hardhatUpgradesPlugin, contractSizerPlugin],
  solidity: {
    profiles: {
      default: {
        version: "0.8.36",
        settings: {
          evmVersion: EVM_VERSION,
        },
      },
      production: {
        version: "0.8.36",
        settings: {
          evmVersion: EVM_VERSION,
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    },
  },
  test: {
    solidity: {
      fuzz: {
        runs: 256,
      },
      invariant: {
        runs: 64,
        depth: 32,
        failOnRevert: false,
      },
    },
  },
  // The EIP-170 gate is measured on the `production` profile only: the default
  // profile compiles without the optimizer and would report a false failure.
  contractSizer: {
    alphaSort: true,
    runOnCompile: false,
    unit: "B",
  },
  networks: {
    // `allowUnlimitedContractSize` on the in-memory dev networks ONLY.
    //
    // Tests and coverage run on the `default` profile, which has no optimizer — the vaults
    // exceed EIP-170 there while the deployable `production` artifacts sit comfortably
    // under it. Enforcing the limit here would mean either running the whole suite
    // optimized (which distorts coverage line attribution) or being unable to test the
    // vaults at all.
    //
    // The real gate is `pnpm size`, measured on the production profile in CI, backed up by
    // `pnpm deploy:local`, which also runs production and would fail on an oversized
    // contract.
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1",
      allowUnlimitedContractSize: true,
    },
    hardhatOp: {
      type: "edr-simulated",
      chainType: "op",
      allowUnlimitedContractSize: true,
    },
    sepolia: {
      type: "http",
      chainType: "l1",
      url: configVariable("SEPOLIA_RPC_URL"),
      accounts: [configVariable("SEPOLIA_PRIVATE_KEY")],
    },
  },
});
