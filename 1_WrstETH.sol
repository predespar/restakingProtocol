// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───────────────────────── OpenZeppelin upgradeable ───────────────────────── */
import "@openzeppelin/contracts-upgradeable/token/ERC4626/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

/* ──────────────────────────── External interfaces ─────────────────────────── */
interface IRestakeVault {
	function reserveForClaims(uint256 ethWei) external;
	function depositFromWrstETH(uint256 wethWei) external;
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

/// @notice Interface to WithdrawalQueue for orderly ETH withdrawals
interface IWithdrawalQueue {
	/// @notice Burn `wrstETHWei` shares and enqueue withdrawal for `receiver`.
	/// @return ticketId sequential ID of withdrawal request
	function requestWithdrawEth(uint256 wrstETHWei, address receiver, address owner)
		external returns (uint256 ticketId);
}

/**
 * @title Wrapped Restaked ETH (wrstETH)
 * @notice ERC-4626 compliant vault wrapper over a restaked ETH position.
 *         Users deposit ETH and/or wETH, receive wrstETH shares, and can
 *         burn shares to queue withdrawals. 
 */
contract WrstETH is
	ERC4626Upgradeable,
	ERC20CappedUpgradeable,
	ERC20BurnableUpgradeable,
	ERC20PermitUpgradeable,
	AccessControlEnumerableUpgradeable,
	PausableUpgradeable,
	ReentrancyGuardUpgradeable
{
	using AddressUpgradeable for address payable;
	using SafeERC20Upgradeable for IERC20Upgradeable;

	/* ------------------------------ Roles ------------------------------ */
	bytes32 public constant FREEZER_ROLE       = keccak256("FREEZER_ROLE");
	bytes32 public constant PAUSER_ROLE        = keccak256("PAUSER_ROLE");
	bytes32 public constant CAP_MANAGER_ROLE   = keccak256("CAP_MANAGER_ROLE");
	bytes32 public constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
	bytes32 public constant ORACLE_ROLE        = keccak256("ORACLE_ROLE");
	bytes32 public constant QUEUE_ROLE         = keccak256("QUEUE_ROLE");

	/* ------------------------------ Storage ---------------------------- */
	IRestakeVault 		public vault;         ///< Restake vault that manages restaking/unrestaking
	IWETH9        		public wETH;          // < WETH9 token address
	IWithdrawalQueue    public withdrawalQueue;  // queue contract
	
	/// @notice ETH-per-share conversion rate (wei)
	uint256 public rateWei;       ///< How many wei of ETH per 1 wrstETH (18 decimals)

	/// @notice Daily mint cap (in wrstETH shares)
	uint256 public dailyMintCapWei;     ///< 24-hour minting ceiling (in wrstETH wei)
	uint256 public mintedTodayWei;      ///< Amount minted since currentDay
	uint64  public currentDay;          ///< Floor(block.timestamp / 1 day)
	uint8   public dailyPercent;        ///< Percent of cap allowed per UTC day

	mapping(address => bool) private _frozen;   ///< Sanctions / fraud freeze list

	/* ---------- pending addresses for two-phase role rotation ---------- */
	address public pendingAdmin;
	address public pendingFreezer;
	address public pendingPauser;
	
	/* --------------------------- constants ---------------------------- */
	// Permit2 address is the same on Ethereum, Polygon, Arbitrum, Optimism, Gnosis, etc.
	address private constant PERMIT2 =
		0x000000000022D473030F116dDEE9F6B43aC78BA3;

	/* ------------------------------ Events ----------------------------- */
	event Frozen(address indexed account);
	event Unfrozen(address indexed account);
	event Confiscated(address indexed account, uint256 amount);

	event CapChanged(uint256 oldCapWei, uint256 newCapWei);
	event DailyCapChanged(uint256 newDailyCapWei);
	event RateChanged(uint256 oldRateWei, uint256 newRateWei);

	event AdminProposed(  address indexed oldAdmin,   address indexed newAdmin);
	event AdminChanged(   address indexed oldAdmin,   address indexed newAdmin);
	
	event FreezerProposed(address indexed oldFreezer, address indexed newFreezer);
	event FreezerChanged( address indexed oldFreezer, address indexed newFreezer);
	
	event PauserProposed( address indexed oldPauser,  address indexed newPauser);
	event PauserChanged(  address indexed oldPauser,  address indexed newPauser);
	
	event OracleChanged(  address indexed oldOracle,  address indexed newOracle);
	event QueueChanged(   address indexed oldQueue,   address indexed newQueue);
	
	event Deposit(
		address indexed caller,
		address indexed owner,
		uint256 assets,
		uint256 shares
	);
	
	event Withdraw(
		address indexed caller,
		address indexed receiver,
		address indexed owner,
		uint256 assets,
		uint256 shares
	);

	/* ------------------------------ Initializer ------------------------ */
	/**
	 * @param admin         DEFAULT_ADMIN_ROLE
	 * @param freezer       FREEZER_ROLE
	 * @param pauser        PAUSER_ROLE
	 * @param oracle        ORACLE_ROLE
	 * @param queue         QUEUE_ROLE & WithdrawalQueue address
	 * @param vaultAddr     RestakeVault address
	 * @param wETHAddr      WETH9 address (underlying ERC-20 asset)
	 * @param capWei        Total supply cap in shares
	 * @param _dailyPercent Percent of cap allowed per UTC day (1–100)
	 */
	function initialize(
		address admin,
		address freezer,
		address pauser,
		address oracle,
		address queue,
		address vaultAddr,
		address wETHAddr, 
		uint256 capWei,
		uint8   dailyPercent              // must be 1-100
	) external initializer {
		require(dailyPercent >= 1 && dailyPercent <= 100, "wrstETH: bad %");

		__ERC4626_init(IERC20Upgradeable(wETHAddr), "Wrapped Restaked ETH", "wrstETH");
		__ERC20Capped_init(capWei);
		__ERC20Permit_init("Wrapped Restaked ETH");
		__AccessControlEnumerable_init();
		__Pausable_init();
		__ReentrancyGuard_init();

		_grantRole(DEFAULT_ADMIN_ROLE, admin);
		_grantRole(FREEZER_ROLE,       freezer);
		_grantRole(PAUSER_ROLE,        pauser);
		_grantRole(CAP_MANAGER_ROLE,   admin);
		_grantRole(LIMIT_MANAGER_ROLE, admin);
		_grantRole(ORACLE_ROLE,        oracle);
		_grantRole(QUEUE_ROLE,         queue);

		vault           = IRestakeVault(vaultAddr);
		withdrawalQueue = IWithdrawalQueue(queue);
		wETH            = IWETH9(wETHAddr); 
		
		rateWei         = 1e18;                                     // 1:1 initial rate
		dailyPercent    = _dailyPercent;
		dailyMintCapWei = capWei * dailyPercent / 100;
		currentDay      = uint64(block.timestamp / 1 days);
	}
	
	/* ───────────────────────── Modifiers ───────────────────────────── */
	modifier notFrozen(address acct) {
		require(!_frozen[acct], "wrstETH: frozen");
		_;
	}

	/* ------------------------------ Pause / Freeze --------------------- */
	function pause()   external onlyRole(PAUSER_ROLE)  { _pause();  }
	function unpause() external onlyRole(PAUSER_ROLE)  { _unpause();}

	function freeze(address account)   external onlyRole(FREEZER_ROLE) {
		_frozen[account] = true;  emit Frozen(account);
	}
	function unfreeze(address account) external onlyRole(FREEZER_ROLE) {
		_frozen[account] = false; emit Unfrozen(account);
	}
	function confiscate(address account) external onlyRole(FREEZER_ROLE) {
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
	 */
	function setCap(uint256 newCapWei) external onlyRole(CAP_MANAGER_ROLE) {
		require(newCapWei > 0, "wrstETH: cap 0");
		emit CapChanged(cap(), newCapWei);
		_updateCap(newCapWei);

		// Re-compute daily limit proportionally to the new cap
		dailyMintCapWei = newCapWei * dailyMintCapWei / cap();
	}

	function setDailyPercent(uint8 percent) external onlyRole(LIMIT_MANAGER_ROLE) {
		require(percent >= 1 && percent <= 100, "wrstETH: bad %");
		dailyPercent    = percent;
		dailyMintCapWei = cap() * percent / 100;
		emit DailyCapChanged(dailyMintCapWei);
	}

	/* ------------------------ Role rotation (admin) -------------------- */
	/* ---------------- One-step rotation: ORACLE & QUEUE ---------------- */
	function setOracle(address newOracle)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(newOracle != address(0), "wrstETH: zero oracle");
		address old = getRoleMember(ORACLE_ROLE, 0);
		_grantRole(ORACLE_ROLE, newOracle);
		_revokeRole(ORACLE_ROLE, old);
		emit OracleChanged(old, newOracle);
	}

	function setQueue(address newQueue)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(newQueue != address(0), "wrstETH: zero queue");
		address old = getRoleMember(QUEUE_ROLE, 0);
		_grantRole(QUEUE_ROLE, newQueue);
		_revokeRole(QUEUE_ROLE, old);
		emit QueueChanged(old, newQueue);
	}
	/* ------------------------- Two-phase: ADMIN ------------------------ */
	function proposeAdmin(address newAdmin)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(newAdmin != address(0), "wrstETH: zero admin");
		pendingAdmin = newAdmin;
		emit AdminProposed(getRoleMember(DEFAULT_ADMIN_ROLE, 0), newAdmin);
	}
	
	function acceptAdmin() external {
		require(msg.sender == pendingAdmin, "wrstETH: not pending admin");
		address old = getRoleMember(DEFAULT_ADMIN_ROLE, 0);
	
		_grantRole(DEFAULT_ADMIN_ROLE, pendingAdmin);
		_revokeRole(DEFAULT_ADMIN_ROLE, old);
	
		emit AdminChanged(old, pendingAdmin);
		pendingAdmin = address(0);
	}
	
	/* ------------------------- Two-phase: FREEZER ---------------------- */
	function proposeFreezer(address newFreezer)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(newFreezer != address(0), "wrstETH: zero freezer");
		pendingFreezer = newFreezer;
		emit FreezerProposed(getRoleMember(FREEZER_ROLE, 0), newFreezer);
	}
	
	function acceptFreezer() external {
		require(msg.sender == pendingFreezer, "wrstETH: not pending freezer");
		address old = getRoleMember(FREEZER_ROLE, 0);
	
		_grantRole(FREEZER_ROLE, pendingFreezer);
		_revokeRole(FREEZER_ROLE, old);
	
		emit FreezerChanged(old, pendingFreezer);
		pendingFreezer = address(0);
	}
	
	/* ------------------------- Two-phase: PAUSER ----------------------- */
	function proposePauser(address newPauser)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(newPauser != address(0), "wrstETH: zero pauser");
		pendingPauser = newPauser;
		emit PauserProposed(getRoleMember(PAUSER_ROLE, 0), newPauser);
	}
	
	function acceptPauser() external {
		require(msg.sender == pendingPauser, "wrstETH: not pending pauser");
		address old = getRoleMember(PAUSER_ROLE, 0);
	
		_grantRole(PAUSER_ROLE, pendingPauser);
		_revokeRole(PAUSER_ROLE, old);
	
		emit PauserChanged(old, pendingPauser);
		pendingPauser = address(0);
	}

	/* --------------------------- Math helpers -------------------------- */
	function getWrstETHByETH(uint256 ethWei) public view returns (uint256) {
		return ethWei * 1e18 / rateWei;
	}
	function getETHByWrstETH(uint256 wrstWei) public view returns (uint256) {
		return wrstWei * rateWei / 1e18;
	}

	/* --------------------- Transfer guard overrides -------------------- */
	function _beforeTokenTransfer(address from, address to, uint256 amount)
		internal override
	{
		require(!paused(),               "wrstETH: paused");
		require(!_frozen[from] && !_frozen[to], "wrstETH: frozen");
		super._beforeTokenTransfer(from, to, amount);
	}
	
	/* ----------------- core deposit routine (shared) ------------------ */
	function _coreDeposit(
		uint256 wETHIn,
		uint256 ethIn,
		address receiver,
		bool    refundAsWETH   // true → refund in wETH, false → refund in ETH
	)
		private
		returns (uint256 mintedWei, uint256 refundWei)
	{
		uint256 totalIn = wETHIn + ethIn;
		require(totalIn > 0, "wrstETH: zero input");

		/* ---------- Cap & daily-limit checks ---------- */
		uint256 wrstWei = getWrstETHByETH(totalIn);
		uint256 remain  = cap() - totalSupply();
		if (wrstWei > remain) wrstWei = remain;

		// Reset counters at start of a new UTC day
		uint64 today = uint64(block.timestamp / 1 days);
		if (today > currentDay) { currentDay = today; mintedTodayWei = 0; }
		require(mintedTodayWei + wrstWei <= dailyMintCapWei,
				"wrstETH: daily cap");

		uint256 wethToRestake = getETHByWrstETH(wrstWei); // ETH == wETH 1:1
		refundWei = totalIn - wethToRestake;

		/* wrap ETH part */
		if (ethIn > 0) wETH.deposit{value: wethToRestake}();

		/* send to vault */
		wETH.safeTransfer(address(vault), wethToRestake);
		vault.depositFromWrstETH(wethToRestake);

		/* refund */
		if (refundWei > 0) {
			if (refundAsWETH) {
				wETH.safeTransfer(receiver, refundWei);
			} else {
				payable(receiver).sendValue(refundWei);
			}
		}

		/* mint */
		mintedTodayWei += wrstWei;
		_mint(receiver, wrstWei);
		
		emit Deposit(msg.sender, receiver, wETHIn + ethIn, wrstWei);
		
		return (wrstWei, refundWei);
	}

	/* ------------------------------ Deposit ---------------------------- */
	/**
	* @notice Deposit any mix of ETH (`msg.value`) and/or pre-wrapped wETH
	* 		       and wrap them into wrstETH. Follows the checks-effects-
	*              interactions pattern and is protected by `nonReentrant`.
	* @param  wETHIn    Amount of wETH the user wants to supply from their wallet.
	*                       Must be approved to this contract *before* calling.
	* @param receiver   who will receive minted shares
	*
	* @return mintedWei  Amount of wrstETH minted to the sender
	* @return refundWei  Excess ETH returned to the sender (if cap reached)
	*/
	function deposit(uint256 wETHIn, address receiver)
		external payable whenNotPaused nonReentrant notFrozen(msg.sender) notFrozen(receiver)
		returns (uint256 mintedWei, uint256 refundWei)
	{
		if (wETHIn > 0) wETH.safeTransferFrom(msg.sender, address(this), wETHIn);
		(mintedWei, refundWei) = _coreDeposit(
			wETHIn,
			msg.value,
			receiver,
			wETHIn > 0  /*refundAsWETH*/       // mixed deposit → refund wETH
		);
	}
	
	/**
	 * @notice Single-tx deposit via Uniswap Permit2 + optional ETH, mint shares.
	 * @param assets     how much wETH to pull
	 * @param receiver   who will receive minted shares
	 * @param nonce      Permit2 nonce
	 * @param deadline   Permit2 deadline
	 * @param signature  Permit2 signature
	 */
	function depositWithPermit(
		uint256 amount,
		address receiver,
		uint256 nonce,
		uint256 deadline,
		bytes calldata signature
	)
		external payable whenNotPaused nonReentrant notFrozen(msg.sender) notFrozen(receiver)
		returns (uint256 mintedWei, uint256 refundWei)
	{
		if (amount > 0) {
			IPermit2.PermitTransferFrom memory permit =
				IPermit2.PermitTransferFrom({
					permitted: IPermit2.TokenPermissions({
						token: address(wETH),
						amount: amount
					}),
					nonce: nonce,
					// user-controlled deadline
					deadline: deadline
				});
			IPermit2.SignatureTransferDetails memory details =
				IPermit2.SignatureTransferDetails({
					to: address(this),
					requestedAmount: amount
				});
			IPermit2(PERMIT2).permitTransferFrom(
				permit,
				details,
				msg.sender,
				signature
			);
		}
		(mintedWei, refundWei) = _coreDeposit(
			amount,
			receiver,
			msg.value,
			amount > 0  /*refundAsWETH*/       // mixed deposit → refund wETH
		);
	}

	/* ------------------------------ Burn ------------------------------- */
	/**
	 * @dev Burn tokens when `WithdrawalQueue` prepares a withdrawal.
	 *      Only callable by the queue contract.
	 */
	function burnForWithdrawal(uint256 wrstWei, address receiver, address owner)
		external onlyRole(QUEUE_ROLE)
		returns (uint256 ethWei)
	{
		ethWei = getETHByWrstETH(wrstWei);
		_burn(from, wrstWei);
		vault.reserveForClaims(ethWei);
		emit Withdraw(msg.sender, receiver, owner, ethWei, wrstWei);
	}

	/* --------------------------- Oracle hooks -------------------------- */
	function setRateWei(uint256 newRateWei) external onlyRole(ORACLE_ROLE) {
		emit RateChanged(rateWei, newRateWei);
		rateWei = newRateWei;
	}

	function resetDailyCounters() external onlyRole(ORACLE_ROLE) {
		uint64 today = uint64(block.timestamp / 1 days);
		if (today > currentDay) {
			currentDay      = today;
			mintedTodayWei  = 0;
		}
	}
	
	/* ========== ERC-4626 OVERWRIDES ========== */

	/// @inheritdoc ERC4626Upgradeable
	function totalAssets() public view override returns (uint256) {
		return totalSupply();
	}

	/// @inheritdoc ERC4626Upgradeable
	function convertToShares(uint256 assets) public view override returns (uint256) {
		return assets * 1e18 / rateWei;
	}

	/// @inheritdoc ERC4626Upgradeable
	function convertToAssets(uint256 shares) public view override returns (uint256) {
		return shares * rateWei / 1e18;
	}

	/// @inheritdoc ERC4626Upgradeable
	function mint(uint256 shares, address receiver)
		public override nonReentrant whenNotPaused returns (uint256 assets)
	{
		(mintedWei, refundWei) = deposit(shares, receiver);
		return mintedWei;
	}

	/// @inheritdoc ERC4626Upgradeable
	function withdraw(uint256, address, address) public pure override {
		withdrawalQueue.requestWithdrawEth(uint256, address);
	}
	
	function withdraw(
		uint256 assets,
		address receiver,
		address owner
	)
		override
		nonReentrant
		whenNotPaused
		notFrozen(owner)
		notFrozen(receiver)
		returns (uint256 shares)
	{
		require(owner == msg.sender, "wrstETH: only owner");
	
		shares = getWrstETHByETH(assets);
		withdrawalQueue.requestWithdrawEth(shares, receiver, owner);
	}

	/// @inheritdoc ERC4626Upgradeable
	function redeem(
		uint256 shares,
		address receiver,
		address owner
	)
		public
		override
		nonReentrant
		whenNotPaused
		notFrozen(owner)
		notFrozen(receiver)
		returns (uint256 assets)
	{
		require(owner == msg.sender, "wrstETH: only owner");
		assets = getETHByWrstETH(shares);
		withdrawalQueue.requestWithdrawEth(shares, receiver, owner);
	}
}
