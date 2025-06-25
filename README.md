## Core Contracts

### 1. WrstETH (Wrapped Restaked ETH)
- **ERC-4626** compliant token representing a user's share in restaked ETH.
- Supports deposits in ETH and wETH, minting and burning of wrstETH.
- Supply cap, daily deposit cap (`dailyDepositCapAmt`), pausable and freeze mechanisms.
- Oracle-controlled rate with daily increase protection; maximum annual rate is owner-configurable.
- Withdrawal discount is calculated based on the current `MAX_ANNUAL_RATE` and reflected in `previewWithdraw`/`previewRedeem` (ERC-4626 preview functions).
- Two-step ownership transfer (`Ownable2StepUpgradeable`).
- Roles: `ORACLE_ROLE` (rate/oracle actions) and `QUEUE_ROLE` (withdrawal queue integration).
- Permit2 support for gasless deposits.
- All transfers and operations are blocked for frozen accounts.
- Emits events on all critical parameter changes.
- Daily deposit cap is enforced as a net of minted and burned shares per day (`todayDepositedShares`).
- **Integrated with PointsController:** On every token transfer, points are accrued and settled for both sender and receiver via `settleBefore` and `settleAfter` hooks.

### 2. EthVault
- Manages ETH reserves for the withdrawal queue and restaking operations.
- Accepts ETH/wETH, releases funds for restaking and withdrawal claims.
- Reentrancy protection (`nonReentrant`).
- Reserves `claimReserveEthAmt` for the withdrawal queue.
- Two-step ownership transfer (`Ownable2StepUpgradeable`).
- `RESTAKER_ROLE` rotation is two-step (propose/accept).
- Owner can set the fast withdrawal reserve (`withdrawReserve`, `uint16`), emits `EthWithdrawReserveChanged` on update.
- Surplus calculation and logic for restaking excess funds.
- Emits `EthVaultBalance` on every balance-affecting operation.

### 3. WithdrawalEthQueue
- Withdrawal requests are represented as ERC-721 NFTs (one per request).
- FIFO logic via cumulative id, O(1) operations, no loops.
- Users can delegate withdrawal rights via approve/allowance (ERC-20 style).
- NFT metadata is implemented via on-chain `tokenURI` (base64 JSON).
- Overflow protection for counters.
- EIP-165 (`supportsInterface`) supported.
- Users can attempt instant withdrawal with `tryWithdraw`; if not possible, an NFT is minted and the user waits in the queue.
- `isClaimReady(id)` returns both readiness and claim status for a withdrawal ticket.
- Emits `QueueAdvanced` after each queue processing, including queue top and pending amount.
- Provides average processing time, request size, and daily payout statistics.

### 4. RstEthOracle (RestakingOracle)
- Keeper contract that updates the wrstETH/ETH rate and resets daily counters.
- Two-step ownership transfer (`Ownable2StepUpgradeable`).
- `KEEPER_ROLE` rotation is two-step (propose/accept).
- All calls are strictly role-restricted.
- Emits `NewWrstEthRatePushed` on each report.
- **Feeds daily rates to PointsController and updates points accumulators using Chainlink price feeds.**

### 5. PointsController
- Tracks global `accPointsPerShare[token]` indices and manages user points for all wrstX tokens.
- Points are NOT ERC-20 and are non-transferable.
- Points are accrued daily by the Oracle and on every wrstX token transfer via `settleBefore` and `settleAfter`.
- In claim phase, users can claim or claimAndStake their points for WRST/sWRST.
- Only wrstX tokens and Oracle can interact with accrual/settlement functions.
- All roles and access rights implemented via OpenZeppelin `AccessControlUpgradeable`.
- Fully upgradeable and pausable.

## Security & Optimization

- All critical external calls are protected by `nonReentrant` and checks-effects-interactions.
- All variables and events are gas-optimized (indexed only where needed, minimal storage types like `uint16` for `withdrawReserve`).
- DoS protection by gas (no loops in main functions).
- Overflow checks for cumulative counters.
- Frozen flags stored as `mapping(address => bool)` — standard and safe.
- Permit2 address stored as immutable (set via assembly in initialize).

## Features

- All roles and access rights implemented via OpenZeppelin `AccessControlEnumerableUpgradeable`.
- All contracts are upgradeable (`Initializable`).
- Support for both off-chain and on-chain NFT metadata.
- Integration with external services (e.g., Uniswap Permit2, OpenSea) is possible.
- All key protocol state changes are reflected in events for off-chain monitoring and integrations.
- **On-chain points accrual and claim logic for airdrop and rewards.**
