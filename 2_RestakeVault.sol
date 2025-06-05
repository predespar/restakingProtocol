// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───────────────────────── OpenZeppelin upgradeable ───────────────────────── */
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

/**
 * @title RestakeVault
 * @notice restaking/unrestaking manager.
 */
contract RestakeVault is
	AccessControlEnumerableUpgradeable,
	ReentrancyGuardUpgradeable
{
	using AddressUpgradeable for address payable;

	/* ------------------------------ Roles ------------------------------ */
	bytes32 public constant RESTAKER_ROLE = keccak256("RESTAKER_ROLE");
	bytes32 public constant ORACLE_ROLE   = keccak256("ORACLE_ROLE");

	/* -------------------- External contract addresses ------------------ */
	address public wrstETHToken;   ///< wrstETH proxy (for pause checks)

	/* --------------------------- State vars ---------------------------- */
	uint256 private _claimReserveWei;    // Reserved for queued withdrawals

	/* ------------------------------ Events ----------------------------- */
	event RestakerChanged(address oldRestaker, address newRestaker);
	event OracleChanged(  address oldOracle,   address newOracle);

	/* ------------------------------ Initializer ------------------------ */
	function initialize(
		address admin,
		address restaker,
		address oracle,
		address wrstETHAddr
	) external initializer {
		__AccessControlEnumerable_init();
		__ReentrancyGuard_init();

		_grantRole(DEFAULT_ADMIN_ROLE, admin);
		_grantRole(RESTAKER_ROLE,     restaker);
		_grantRole(ORACLE_ROLE,       oracle);

		wrstETHToken = wrstETHAddr;
	}

	/* ------------------------- Modifiers ------------------------------- */
	modifier wrstETHNotPaused() {
		(bool ok, bytes memory data) =
			wrstETHToken.staticcall(abi.encodeWithSignature("paused()"));
		require(ok && data.length == 32 && !abi.decode(data, (bool)),
				"Vault: wrstETH paused");
		_;
	}

	/* ----------------------- Liquidity outflow ------------------------- */
	/**
	 * @notice Move assets to restaking venue.
	 */
	function withdrawForRestaking(uint256 amountEthWei)
		external
		nonReentrant
		wrstETHNotPaused
		onlyRole(RESTAKER_ROLE)
	{
		require(
			address(this).balance - _claimReserveWei >= amountWei,
			"Vault: insufficient liquidity"
		);
		payable(msg.sender).sendValue(amountWei);
	}

	/* ----------------------- Liquidity inflow -------------------------- */
	function depositFromRestaker() external payable onlyRole(RESTAKER_ROLE) {}

	/* -------------- Oracle reserve / release management ---------------- */
	function reserveForClaims(uint256 ethWei)
		external onlyRole(ORACLE_ROLE)
	{ _claimReserveWei += ethWei; }

	function releaseClaim(address payable user, uint256 ethWei)
		external
		nonReentrant
		wrstETHNotPaused
		onlyRole(ORACLE_ROLE)
	{
		_claimReserveWei -= ethWei;
		user.sendValue(ethWei);
	}

	/* ------------------------- Restricted getters ---------------------- */
	function getClaimReserveWei()
		external view
		returns (uint256)
	{
		require(
			hasRole(ORACLE_ROLE, msg.sender) ||
			hasRole(RESTAKER_ROLE, msg.sender),
			"Vault: access denied"
		);
		return _claimReserveWei;
	}

	/* -------------------- Admin role rotation helpers ------------------ */
	function setRestaker(address newRestaker)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(newRestaker != address(0), "vault: zero Restaker");
		_revokeRole(RESTAKER_ROLE, getRoleMember(RESTAKER_ROLE, 0));
		_grantRole(RESTAKER_ROLE,  newRestaker);
		emit RestakerChanged(getRoleMember(RESTAKER_ROLE, 0), newRestaker);
	}

	function setOracle(address newOracle)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(newOracle != address(0), "vault: zero Oracle");
		_revokeRole(ORACLE_ROLE, getRoleMember(ORACLE_ROLE, 0));
		_grantRole(ORACLE_ROLE,  newOracle);
		emit OracleChanged(getRoleMember(ORACLE_ROLE, 0), newOracle);
	}

	/* ----------------------- Asset sweeping ---------------------------- */
	/**
	 * @dev Idle ETH / ERC-20 sweeping.
	 */
	function sweep(address token, address to, uint256 amount)
		external onlyRole(RESTAKER_ROLE)
	{
		if (token == address(0)) {
			payable(to).sendValue(amount);               // reverts on failure
		} else {
			// ERC-20 sweep — compatible with non-standard tokens that return no bool
			bytes memory data =
				abi.encodeWithSelector(IERC20Upgradeable.transfer.selector, to, amount);
			(bool ok, bytes memory ret) = token.call(data);
			require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "Vault: sweep ERC-20");
		}
	}

	/* --------------------- Receive plain ETH --------------------------- */
	receive() external payable {}
}
