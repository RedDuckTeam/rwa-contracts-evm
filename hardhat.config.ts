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
      // Pinned, and checked against the RPC before any transaction is signed: an RPC URL
      // pasted from the wrong project is otherwise indistinguishable from the right one until
      // the deployment is already on some other chain.
      chainId: 11155111,
      url: configVariable("SEPOLIA_RPC_URL"),
      // TWO keys, in this order, and they must be different accounts:
      //   [0] deployer — pays for the deployment, ends up holding NO privileges at all.
      //   [1] admin    — DEFAULT_ADMIN, timelock proposer, treasury. `deploy.ts` refuses to
      //                  run if this is the same account as the deployer, because that would
      //                  collapse the operational and critical tiers onto one key and no
      //                  downstream check could detect it.
      //
      // The admin's key is here only because `scripts/handover.ts` signs as it. A production
      // deployment has a multisig admin, no admin key on this machine, and one entry.
      accounts: [
        configVariable("SEPOLIA_PRIVATE_KEY"),
        configVariable("SEPOLIA_ADMIN_PRIVATE_KEY"),
      ],
    },
  },
  // Etherscan's v2 API is multichain: one key covers Sepolia and mainnet alike. Blockscout and
  // Sourcify default to enabled; they are off here so a `verify` run has exactly one way to
  // fail. Flip either to `true` to publish there as well — neither needs a key.
  verify: {
    etherscan: {
      apiKey: configVariable("ETHERSCAN_API_KEY"),
    },
    blockscout: { enabled: false },
    sourcify: { enabled: false },
  },
});
