// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*────────────────── OpenZeppelin ──────────────────*/
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/*────────────── External interfaces ───────────────*/
interface IVault {
	function reserveForClaims(uint256 ethWei) external;
}

/**
 * @title   Wrapped Restaked Ether (wrstETH)
 */
contract WrstETH is
	ERC20CappedUpgradeable,
	ERC20BurnableUpgradeable,
	ERC20PermitUpgradeable,
	AccessControlUpgradeable,
	PausableUpgradeable
{
	/*──────────── Roles ───────────*/
	bytes32 public constant FREEZER_ROLE       = keccak256("FREEZER_ROLE");
	bytes32 public constant PAUSER_ROLE        = keccak256("PAUSER_ROLE");
	bytes32 public constant CAP_MANAGER_ROLE   = keccak256("CAP_MANAGER_ROLE");
	bytes32 public constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
	bytes32 public constant ORACLE_ROLE        = keccak256("ORACLE_ROLE");
	bytes32 public constant QUEUE_ROLE         = keccak256("QUEUE_ROLE");

	/*──────────── State ───────────*/
	IVault  public vault;                 ///< ETH vault contract
	uint256 public rateWei;               ///< ETH per 1 wrst (18 decimals)

	uint256 public dailyMintLimitWei;     ///< daily mint window
	uint256 public dailyBurnLimitWei;     ///< daily burn window
	uint256 public mintedTodayWei;
	uint256 public burnedTodayWei;
	uint64  public currentDayIdx;         ///< floor(block.timestamp / 1 days)

	mapping(address => bool) private _frozen;

	/*──────────── Events ──────────*/
	event Frozen(address indexed account);
	event Unfrozen(address indexed account);
	event Confiscated(address indexed account, uint256 amountWei);
	event CapChanged(uint256 oldCapWei, uint256 newCapWei);
	event DailyLimitsChanged(uint256 mintWei, uint256 burnWei);
	event RateChanged(uint256 oldRateWei, uint256 newRateWei);

	/*──────────────── Initializer ────────────────*/
	function initialize(
		address admin,
		address freezer,
		address pauser,
		address vaultAddr,
		uint256 capWei,
		uint256 dailyPercent              // 10 ⇒ 10 % cap per day
	) external initializer
	{
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

		vault    = IVault(vaultAddr);
		rateWei  = 1e18;                        // 1 wrst = 1 ETH

		uint256 window = capWei * dailyPercent / 100;
		_setDailyLimits(window, window);

		currentDayIdx = uint64(block.timestamp / 1 days);
	}

	/*──────────────── Freeze / confiscate ───────*/
	function freeze(address acct)   external onlyRole(FREEZER_ROLE){
		_frozen[acct] = true;  emit Frozen(acct);
	}
	function unfreeze(address acct) external onlyRole(FREEZER_ROLE){
		_frozen[acct] = false; emit Unfrozen(acct);
	}
	function confiscate(address acct) external onlyRole(FREEZER_ROLE){
		require(_frozen[acct], "WrstETH: not frozen");
		uint256 bal = balanceOf(acct);
		_burn(acct, bal);
		emit Confiscated(acct, bal);
	}
	function isFrozen(address acct) external view returns(bool){
		return _frozen[acct];
	}

	/*──────────────── Pause ──────────────*/
	function pause()   external onlyRole(PAUSER_ROLE) { _pause();  }
	function unpause() external onlyRole(PAUSER_ROLE) { _unpause();}

	/*──────────────── Cap & daily limits ─*/
	function setCap(uint256 newCap) external onlyRole(CAP_MANAGER_ROLE) {
		require(newCap > 0, "cap 0");
		emit CapChanged(cap(), newCap);
		_updateCap(newCap);                     // internal from OZ
	}
	function setDailyLimits(uint256 mintWei,uint256 burnWei)
		external onlyRole(LIMIT_MANAGER_ROLE)
	{ _setDailyLimits(mintWei,burnWei); }

	function _setDailyLimits(uint256 m,uint256 b) internal {
		dailyMintLimitWei = m; dailyBurnLimitWei = b;
		emit DailyLimitsChanged(m,b);
	}

	/*──────────────── View helpers ───────*/
	function wrstByEth(uint256 ethWei) public view returns(uint256){
		return ethWei * 1e18 / rateWei;
	}
	function ethByWrst(uint256 wrstWei) public view returns(uint256){
		return wrstWei * rateWei / 1e18;
	}

	/*──────────────── ERC20 hooks ────────*/
	function _beforeTokenTransfer(
		address from, address to, uint256 amt
	) internal override {
		require(!paused(), "WrstETH: paused");
		require(!_frozen[from] && !_frozen[to], "WrstETH: frozen");
		super._beforeTokenTransfer(from, to, amt);
	}

	/*──────────────── Deposit (mint) ─────*/
	function deposit()
		external payable whenNotPaused
		returns (uint256 mintedWei)
	{
		require(msg.value > 0, "WrstETH: zero ETH");

		uint256 wrstWei = wrstByEth(msg.value);
		_checkDailyMint(wrstWei);

		uint256 room = cap() - totalSupply();
		require(room > 0, "WrstETH: cap reached");
		if (wrstWei > room) wrstWei = room;          // clamp to cap

		uint256 ethForMint = ethByWrst(wrstWei);
		(bool okVault, ) = address(vault).call{value: ethForMint}("");
		require(okVault, "ETH: restaking push fail");
		
		mintedTodayWei += wrstWei;
		mintedWei = wrstWei;
		_mint(msg.sender, wrstWei);

		uint256 refund = msg.value - ethForMint;
		if (refund > 0) {
			(bool okRefund,) = payable(msg.sender).call{value: refund}("");
			require(okRefund, "WrstETH: refund fail");
		}
	}

	/*──────────────── Burn for withdrawal ─*/
	function burnForWithdrawal(address from,uint256 wrstWei)
		external whenNotPaused onlyRole(QUEUE_ROLE)
		returns(uint256 ethWei)
	{
		require(
			burnedTodayWei + wrstWei <= dailyBurnLimitWei,
			"WrstETH: daily burn cap"
		);
		burnedTodayWei += wrstWei;

		ethWei = ethByWrst(wrstWei);
		_burn(from, wrstWei);
		vault.reserveForClaims(ethWei);
	}

	/*──────────────── Oracle functions ───*/
	function setRateWei(uint256 newRate) external onlyRole(ORACLE_ROLE) {
		emit RateChanged(rateWei,newRate);
		rateWei = newRate;
	}
	function resetDailyCounters() external onlyRole(ORACLE_ROLE) {
		mintedTodayWei  = 0;
		burnedTodayWei  = 0;
		currentDayIdx   = uint64(block.timestamp / 1 days);
	}

	/*──────────────── Internals ──────────*/
	function _checkDailyMint(uint256 wrstWei) internal view {
		require(
			mintedTodayWei + wrstWei <= dailyMintLimitWei,
			"WrstETH: daily mint cap"
		);
	}
}
