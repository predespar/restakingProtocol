// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───────────────────────── OpenZeppelin upgradeable ───────────────────────── */
import "@openzeppelin/contracts-upgradeable/token/ERC4626/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

/* ──────────────────────────── External interfaces ─────────────────────────── */
interface IEthVault {
	function reserveForClaims(uint256 ethAmt) external;
	function depositFromWrstETH(uint256 wethAmt) external;
	function claimReserveEthAmt() external view returns (uint256);
}

/* ──────────────── Uniswap Permit2 minimal interface ───────────────── */
interface IWETH9 is IERC20Upgradeable {
	function deposit() external payable;
	function withdraw(uint256) external;
}

/* ──────────────── Uniswap Permit2 minimal interface ───────────────── */
interface IPermit2 {
	struct TokenPermissions { address token; uint256 amount; }
	struct PermitTransferFrom {
		TokenPermissions permitted;
		uint256 nonce;
		uint256 deadline;
	}
	struct SignatureTransferDetails { address to; uint256 requestedAmount; }

	function permitTransferFrom(
		PermitTransferFrom calldata permit,
		SignatureTransferDetails calldata transferDetails,
		address owner,
		bytes calldata signature
	) external;
}

/// @notice Interface to WithdrawalEthQueue for orderly ETH withdrawals
interface IEthQueue {
	function tryWithdraw(
		uint256 ethShares,
		address receiver,
		address owner,
		uint256 wETHamt
	) external returns (uint256[4] memory result);
	function ethQueueUpdate() external;
}

/**
 * @title Wrapped Restaked ETH (wrstETH)
 * @notice ERC-4626 compliant vault wrapper over a restaked ETH position.
 *         All calculations and values in this contract are expressed in Wei (10^-18 ETH).
 *         Users deposit ETH and/or wETH, receive wrstETH shares, and can
 *         burn shares to queue withdrawals.
 */
contract WrstETH is
	ERC4626Upgradeable,
	ERC20CappedUpgradeable,
	ERC20BurnableUpgradeable,
	ERC20PermitUpgradeable,
	Ownable2StepUpgradeable,
	AccessControlEnumerableUpgradeable,
	PausableUpgradeable,
	ReentrancyGuardUpgradeable
{
	using AddressUpgradeable for address payable;
	using SafeERC20Upgradeable for IERC20Upgradeable;

	/* ------------------------------ Roles ------------------------------ */
	bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
	bytes32 public constant QUEUE_ROLE  = keccak256("QUEUE_ROLE");

	/* ------------------------------ Storage ---------------------------- */
	IEthVault         public ethVault;      ///< ETH vault that manages restaking/unrestaking
	IWETH9            public wETH;          ///< WETH9 token address
	IEthQueue  public ethQueue;  ///< WithdrawalEthQueue contract

	/// @notice ETH-per-share conversion rate (wei)
	uint256 public ethRate;       ///< How many wei of ETH per 1 wrstETH (18 decimals)

	/// @notice Timestamp of the last rate update (for oracle rate protection)
	uint256 public lastRateUpdate;

	/// @notice Daily mint cap (in wrstETH shares)
	uint256 public dailyDepositCapAmt;      ///< 24-hour deposit ceiling (in wrstETH)
	int256  public todayDepositedShares;    ///< Net wrstETH shares deposited today (mint - burn)
	uint64  public currentDay;              ///< Floor(block.timestamp / 1 day)
	uint8   public dailyPercent;            ///< Percent of cap allowed per UTC day

	mapping(address => bool) private _frozen;   ///< Sanctions / fraud freeze list

	/* --------------------------- Rate update protection ---------------- */
	// Use 2 decimals precision for annual rate (e.g. 1000 = 10.00%)
	uint16 public MAX_ANNUAL_RATE; // in basis points, 2 decimals (e.g. 1000 = 10.00%)

	/* --------------------------- constants ---------------------------- */
	// Permit2 address is the same on Ethereum, Polygon, Arbitrum, Optimism, Gnosis, etc.
	address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

	/* ------------------------------ Events ----------------------------- */
	event Frozen(address account);
	event Unfrozen(address account);
	event Confiscated(address account, uint256 amount);

	event CapChanged(uint256 oldCapAmt, uint256 newCapAmt);
	event DailyCapChanged(uint256 newDailyCap);
	event RateChanged(uint256 oldRate, uint256 newRate);
	event MaxAnnualRateChanged(uint16 oldRate, uint16 newRate); // <--- добавлено

	event AdminProposed(address oldAdmin, address newAdmin);
	event AdminChanged(address oldAdmin, address newAdmin);
	
	event FreezerProposed(address oldFreezer, address newFreezer);
	event FreezerChanged(address oldFreezer, address newFreezer);
	
	event PauserProposed(address oldPauser, address newPauser);
	event PauserChanged(address oldPauser, address newPauser);
	
	event OracleChanged(address oldOracle, address newOracle);
	event QueueChanged(address oldQueue, address newQueue);
	
	event Deposit(
		address caller,
		address owner,
		address receiver,
		uint256 assets,
		uint256 shares
	);
	
	event Withdraw(
		address caller,
		address receiver,
		address owner,
		uint256 assets,
		uint256 shares
	);

	/* ------------------------------ Initializer ------------------------ */
	/**
	 * @param admin         DEFAULT_ADMIN_ROLE
	 * @param oracle        ORACLE_ROLE
	 * @param queue         QUEUE_ROLE & WithdrawalQueue address
	 * @param vaultAddr     RestakeVault address
	 * @param wETHAddr      WETH9 address (underlying ERC-20 asset)
	 * @param capAmt        Total supply cap in shares
	 * @param _dailyPercent Percent of cap allowed per UTC day (1–100)
	 */
	function initialize(
		address admin,
		address oracle,
		address queue,
		address vaultAddr,
		address wETHAddr, 
		uint256 capAmt,
		uint8   _dailyPercent              // must be 1-100
	) external initializer {
		require(_dailyPercent >= 1 && _dailyPercent <= 100, "wrstETH: bad %");

		__ERC4626_init(IERC20Upgradeable(wETHAddr), "Wrapped Restaked ETH", "wrstETH");
		__ERC20Capped_init(capAmt);
		__ERC20Permit_init("Wrapped Restaked ETH");
		__Ownable2Step_init();
		__AccessControlEnumerable_init();
		__Pausable_init();
		__ReentrancyGuard_init();

		_transferOwnership(admin);
		_grantRole(ORACLE_ROLE, oracle);
		_grantRole(QUEUE_ROLE, queue);

		ethVault        = IEthVault(vaultAddr);
		ethQueue        = IEthQueue(queue);
		wETH            = IWETH9(wETHAddr); 
		
		ethRate         = 1e18;                                     // 1:1 initial rate
		dailyPercent    = _dailyPercent;
		dailyDepositCapAmt = capAmt * dailyPercent / 100;
		currentDay      = uint64(block.timestamp / 1 days);
		MAX_ANNUAL_RATE = 1000; // default: 10.00%
	}

	/* ───────────────────────── Modifiers ───────────────────────────── */
	modifier notFrozen(address acct) {
		require(!_frozen[acct], "wrstETH: frozen");
		_;
	}

	/* ------------------------------ Pause / Freeze --------------------- */
	function pause()   external onlyOwner { _pause(); }
	function unpause() external onlyOwner { _unpause(); }

	function freeze(address account)   external onlyOwner {
		_frozen[account] = true;
		emit Frozen(account);
	}
	function unfreeze(address account) external onlyOwner {
		_frozen[account] = false; emit Unfrozen(account);
	}
	function confiscate(address account) external onlyOwner {
		require(_frozen[account], "wrstETH: not frozen");
		uint256 bal = balanceOf(account);
		_burn(account, bal);
		emit Confiscated(account, bal);
	}
	function isFrozen(address a) external view returns (bool) { return _frozen[a]; }

	/* ------------------------- Cap & daily limit ----------------------- */
	/**
	 * @dev Lowers or raises the absolute supply cap.
	 *      The cap may be set *below* current totalSupply in order to block new
	 *      deposits while allowing withdrawals.
	 * @param newCapAmt New total supply cap (in Wei).
	 */
	function setCap(uint256 newCapAmt) external onlyOwner {
		require(newCapAmt > 0, "wrstETH: cap 0");
		emit CapChanged(cap(), newCapAmt);
		_updateCap(newCapAmt);

		// Re-compute daily limit proportionally to the new cap
		dailyDepositCapAmt = newCapAmt * dailyPercent / 100;
		emit DailyCapChanged(dailyDepositCapAmt);
	}

	function setDailyPercent(uint8 percent) external onlyOwner {
		require(percent >= 1 && percent <= 100, "wrstETH: bad %");
		dailyPercent    = percent;
		dailyDepositCapAmt = cap() * percent / 100;
		emit DailyCapChanged(dailyDepositCapAmt);
	}

	/* ------------------------ Role rotation (admin) -------------------- */
	/* ---------------- One-step rotation: ORACLE & QUEUE ---------------- */
	function setOracle(address newOracle)
		external onlyOwner
	{
		require(newOracle != address(0), "wrstETH: zero oracle");
		address old = getRoleMember(ORACLE_ROLE, 0);
		_grantRole(ORACLE_ROLE, newOracle);
		_revokeRole(ORACLE_ROLE, old);
		emit OracleChanged(old, newOracle);
	}

	function setQueue(address newQueue)
		external onlyOwner
	{
		require(newQueue != address(0), "wrstETH: zero queue");
		address old = getRoleMember(QUEUE_ROLE, 0);
		_grantRole(QUEUE_ROLE, newQueue);
		_revokeRole(QUEUE_ROLE, old);
		emit QueueChanged(old, newQueue);
	}

	/* --------------------------- Math helpers -------------------------- */
	function getWrstETHByETH(uint256 ethAmt) public view returns (uint256) {
		return ethAmt * 1e18 / ethRate;
	}
	function getETHByWrstETH(uint256 wrstEthAmt) public view returns (uint256) {
		return wrstEthAmt * ethRate / 1e18;
	}

	/**
	 * @notice Returns the amount of assets that would be received for redeeming the given number of shares,
	 *         taking into account the withdrawal discount.
	 * @param shares Amount of shares to redeem.
	 * @return Amount of assets receivable after discount.
	 */
	function previewRedeem(uint256 shares) public view override returns (uint256) {
		return previewWithdraw(shares);
	}

	/**
	 * @notice Returns the amount of assets that would be withdrawn for burning the given number of shares,
	 *         taking into account the withdrawal discount.
	 * @param shares Amount of shares to withdraw.
	 * @return Amount of assets receivable after discount.
	 */
	function previewWithdraw(uint256 shares) public view override returns (uint256) {
		// MAX_ANNUAL_RATE is now uint16, with 2 decimals (e.g. 1000 = 10.00%)
		// Daily rate = MAX_ANNUAL_RATE / 10000 / 365
		uint256 discount = ethRate * uint256(MAX_ANNUAL_RATE) / 10000 / 365;
		return shares * (ethRate - discount) / 1e18;
	}

	/* --------------------- Transfer guard overrides -------------------- */
	function _beforeTokenTransfer(address from, address to, uint256 amount)
		internal override
	{
		require(!paused(), "wrstETH: paused");
		require(!_frozen[from], "wrstETH: from is frozen");
		require(!_frozen[to], "wrstETH: to is frozen");
		super._beforeTokenTransfer(from, to, amount);
	}

	/* --------------------- Core deposit routine ------------------------ */
	/**
	 * @dev Internal function to handle deposits of ETH and/or wETH.
	 *      Calculates the total deposit, checks caps and limits, mints shares, and handles refunds.
	 *      Refunds are prioritized in ETH; if not enough ETH was sent, the remainder is refunded in wETH.
	 * @param owner Address of the owner of the assets being deposited.
	 * @param receiver Address that will receive the minted shares and refund.
	 * @param wethAmt Amount of wETH provided by the user (in Wei).
	 * @param ethAmt Amount of ETH provided by the user (in Wei).
	 * @return mintedShares Number of wrstETH shares minted for the deposit (in Wei).
	 * @return refundEthAmt Amount of ETH or wETH refunded to the user (in Wei).
	 */
	function _coreDeposit(
		address owner,
		address receiver,
		uint256 wethAmt,
		uint256 ethAmt
	)
		private
		returns (uint256 mintedShares, uint256 refundEthAmt)
	{
		// Reset daily counters if a new UTC day has started
		uint64 today = uint64(block.timestamp / 1 days);
		if (today > currentDay) {
			currentDay           = today;
			todayDepositedShares = 0;
		}

		// Calculate the total deposit amount (ETH + wETH)
		uint256 totalAssetAmt = wethAmt + ethAmt;
		require(totalAssetAmt > 0, "wrstETH: zero input");

		// Calculate the number of shares to mint based on the total deposit
		uint256 shares = getWrstETHByETH(totalAssetAmt);

		// Cap and daily limit logic
		if (totalSupply() >= cap()) revert("wrstETH: cap reached");
		uint256 capRemain = cap() - totalSupply();

		uint256 usedToday = todayDepositedShares > 0 ? uint256(todayDepositedShares) : 0;
		uint256 dayRemain = dailyDepositCapAmt + (todayDepositedShares < 0 ? uint256(-todayDepositedShares) : 0) - usedToday;
		uint256 maxShares = capRemain < dayRemain ? capRemain : dayRemain;
		if (shares > maxShares) shares = maxShares;
		require(shares > 0, "wrstETH: daily cap");

		// Calculate the amount of wETH required for restaking
		uint256 assetsToRestake = getETHByWrstETH(shares);

		// Calculate the refund amount (if any)
		refundEthAmt = totalAssetAmt - assetsToRestake;

		// 1. State changes first: mint shares and update counters
		todayDepositedShares += int256(shares);
		_mint(receiver, shares);

		// 2. Refund logic: prioritize refund in ETH, remainder in wETH
		if (refundEthAmt > 0) {
			if (ethAmt >= refundEthAmt) {
				// Refund as much as possible in ETH
				payable(receiver).sendValue(refundEthAmt);
				// Wrap the remaining ETH (if any) into wETH for vault
				if (ethAmt > refundEthAmt) {
					wETH.deposit{value: ethAmt - refundEthAmt}();
				}
			} else {
				// Refund all ETH sent
				if (ethAmt > 0) {
					payable(receiver).sendValue(ethAmt);
				}
				// Refund the rest in wETH
				uint256 wethRefund = refundEthAmt - ethAmt;
				wETH.safeTransfer(receiver, wethRefund);
			}
		} else if (ethAmt > 0) {
			// No refund, wrap all ETH for vault
			wETH.deposit{value: ethAmt}();
		}

		// 3. Transfer wETH to the vault for restaking
		wETH.safeTransfer(address(ethVault), assetsToRestake);
		// Eth vault will unwrap wETH into ETH upon receiving it. (external)
		ethVault.depositFromWrstETH(assetsToRestake);

		// try to advance withdrawal queue if there is free liquidity ---
		uint256 free = address(ethVault).balance - ethVault.claimReserveEthAmt();
		if (free > 0) {
			ethQueue.ethQueueUpdate();
		}

		emit Deposit(msg.sender, owner, receiver, totalAssetAmt - refundEthAmt, shares);
		return (shares, refundEthAmt);
	}

	/**
	 * @notice Standard ERC-4626 deposit: deposit wETH and receive shares.
	 *         According to the ERC-4626 standard, this function must only accept wETH (ERC20), not ETH.
	 *         If the user mistakenly sends ETH, the transaction will revert.
	 * @param assets Amount of wETH to deposit (in Wei).
	 * @param receiver Address to receive the minted wrstETH shares.
	 * @return shares Amount of wrstETH shares minted.
	 */
	function deposit(uint256 assets, address receiver)
		public
		override
		whenNotPaused
		nonReentrant
		notFrozen(msg.sender)
		notFrozen(receiver)
		returns (uint256 shares)
	{
		require(msg.value == 0, "wrstETH: do not send ETH, use wETH transfer");
		if (assets > 0) {
			wETH.safeTransferFrom(msg.sender, address(this), assets);
		}
		(uint256 mintedShares, ) = _coreDeposit(msg.sender, receiver, assets, 0);
		return mintedShares;
	}

	/**
	 * @notice Deposit a mix of ETH (`msg.value`) and/or pre-wrapped wETH into the protocol.
	 *         Mints wrstETH shares for the user and handles refunds if the cap is reached.
	 *         Refunds are prioritized in ETH; if not enough ETH was sent, the remainder is refunded in wETH.
	 * @param wethAmt Amount of wETH provided by the user (in Wei).
	 * @param receiver Address that will receive the minted shares and refund.
	 * @param owner Address of the owner of the tokens being deposited.
	 * @return mintedShares Number of wrstETH shares minted for the deposit (in Wei).
	 * @return refundEthAmt Amount of ETH or wETH refunded to the receiver (in Wei).
	 */
	function depositAssets(uint256 wethAmt, address receiver, address owner)
		external
		payable
		whenNotPaused
		nonReentrant
		notFrozen(msg.sender)
		notFrozen(owner)
		notFrozen(receiver)
		returns (uint256 mintedShares, uint256 refundEthAmt)
	{
		// Check allowance if wETH is provided
		if (wethAmt > 0) {
			wETH.safeTransferFrom(owner, address(this), wethAmt);
		}

		(mintedShares, refundEthAmt) = _coreDeposit(
			owner,
			receiver,
			wethAmt,
			msg.value
		);
		return (mintedShares, refundEthAmt);
	}

	/**
	 * @notice Deposit wETH via Uniswap Permit2 and optionally ETH in a single transaction.
	 *         Mints wrstETH shares for the user and handles refunds if the cap is reached.
	 *         Refunds are prioritized in ETH; if not enough ETH was sent, the remainder is refunded in wETH.
	 * @param wethAmt Amount of wETH to pull from the user's wallet (in Wei).
	 * @param receiver Address that will receive the minted shares and refund.
	 * @param owner Address of the owner of the tokens being deposited.
	 * @param nonce Permit2 nonce for the user's approval.
	 * @param deadline Permit2 deadline for the approval.
	 * @param signature Permit2 signature for the approval.
	 * @return mintedShares Number of wrstETH shares minted for the deposit (in Wei).
	 * @return refundEthAmt Amount of ETH or wETH refunded to the receiver (in Wei).
	 */
	function depositWithPermit(
		uint256 wethAmt,
		address receiver,
		address owner,
		uint256 nonce,
		uint256 deadline,
		bytes calldata signature
	)
		external
		payable
		whenNotPaused
		nonReentrant
		notFrozen(msg.sender)
		notFrozen(owner)
		notFrozen(receiver)
		returns (uint256 mintedShares, uint256 refundEthAmt)
	{
		if (wethAmt > 0) {
			IPermit2.PermitTransferFrom memory permit =
				IPermit2.PermitTransferFrom({
					permitted: IPermit2.TokenPermissions({
						token: address(wETH),
						amount: wethAmt
					}),
					nonce: nonce,
					deadline: deadline
				});
			IPermit2.SignatureTransferDetails memory details =
				IPermit2.SignatureTransferDetails({
					to: address(this),
					requestedAmount: wethAmt
				});
			IPermit2(PERMIT2).permitTransferFrom(
				permit,
				details,
				owner,
				signature
			);
		}

		(mintedShares, refundEthAmt) = _coreDeposit(
			owner,
			receiver,
			wethAmt,
			msg.value
		);
		return (mintedShares, refundEthAmt);
	}

	/**
	 * @notice Standard ERC-4626 mint: mint shares by depositing the required amount of wETH from msg.sender.
	 * @param shares Amount of shares to mint (in Wei).
	 * @param receiver Address to receive the minted wrstETH shares.
	 * @return assets Amount of wETH deposited to mint the shares (in Wei).
	 */
	function mint(uint256 shares, address receiver)
		public
		override
		whenNotPaused
		nonReentrant
		notFrozen(msg.sender)
		notFrozen(receiver)
		returns (uint256 assets)
	{
		assets = getETHByWrstETH(shares);
		if (assets > 0) {
			wETH.safeTransferFrom(msg.sender, address(this), assets);
		}
		(uint256 mintedShares, ) = _coreDeposit(msg.sender, receiver, assets, 0);
		require(mintedShares == shares, "ERC4626: insufficient cap for minting");
		return assets;
	}

	/**
	 * @notice Mints `shares` to `receiver` by depositing the required amount of assets from a specified owner.
	 *         This is the extended entry point for integrations and advanced use-cases.
	 *         For integrations only: mint shares from another owner's assets.
	 * @param shares Amount of shares to mint (in Wei).
	 * @param receiver Address that will receive the minted shares.
	 * @param owner Address of the owner of the assets being deposited.
	 * @return assets Amount of assets deposited to mint the shares (in Wei).
	 */
	function mintShares(uint256 shares, address receiver, address owner)
		external
		nonReentrant
		whenNotPaused
		notFrozen(msg.sender)
		notFrozen(owner)
		notFrozen(receiver)
		returns (uint256 assets)
	{
		assets = getETHByWrstETH(shares);
		if (assets > 0) {
			wETH.safeTransferFrom(owner, address(this), assets);
		}
		(uint256 mintedShares, ) = _coreDeposit(owner, receiver, assets, 0);
		require(mintedShares == shares, "ERC4626: insufficient cap for minting");
		return assets;
	}

	/**
	 * @notice Withdraws `assets` from the vault and burns the equivalent shares.
	 *         Assets will not be returned immediately but will be claimable later
	 *         via `claimEth` in the `WithdrawalEthQueue` contract.
	 * @param assets Amount of assets to withdraw (in Wei).
	 * @param receiver Address that will receive the withdrawn assets.
	 * @param owner Address of the owner of the shares being burned.
	 * @return shares Amount of shares burned to withdraw the assets (in Wei).
	 */
	function withdraw(
		uint256 assets,
		address receiver,
		address owner
	)
		override
		nonReentrant
		whenNotPaused
		notFrozen(msg.sender)
		notFrozen(owner)
		notFrozen(receiver)
		returns (uint256 shares)
	{
		// Calculate the amount of shares corresponding to the assets
		shares = getWrstETHByETH(assets);

		// If owner is not msg.sender, check allowance
		if (owner != msg.sender) {
			uint256 allowed = allowance(owner, msg.sender);
			require(allowed >= shares, "ERC4626: insufficient allowance");
		}

		// Burn the shares and enqueue the withdrawal
		ethQueue.tryWithdraw(shares, receiver, owner, assets);

		// Return the amount of shares burned
		return shares;
	}

	/**
	 * @notice Redeems `shares` for the equivalent amount of assets.
	 *         Assets will not be returned immediately but will be claimable
     *         later via `claimEth` in the `WithdrawalEthQueue` contract.
	 * @param shares Amount of shares to redeem (in Wei).
	 * @param receiver Address that will receive the redeemed assets.
	 * @param owner Address of the owner of the shares being redeemed.
	 * @return assets Amount of assets redeemed (in Wei).
	 */
	function redeem(
		uint256 shares,
		address receiver,
		address owner
	)
		public
		override
		nonReentrant
		whenNotPaused
		notFrozen(msg.sender)
		notFrozen(owner)
		notFrozen(receiver)
		returns (uint256 assets)
	{
		// Calculate the amount of assets corresponding to the shares
		assets = getETHByWrstETH(shares);

		// If owner is not msg.sender, check allowance
		if (owner != msg.sender) {
			uint256 allowed = allowance(owner, msg.sender);
			require(allowed >= shares, "ERC4626: insufficient allowance");
		}

		// Burn the shares and enqueue the withdrawal
		ethQueue.tryWithdraw(shares, receiver, owner, assets);

		// Return the amount of assets that will be claimable later
		return assets;
	}

	/**
	 * @notice Returns the maximum amount of assets that can be deposited for the given address.
	 *         Takes into account the paused state, cap, and daily mint limit.
	 * @param receiver Address for which the deposit limit is calculated.
	 * @return maxAssets Maximum amount of ETH that can be deposited (in Wei).
	 */
	function maxDeposit(address receiver) public view override returns (uint256 maxAssets) {
		if (paused()) return 0;

		uint256 remainingCap = cap() - totalSupply();
		uint256 usedToday = todayDepositedShares > 0 ? uint256(todayDepositedShares) : 0;
		uint256 dayRemain = dailyDepositCapAmt + (todayDepositedShares < 0 ? uint256(-todayDepositedShares) : 0) - usedToday;

		uint256 remainingDaily = dailyDepositCapAmt > usedToday ? dayRemain : 0;
		uint256 minShares = remainingCap < remainingDaily ? remainingCap : remainingDaily;
		maxAssets = getETHByWrstETH(minShares);
		
		return maxAssets;
	}

	/* ------------------------------ Burn ------------------------------- */
	/**
	 * @dev Burns wrstETH shares and reserves ETH for withdrawal.
	 *      Applies a discount equal to the maximum possible daily rate increase to protect the protocol from instant withdrawal arbitrage.
	 *      The user receives ETH as if the rate were reduced by the maximum allowed daily increase.
	 *      Only callable by the withdrawal queue contract.
	 * @param wrstEthAmt Amount of wrstETH shares to burn.
	 * @param receiver Address to receive the withdrawal (for event/logging).
	 * @param owner Address of the owner of the shares being burned.
	 * @return ethAmt Amount of ETH reserved for withdrawal (discounted).
	 */
	function burnForWithdrawal(uint256 wrstEthAmt, address receiver, address owner)
		external onlyRole(QUEUE_ROLE)
		returns (uint256 ethAmt)
	{
		// Discount: user receives ETH as if the rate were reduced by the maximum allowed daily increase
		ethAmt = previewWithdraw(wrstEthAmt);
		_burn(owner, wrstEthAmt);

		uint64 today = uint64(block.timestamp / 1 days);
		if (today > currentDay) {
			currentDay           = today;
			todayDepositedShares = 0;
		}
		todayDepositedShares -= int256(wrstEthAmt);
		
		ethVault.reserveForClaims(ethAmt);
		emit Withdraw(msg.sender, receiver, owner, ethAmt, wrstEthAmt);
	}

	/* --------------------------- Oracle hooks -------------------------- */
	/**
	 * @notice Updates the ETH-to-wrstETH conversion rate.
	 * @param newRate The new ETH-to-wrstETH conversion rate.
	 */
	function setRate(uint256 newRate) external onlyRole(ORACLE_ROLE) {
		// Ensure at least 23 hours have passed since the last update
		require(block.timestamp >= lastRateUpdate + 23 hours, "wrstETH: update too soon");

		// Ensure the new rate is not less than the current rate
		require(newRate >= ethRate, "wrstETH: rate cannot decrease");

		// Calculate max allowed rate using 64.64 fixed-point math
		// maxAllowedRate = ethRate + ethRate * MAX_DAILY_RATE_INCREASE_64x64 >> 64
		uint256 maxAllowedRate = ethRate + ethRate * uint256(MAX_ANNUAL_RATE) / 10000 / 365;
		require(newRate <= maxAllowedRate, "wrstETH: rate increase too high");

		// Update the rate and timestamp
		emit RateChanged(ethRate, newRate);
		ethRate = newRate;
		lastRateUpdate = block.timestamp;
	}

	function resetDailyCounters() external onlyRole(ORACLE_ROLE) {
		uint64 today = uint64(block.timestamp / 1 days);
		if (today > currentDay) {
			currentDay           = today;
			todayDepositedShares = 0;
		}
	}
	
	/* ========== ERC-4626 OVERWRITES ========== */

	/**
	 * @notice Returns the total amount of underlying assets managed by the vault.
	 * @return Total assets in the vault (in Wei).
	 */
	function totalAssets() public view override returns (uint256) {
		// Calculate total assets based on totalSupply and the current ethRate
		return totalSupply() * ethRate / 1e18;
	}

	/**
	 * @notice Converts a given amount of assets to the equivalent amount of shares.
	 * @param assets Amount of assets to convert (in Wei).
	 * @return Equivalent amount of shares (in Wei).
	 */
	function convertToShares(uint256 assets) public view override returns (uint256) {
		return getWrstETHByETH(assets);
	}

	/**
	 * @notice Converts a given amount of shares to the equivalent amount of assets.
	 * @param shares Amount of shares to convert (in Wei).
	 * @return Equivalent amount of assets (in Wei).
	 */
	function convertToAssets(uint256 shares) public view override returns (uint256) {
		return getETHByWrstETH(shares);
	}

	/**
	 * @notice Sets the maximum allowed annual rate (basis points, 2 decimals).
	 *         Only callable by owner.
	 * @param newAnnualRate New max annual rate (e.g. 1000 = 10.00%).
	 */
	function setMaxAnnualRate(uint16 newAnnualRate) external onlyOwner {
		require(newAnnualRate >= 0 && newAnnualRate <= 2500, "wrstETH: invalid max rate"); // sanity check, max 25%
		uint16 oldRate = MAX_ANNUAL_RATE;
		MAX_ANNUAL_RATE = newAnnualRate;
		emit MaxAnnualRateChanged(oldRate, newAnnualRate);
	}

	/**
	 * @notice Allows the WithdrawalEthQueue contract to decrease the ERC20 allowance of a user (owner) to a spender after withdrawal.
	 *         Can only be called by the contract with QUEUE_ROLE.
	 * @param owner The address whose wrstETH tokens are being withdrawn and whose allowance is being decreased.
	 * @param spender The address that was approved by the owner to spend wrstETH (typically msg.sender in the queue).
	 * @param subtractedValue The amount to subtract from the current allowance (i.e., the amount withdrawn).
	 */
	function queueApprove(address owner, address spender, uint256 subtractedValue)
		external
		onlyRole(QUEUE_ROLE)
	{
		uint256 currentAllowance = allowance(owner, spender);
		require(currentAllowance >= subtractedValue, "wrstETH: decreased allowance below zero");
		_approve(owner, spender, currentAllowance - subtractedValue);
	}
}
