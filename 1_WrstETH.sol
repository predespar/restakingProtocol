// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ─────────── OpenZeppelin ─────────── */
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

/* ─────────── Local interfaces ─────── */
interface IRestakeVault {
	function reserveForClaims(uint256 ethWei) external;
}

/**
 * @title Wrapped Restaked ETH – wrstETH (v2)
 * @notice ERC-20 token side of the restaking protocol (ETH flavour).
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

	/* ───────── Roles ─────── */
	bytes32 public constant FREEZER_ROLE       = keccak256("FREEZER_ROLE");
	bytes32 public constant PAUSER_ROLE        = keccak256("PAUSER_ROLE");
	bytes32 public constant CAP_MANAGER_ROLE   = keccak256("CAP_MANAGER_ROLE");
	bytes32 public constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
	bytes32 public constant ORACLE_ROLE        = keccak256("ORACLE_ROLE");
	bytes32 public constant QUEUE_ROLE         = keccak256("QUEUE_ROLE");

	/* ───────── Storage ───── */
	IRestakeVault  public vault;           ///< vault that actually manages restaking/unrestaking ETH
	uint256        public rateWei;         ///< ETH per 1 wrstETH (18 decimals)
	uint256 public dailyMintCapWei;        ///< daily mint cap
	uint256 public mintedTodayWei;         ///< minted today (18 decimals)
	uint64  public currentDay;             ///< floor(block.timestamp / 1 days)

	mapping(address => bool) private _frozen;

	/* ───────── Events ────── */
	event Frozen(address indexed account);
	event Unfrozen(address indexed account);
	event Confiscated(address indexed account, uint256 value);
	event CapChanged(uint256 oldCap, uint256 newCap);
	event DailyCapChanged(uint256 newDailyCap);
	event RateChanged(uint256 oldRateWei, uint256 newRateWei);
	event FreezerUpdated(address indexed oldFreezer, address indexed newFreezer);
	event PauserUpdated(address indexed oldPauser,  address indexed newPauser);

	/* ───────── Init ──────── */
	function initialize(
		address admin,
		address freezer,
		address pauser,
		address vaultAddr,
		uint256 capWei,
		uint8   dailyPercent                    // 1-100
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
		rateWei         = 1e18;                           // 1 wrstETH == 1 ETH on start
		dailyMintCapWei = capWei * dailyPercent / 100;
		currentDay      = uint64(block.timestamp / 1 days);
	}

	/* ───────── Admin updates (freezer / pauser) ───────── */
	function setFreezer(address oldFreezer, address newFreezer)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(newFreezer != address(0), "wrstETH: zero freezer");
		_revokeRole(FREEZER_ROLE, oldFreezer);
		_grantRole(FREEZER_ROLE,  newFreezer);
		emit FreezerUpdated(oldFreezer, newFreezer);
	}

	function setPauser(address oldPauser, address newPauser)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(newPauser != address(0), "wrstETH: zero pauser");
		_revokeRole(PAUSER_ROLE, oldPauser);
		_grantRole(PAUSER_ROLE,  newPauser);
		emit PauserUpdated(oldPauser, newPauser);
	}

	/* ───────── Pause / Freeze ───── */
	function pause()   external onlyRole(PAUSER_ROLE)   { _pause();   }
	function unpause() external onlyRole(PAUSER_ROLE)   { _unpause(); }

	function freeze(address a)   external onlyRole(FREEZER_ROLE) { _frozen[a] = true;  emit Frozen(a); }
	function unfreeze(address a) external onlyRole(FREEZER_ROLE) { _frozen[a] = false; emit Unfrozen(a); }
	function confiscate(address account) external onlyRole(FREEZER_ROLE) {
		require(_frozen[account], "wrstETH: not frozen");
		uint256 bal = balanceOf(account);
		_burn(account, bal);
		emit Confiscated(account, bal);
	}
	function isFrozen(address a) external view returns (bool) { return _frozen[a]; }

	/* ───────── Cap & daily limit ───── */
	function setCap(uint256 newCapWei) external onlyRole(CAP_MANAGER_ROLE) {
		require(newCapWei > 0, "cap 0");
		emit CapChanged(cap(), newCapWei);
		_updateCap(newCapWei);
		// корректируем дневной лимит пропорционально
		dailyMintCapWei = newCapWei * dailyMintCapWei / cap();
	}

	function setDailyPercent(uint8 percent) external onlyRole(LIMIT_MANAGER_ROLE) {
		require(percent >= 1 && percent <= 100, "wrstETH: bad %");
		dailyMintCapWei = cap() * percent / 100;
		emit DailyCapChanged(dailyMintCapWei);
	}

	/* ───────── Helpers — pricing ───── */
	function getWrstETHByETH(uint256 ethWei) public view returns (uint256) {
		return ethWei * 1e18 / rateWei;
	}
	function getETHByWrstETH(uint256 wrstWei) public view returns (uint256) {
		return wrstWei * rateWei / 1e18;
	}

	/* ───────── Transfer guard ─────── */
	function _beforeTokenTransfer(address from, address to, uint256 amount)
		internal override
	{
		require(!paused(), "wrstETH: paused");
		require(!_frozen[from] && !_frozen[to], "wrstETH: frozen");
		super._beforeTokenTransfer(from, to, amount);
	}

	/* ───────── Deposit (mint) ─────── */
	function deposit()
		external payable whenNotPaused nonReentrant
		returns (uint256 mintedWei, uint256 refundWei)
	{
		require(msg.value > 0, "wrstETH: zero ETH");

		// 1. checks — лимиты
		uint256 wrstWeiWanted = getWrstETHByETH(msg.value);
		uint256 remain        = cap() - totalSupply();
		if (wrstWeiWanted > remain) wrstWeiWanted = remain;
		require(remain > 0, "wrstETH: cap reached");
		require(mintedTodayWei + wrstWeiWanted <= dailyMintCapWei, "wrstETH: daily cap");

		uint256 ethToRestake = getETHByWrstETH(wrstWeiWanted);
		refundWei            = msg.value - ethToRestake;

		// 2. interactions — отправляем ETH в хранилище
		(bool okPush, ) = address(vault).call{value: ethToRestake}("");
		require(okPush, "wrstETH: push fail");
		if (refundWei > 0) payable(msg.sender).sendValue(refundWei);

		// 3. effects — фиксируем состояние после успешных интеракций
		mintedTodayWei += wrstWeiWanted;
		mintedWei       = wrstWeiWanted;
		_mint(msg.sender, wrstWeiWanted);
	}

	/* ───────── Burn by queue ─────── */
	function burnForWithdrawal(address from, uint256 wrstWei)
		external whenNotPaused onlyRole(QUEUE_ROLE) nonReentrant
		returns (uint256 ethWei)
	{
		ethWei = getETHByWrstETH(wrstWei);
		_burn(from, wrstWei);
		vault.reserveForClaims(ethWei);
	}

	/* ───────── Oracle actions ─────── */
	function setRateWei(uint256 newRateWei) external onlyRole(ORACLE_ROLE) {
		emit RateChanged(rateWei, newRateWei);
		rateWei = newRateWei;
	}

	function resetDailyCounters() external onlyRole(ORACLE_ROLE) {
		mintedTodayWei = 0;
		currentDay     = uint64(block.timestamp / 1 days);
	}
}
