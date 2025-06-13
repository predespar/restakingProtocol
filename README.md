## Core Contracts

### 1. WrstETH (Wrapped Restaked ETH)
- **ERC-4626** compatible token representing a user's share in restaked ETH.
- Supports deposits in ETH and wETH, minting and burning of wrstETH.
- Limits: supply cap, daily mint cap, freeze/pausable mechanisms.
- wrstETH/ETH rate is updated via Oracle with fixed-point 64.64 protection against sharp changes.
- Two-step role rotation for admin/freezer/pauser, single-step for oracle/queue.
- Permit2 support for gasless deposits.
- All transfers and operations are blocked for frozen accounts.

### 2. RestakeVault
- Manages ETH reserves for the withdrawal queue and restaking operations.
- Accepts ETH/wETH, releases funds for restaking and withdrawal claims.
- Reentrancy protection (nonReentrant).
- Reserves claimReserveEthAmt for the withdrawal queue.
- Two-step role rotation for admin/restaker, single-step for oracle/queue.

### 3. WithdrawalQueue
- Withdrawal requests are represented as NFTs (ERC-721), each request is a separate NFT.
- FIFO logic via cumulative id, O(1) operations, no loops.
- Users can delegate withdrawal rights via approve/allowance (ERC-20 style).
- NFT metadata is implemented via on-chain tokenURI (base64 JSON).
- Overflow protection for counters.
- EIP-165 (supportsInterface) supported.

### 4. RestakingOracle
- Keeper contract that updates the wrstETH/ETH rate and releases liquidity for the queue.
- Two-step role rotation for admin/keeper.
- All calls are strictly role-restricted.

## Security & Optimization

- All critical external calls are protected by nonReentrant and checks-effects-interactions.
- All variables and events are gas-optimized (indexed only where needed).
- DoS protection by gas (no loops in main functions).
- Overflow checks for cumulative counters.
- Frozen flags stored as mapping(address => bool) — standard and safe.
- Permit2 address stored as immutable (set via assembly in initialize).

## Features

- All roles and access rights implemented via OpenZeppelin AccessControlEnumerableUpgradeable.
- All contracts are upgradeable (Initializable).
- Support for both off-chain and on-chain NFT metadata.
- Integration with external services (e.g., Uniswap Permit2, OpenSea) is possible.
