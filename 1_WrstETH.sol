// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───────────────── OpenZeppelin ───────────────── */
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

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
	/* ───────── roles ───────── */
	bytes32 public constant FREEZER_ROLE       = keccak256("FREEZER_ROLE");
	bytes32 public constant PAUSER_ROLE        = keccak256("PAUSER_ROLE");
	bytes32 public constant CAP_MANAGER_ROLE   = keccak256("CAP_MANAGER_ROLE");
	bytes32 public constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
	bytes32 public constant ORACLE_ROLE        = keccak256("ORACLE_ROLE");
	bytes32 public constant QUEUE_ROLE         = keccak256("QUEUE_ROLE");

	/* ───────── state ───────── */
	IRestakeVault  public vault;
	uint256        public rateWei;               // ETH per 1 wrstETH (18 dec)

	uint256 public dailyMintLimitWei;
	uint256 public mintedTodayWei;
	uint64  public currentDayIdx;

	mapping(address => bool) private _frozen;

	/* ───────── events ──────── */
	event Frozen(address indexed);
	event Unfrozen(address indexed);
	event Confiscated(address indexed, uint256);
	event CapChanged(uint256, uint256);
	event DailyLimitChanged(uint256);
	event RateChanged(uint256, uint256);

	/* ───────── init ────────── */
	function initialize(
		address admin,
		address freezer,
		address pauser,
		address vaultAddr,
		uint256 capWei,
		uint8   dailyPercent               // 1..100
	) external initializer
	{
		require(dailyPercent >= 1 && dailyPercent <= 100, "bad %");

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
		rateWei = 1e18;									// 1 wrstETH = 1 ETH on T0

		dailyMintLimitWei = capWei * dailyPercent / 100;
		currentDayIdx     = uint64(block.timestamp / 1 days);
	}

	/* ───────── freeze ──────── */
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

	/* ───────── Cap & daily limit ── */
	function setCap(uint256 newCap) external onlyRole(CAP_MANAGER_ROLE) {
		require(newCap > 0, "cap 0");
		emit CapChanged(cap(), newCap);
		_updateCap(newCap);
	}
	function setDailyPercent(uint8 percent)
		external onlyRole(LIMIT_MANAGER_ROLE)
	{
		require(percent >= 1 && percent <= 100, "bad %");
		dailyMintLimitWei = cap() * percent / 100;
		emit DailyLimitChanged(dailyMintLimitWei);
	}

	/* ───────── helpers ────── */
	function getWrstETHByETH(uint256 ethWei)
		public view returns (uint256) { return ethWei * 1e18 / rateWei; }
		
	function getETHByWrstETH(uint256 wrstWei)
		public view returns (uint256) { return wrstWei * rateWei / 1e18;  }

	/* ───────── ERC-20 Transfer hook ─── */
	function _beforeTokenTransfer(address from, address to, uint256 amt)
		internal override
	{
		require(!paused(),                 "paused");
		require(!_frozen[from] && !_frozen[to], "frozen");
		super._beforeTokenTransfer(from, to, amt);
	}

	/* ───────── deposit ─────── */
	function deposit()
		external payable whenNotPaused
		returns (uint256 mintedWei, uint256 refundWei)
	{
		require(msg.value > 0, "zero ETH");

		uint256 wrstWei    = getWrstETHByETH(msg.value);
		uint256 remaining  = cap() - totalSupply();
		require(remaining > 0, "cap hit");
		if (wrstWei > remaining) wrstWei = remaining;

		require(
			mintedTodayWei + wrstWei <= dailyMintLimitWei,
			"daily cap"
		);

		uint256 ethToRestake = getETHByWrstETH(wrstWei);
		(bool okPush, ) = address(vault).call{value: ethToRestake}("");
		require(okPush, "push fail");

		refundWei = msg.value - ethToRestake;
		if (refundWei > 0) {
			(bool okRefund, ) = payable(msg.sender).call{value: refundWei}("");
			require(okRefund, "refund fail");
		}

		mintedTodayWei += wrstWei;
		mintedWei      = wrstWei;
		_mint(msg.sender, wrstWei);
	}

	/* ───────── burn for withdraw ─ */
	function burnForWithdrawal(address from, uint256 wrstWei)
		external whenNotPaused onlyRole(QUEUE_ROLE)
		returns (uint256 ethWei)
	{
		ethWei = getETHByWrstETH(wrstWei);
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
}
