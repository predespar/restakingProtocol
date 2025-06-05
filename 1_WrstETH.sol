// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───────────────────────── OpenZeppelin upgradeable ───────────────────────── */
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

/* ──────────────────────────── External interfaces ─────────────────────────── */
interface IRestakeVault {
	function reserveForClaims(uint256 ethWei) external;
}

/**
 * @title Wrapped Restaked ETH (wrstETH)
 * @notice ERC-20 wrapper for restaked ETH. Mint on deposit, burn on withdrawal.
 */
contract WrstETH is
	ERC20CappedUpgradeable,
	ERC20BurnableUpgradeable,
	ERC20PermitUpgradeable,
	AccessControlEnumerableUpgradeable,
	PausableUpgradeable,
	ReentrancyGuardUpgradeable
{
	using AddressUpgradeable for address payable;

	/* ------------------------------ Roles ------------------------------ */
	bytes32 public constant FREEZER_ROLE       = keccak256("FREEZER_ROLE");
	bytes32 public constant PAUSER_ROLE        = keccak256("PAUSER_ROLE");
	bytes32 public constant CAP_MANAGER_ROLE   = keccak256("CAP_MANAGER_ROLE");
	bytes32 public constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
	bytes32 public constant ORACLE_ROLE        = keccak256("ORACLE_ROLE");
	bytes32 public constant QUEUE_ROLE         = keccak256("QUEUE_ROLE");

	/* ------------------------------ Storage ---------------------------- */
	IRestakeVault public vault;         ///< Restake vault that manages restaking/unrestaking
	uint256       public rateWei;       ///< How many wei of ETH per 1 wrstETH (18 decimals)

	uint256 public dailyMintCapWei;     ///< 24-hour minting ceiling (in wrstETH wei)
	uint256 public mintedTodayWei;      ///< Amount minted since currentDay
	uint64  public currentDay;          ///< Floor(block.timestamp / 1 day)

	mapping(address => bool) private _frozen;   ///< Sanctions / fraud freeze list

	/* ------------------------------ Events ----------------------------- */
	event Frozen(address indexed account);
	event Unfrozen(address indexed account);
	event Confiscated(address indexed account, uint256 amount);

	event CapChanged(uint256 oldCapWei, uint256 newCapWei);
	event DailyCapChanged(uint256 newDailyCapWei);
	event RateChanged(uint256 oldRateWei, uint256 newRateWei);

	event FreezerChanged(address oldFreezer, address newFreezer);
	event PauserChanged(address oldPauser,  address newPauser);

	/* ------------------------------ Initializer ------------------------ */
	function initialize(
		address admin,
		address freezer,
		address pauser,
		address vaultAddr,
		uint256 capWei,
		uint8   dailyPercent              // must be 1-100
	) external initializer {
		require(dailyPercent >= 1 && dailyPercent <= 100, "wrstETH: bad %");

		__ERC20_init("Wrapped Restaked ETH", "wrstETH");
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

		vault           = IRestakeVault(vaultAddr);
		rateWei         = 1e18;                                     // 1:1 initial rate
		dailyMintCapWei = capWei * dailyPercent / 100;
		currentDay      = uint64(block.timestamp / 1 days);
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
		dailyMintCapWei = cap() * percent / 100;
		emit DailyCapChanged(dailyMintCapWei);
	}

	/* ------------------------ Role rotation (admin) -------------------- */
	function setFreezer(address newFreezer) external onlyRole(DEFAULT_ADMIN_ROLE) {
		require(newFreezer != address(0), "wrstETH: zero freezer");
		_revokeRole(FREEZER_ROLE, getRoleMember(FREEZER_ROLE, 0));
		_grantRole(FREEZER_ROLE,  newFreezer);
		emit FreezerChanged(getRoleMember(FREEZER_ROLE, 0), newFreezer);
	}
	function setPauser(address newPauser)  external onlyRole(DEFAULT_ADMIN_ROLE) {
		require(newPauser != address(0), "wrstETH: zero pauser");
		_revokeRole(PAUSER_ROLE, getRoleMember(PAUSER_ROLE, 0));
		_grantRole(PAUSER_ROLE,  newPauser);
		emit PauserChanged(getRoleMember(PAUSER_ROLE, 0), newPauser);
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

	/* ------------------------------ Deposit ---------------------------- */
	/**
	 * @notice Wrap ETH into wrstETH. Follows the checks-effects-interactions
	 *         pattern and is protected by `nonReentrant`.
	 *
	 * @return mintedWei  Amount of wrstETH minted to the sender
	 * @return refundWei  Excess ETH returned to the sender (if cap reached)
	 */
	function deposit()
		external payable whenNotPaused nonReentrant
		returns (uint256 mintedWei, uint256 refundWei)
	{
		require(msg.value > 0, "wrstETH: zero ETH");

		/* ---------- Cap & daily-limit checks ---------- */
		uint256 wrstWei = getWrstETHByETH(msg.value);
		uint256 remainingCap = cap() - totalSupply();
		if (wrstWei > remainingCap) wrstWei = remainingCap;

		// Reset counters at start of a new UTC day
		uint64 today = uint64(block.timestamp / 1 days);
		if (today > currentDay) {
			currentDay      = today;
			mintedTodayWei  = 0;
		}
		require(mintedTodayWei + wrstWei <= dailyMintCapWei, "wrstETH: daily cap");

		/* ---------- Interactions ---------- */
		uint256 ethToRestake = getETHByWrstETH(wrstWei);
		// Send ETH to the vault; revert entire tx if transfer fails
		payable(address(vault)).sendValue(ethToRestake);

		// Return change if user over-sent because of cap exhaustion
		refundWei = msg.value - ethToRestake;
		if (refundWei > 0) payable(msg.sender).sendValue(refundWei);
		
		/* ---------- Effects ---------- */
		mintedTodayWei += wrstWei;
		_mint(msg.sender, wrstWei);

		mintedWei = wrstWei;
	}

	/* ------------------------------ Burn ------------------------------- */
	/**
	 * @dev Burn tokens when `WithdrawalQueue` prepares a withdrawal.
	 *      Only callable by the queue contract.
	 */
	function burnForWithdrawal(address from, uint256 wrstWei)
		external whenNotPaused onlyRole(QUEUE_ROLE)
		returns (uint256 ethWei)
	{
		ethWei = getETHByWrstETH(wrstWei);
		_burn(from, wrstWei);
		vault.reserveForClaims(ethWei);
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
}
