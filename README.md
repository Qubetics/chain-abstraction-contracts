## Chain Abstraction Contracts

This repository contains the core smart contracts for a chain abstraction system, including solver management, intent handling, and vault logic. The contracts are written in Solidity and use the upgradeable OpenZeppelin stack with Hardhat as the development environment.

---

## Contracts

- **`contracts/solver_manager.sol`**  
  - Manages solver onboarding, activation, and liquidity accounting across chains.  
  - Enforces:
    - One-time onboarding per EVM address (each address can only call `onboardSolver` once).
    - Minimum liquidity thresholds for required chains (BTC and TICS) before a solver can be activated.
  - Tracks:
    - Solver metadata (`solverId`, name, chain IDs, solver addresses).
    - Per-chain liquidity and deposits/withdrawals.
    - Rewards per chain and total rewards.

- **`contracts/intent_manager.sol`**  
  - Handles user intents for cross-chain operations.  
  - Stores and tracks intent lifecycle and associated transaction status.  
  - Uses role-based access control for MPC and admin operations.

- **`contracts/vault.sol`**  
  - Vault logic for holding and moving funds that back intents/solvers.  
  - Integrated with the intent and solver flows (see contract for details).

---

## Roles and Upgradeability

The contracts use `AccessControlUpgradeable` and `UUPSUpgradeable` from OpenZeppelin.

- **Roles**
  - `DEFAULT_ADMIN_ROLE`: Full administrative permissions.
  - `ADMIN_ROLE`: Operational admin actions (e.g., configuration).
  - `MPC_ROLE`: Off‑chain MPC components that are allowed to update liquidity, rewards, etc.
  - `UPGRADER_ROLE`: Authorized to perform contract upgrades.

- **Upgrade Authorization**
  - Upgrades are authorized via the internal `_authorizeUpgrade` function in each UUPS contract.
  - In `solver_manager.sol`, upgrades are **disabled permanently** once privileged roles are renounced (see below).

---


## Development Setup

### Prerequisites

- Node.js (LTS, v18+; Hardhat recommends v20+)
- npm

### Install Dependencies

From the project root:

```bash
npm install
```

### Compile Contracts

```bash
npx hardhat compile
```

### Run Tests

```bash
npx hardhat test
```

### Run Local Node

```bash
npx hardhat node
```

You can then deploy contracts from your scripts (e.g. in `scripts/`) against the local node.

---

## Deployment & Configuration Notes

- **Roles**
  - On deployment, `initialize` grants `DEFAULT_ADMIN_ROLE`, `ADMIN_ROLE`, `MPC_ROLE`, and `UPGRADER_ROLE` to the provided admin address.
  - Before going permissionless, call `renouncePrivilegedRoles()` from a privileged admin to permanently drop upgrade and admin powers.

- **Liquidity Thresholds**
  - `minLiquidityBTC` and `minLiquidityTICS` can be updated via:
    - `setMinimumLiquidityBTC(uint256 newMinimum)`
    - `setMinimumLiquidityTICS(uint256 newMinimum)`
  - Changes emit `MinimumLiquidityUpdated(chainId, oldMinimum, newMinimum, timestamp)` and are enforced in solver activation checks.

---

## License

This project is licensed under the MIT License. See the SPDX identifier in each contract file.


