// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───── OpenZeppelin ───── */
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/* ───── External interfaces ───── */
interface IRestakeVault {
	function reserveForClaims(uint256 ethWei) external;
}

/**
 *  @title  Wrapped Restaked ETH – wrstETH
 *  @notice Mint-path : user → deposit() → wrstETH mints → pushes ETH to restaking.
 *          Burn-path : WithdrawalQueue → burnForWithdrawal() → reserves ETH for claim.
 */
contract WrstETH is
	ERC20CappedUpgradeable,
	ERC20BurnableUpgradeable,
	ERC20PermitUpgradeable,
	AccessControlUpgradeable,
	PausableUpgradeable
{
	/* ───── Roles ───── */
	bytes32 public constant FREEZER_ROLE       = keccak256("FREEZER_ROLE");
	bytes32 public constant PAUSER_ROLE        = keccak256("PAUSER_ROLE");
	bytes32 public constant CAP_MANAGER_ROLE   = keccak256("CAP_MANAGER_ROLE");
	bytes32 public constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
	bytes32 public constant ORACLE_ROLE        = keccak256("ORACLE_ROLE");
	bytes32 public constant QUEUE_ROLE         = keccak256("QUEUE_ROLE");

	/* ───── Storage ───── */
	IRestakeVault  public vault;               ///< restaking vault
	uint256        public rateWei;             ///< ETH per 1 wrstETH (18 dec)

	uint256 public dailyMintLimitWei;          ///< daily window
	uint256 public dailyBurnLimitWei;

	uint256 public mintedTodayWei;
	uint256 public burnedTodayWei;
	uint64  public currentDayIdx;              ///< floor(block.timestamp / 1 days)

	mapping(address => bool) private _frozen;

	/* ───── Events ───── */
	event Frozen(address indexed account);
	event Unfrozen(address indexed account);
	event Confiscated(address indexed account, uint256 amountWei);
	event CapChanged(uint256 oldCapWei, uint256 newCapWei);
	event DailyLimitsChanged(uint256 mintWei, uint256 burnWei);
	event RateChanged(uint256 oldRateWei, uint256 newRateWei);

	/* ───── Initialiser ───── */
	function initialize(
		address admin,
		address freezer,
		address pauser,
		address vaultAddr,
		uint256 capWei,
		uint256 dailyPercent                          // must be 1…100
	) external initializer
	{
		require(dailyPercent >= 1 && dailyPercent <= 100, "wrstETH: bad %");

		__ERC20_init("Wrapped Restaked ETH", "wrstETH");
		__ERC20Capped_init(capWei);
		__ERC20Permit_init("Wrapped Restaked ETH");
		__AccessControl_init();
		__Pausable_init();

		_grantRole(DEFAULT_ADMIN_ROLE, admin);
		_grantRole(FREEZER_ROLE,       freezer);
		_grantRole(PAUSER_ROLE,        pauser);
		_grantRole(CAP_MANAGER_ROLE,   admin);
		_grantRole(LIMIT_MANAGER_ROLE, admin);

		vault   = IRestakeVault(vaultAddr);
		rateWei = 1e18;                                // 1 wrstETH = 1 ETH on T0

		uint256 dailyCapWei = capWei * dailyPercent / 100;
		_setDailyLimits(dailyCapWei, dailyCapWei);

		currentDayIdx = uint64(block.timestamp / 1 days);
	}

	/* ───────────────────────── Freezing ───────────────────────── */
	function freeze(address acct)   external onlyRole(FREEZER_ROLE) {
		_frozen[acct] = true;
		emit Frozen(acct);
	}
	function unfreeze(address acct) external onlyRole(FREEZER_ROLE) {
		_frozen[acct] = false;
		emit Unfrozen(acct);
	}
	function confiscate(address acct) external onlyRole(FREEZER_ROLE) {
		require(_frozen[acct], "wrstETH: not frozen");
		uint256 bal = balanceOf(acct);
		_burn(acct, bal);
		emit Confiscated(acct, bal);
	}
	function isFrozen(address acct) external view returns (bool) {
		return _frozen[acct];
	}

	/* ───────────────────────── Pause ──────────────────────────── */
	function pause()   external onlyRole(PAUSER_ROLE) { _pause();   }
	function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

	/* ──────────────────── Cap & daily limits ─────────────────── */
	function setCap(uint256 newCapWei) external onlyRole(CAP_MANAGER_ROLE) {
		require(newCapWei > 0, "wrstETH: cap 0");
		emit CapChanged(cap(), newCapWei);
		_updateCap(newCapWei);                        // OZ internal
	}
	function setDailyPercent(uint256 dailyPercent)
		external onlyRole(LIMIT_MANAGER_ROLE)
	{
		require(dailyPercent >= 1 && dailyPercent <= 100, "wrstETH: bad %");
		uint256 dailyCapWei = cap() * dailyPercent / 100;
		_setDailyLimits(dailyCapWei, dailyCapWei);
	}
	function _setDailyLimits(uint256 mintWei, uint256 burnWei) internal {
		dailyMintLimitWei = mintWei;
		dailyBurnLimitWei = burnWei;
		emit DailyLimitsChanged(mintWei, burnWei);
	}

	/* ───────────────────────── Helpers ───────────────────────── */
	function wrstByEth(uint256 ethWei) public view returns (uint256) {
		return ethWei * 1e18 / rateWei;
	}
	function ethByWrst(uint256 wrstWei) public view returns (uint256) {
		return wrstWei * rateWei / 1e18;
	}

	/* ───────────────────── Transfer hook ─────────────────────── */
	function _beforeTokenTransfer(address from, address to, uint256 amt)
		internal override
	{
		require(!paused(), "wrstETH: paused");
		require(!_frozen[from] && !_frozen[to], "wrstETH: frozen");
		super._beforeTokenTransfer(from, to, amt);   // cap & OZ logic
	}

	/* ───────────────────────── Deposit ───────────────────────── */
	function deposit()
		external
		payable
		whenNotPaused
		returns (uint256 mintedWei, uint256 refundWei)
	{
		require(msg.value > 0, "wrstETH: zero ETH");

		uint256 wrstWei = wrstByEth(msg.value);
		_checkDailyMint(wrstWei);

		uint256 remaining = cap() - totalSupply();
		require(remaining > 0, "wrstETH: cap reached");
		if (wrstWei > remaining) wrstWei = remaining;

		/* push ETH first */
		uint256 ethToRestake = ethByWrst(wrstWei);
		(bool okRestake, ) = address(vault).call{value: ethToRestake}("");
		require(okRestake, "wrstETH: restake push fail");

		/* refund surplus ETH */
		refundWei = msg.value - ethToRestake;
		if (refundWei > 0) {
			(bool okRefund, ) = payable(msg.sender).call{value: refundWei}("");
			if (!okRefund) {
				/* fallback: keep surplus in vault & issue claim NFT */
				vault.reserveForClaims(refundWei);
			}
		}

		/* mint last — so any revert above prevents dilution */
		mintedTodayWei += wrstWei;
		mintedWei = wrstWei;
		_mint(msg.sender, wrstWei);
	}

	/* ───────────────── Burn for withdrawal ───────────────────── */
	function burnForWithdrawal(address from, uint256 wrstWei)
		external
		whenNotPaused
		onlyRole(QUEUE_ROLE)
		returns (uint256 ethWei)
	{
		require(
			burnedTodayWei + wrstWei <= dailyBurnLimitWei,
			"wrstETH: daily burn cap"
		);
		burnedTodayWei += wrstWei;

		ethWei = ethByWrst(wrstWei);
		_burn(from, wrstWei);
		vault.reserveForClaims(ethWei);
	}

	/* ─────────────────── Oracle-only calls ───────────────────── */
	function setRateWei(uint256 newRateWei) external onlyRole(ORACLE_ROLE) {
		emit RateChanged(rateWei, newRateWei);
		rateWei = newRateWei;
	}
	function resetDailyCounters() external onlyRole(ORACLE_ROLE) {
		mintedTodayWei = 0;
		burnedTodayWei = 0;
		currentDayIdx  = uint64(block.timestamp / 1 days);
	}

	/* ──────────────────── Internal utils ─────────────────────── */
	function _checkDailyMint(uint256 wrstWei) internal view {
		require(
			mintedTodayWei + wrstWei <= dailyMintLimitWei,
			"wrstETH: daily mint cap"
		);
	}
}
