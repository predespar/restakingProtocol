// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───────────────────────── OpenZeppelin upgradeable ───────────────────────── */
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

/* ──────────────────────────── External interfaces ─────────────────────────── */
interface IWrstToken {
	function paused() external view returns (bool);
}

/**
 * @title RestakeVault
 * @notice Restaking / un-restaking manager.
 */
contract RestakeVault is
	AccessControlEnumerableUpgradeable,
	ReentrancyGuardUpgradeable
{
	using AddressUpgradeable for address payable;

	/* ------------------------------ Roles ------------------------------ */
	bytes32 public constant RESTAKER_ROLE = keccak256("RESTAKER_ROLE");
	bytes32 public constant ORACLE_ROLE   = keccak256("ORACLE_ROLE");
	bytes32 public constant QUEUE_ROLE    = keccak256("QUEUE_ROLE");

	/* -------------------- External contract addresses ------------------ */
	IWrstToken public wrstETHToken;   ///< wrstETH proxy (for pause checks)

	/* --------------------------- State vars ---------------------------- */
	uint256 private _claimReserveWei;    // Reserved for queued withdrawals

	/* ------------------------------ Events ----------------------------- */
	event RestakerChanged(address indexed oldRestaker, address indexed newRestaker);
	event OracleChanged(  address indexed oldOracle,   address indexed newOracle);
	event QueueChanged(   address indexed oldQueue,    address indexed newQueue);

	/* ------------------------------ Initializer ------------------------ */
	function initialize(
		address admin,
		address restaker,
		address oracle,
		address queue,
		address wrstETHAddr
	) external initializer {
		__AccessControlEnumerable_init();
		__ReentrancyGuard_init();

		_grantRole(DEFAULT_ADMIN_ROLE, admin);
		_grantRole(RESTAKER_ROLE,     restaker);
		_grantRole(ORACLE_ROLE,       oracle);
		_grantRole(QUEUE_ROLE,        queue);

		wrstETHToken = IWrstToken(wrstETHAddr);
	}

	/* ------------------------- Modifiers ------------------------------- */
	modifier wrstETHNotPaused() {
		require(!wrstETHToken.paused(), "Vault: wrstETH paused");
		_;
	}

	/* ----------------------- Liquidity outflow ------------------------- */
	/**
	 * @notice Move assets to a restaking venue.
	 * @param amountEthWei Amount of ETH (in wei) to withdraw.
	 */
	function withdrawForRestaking(uint256 amountEthWei)
		external
		nonReentrant
		wrstETHNotPaused
		onlyRole(RESTAKER_ROLE)
	{
		require(
			address(this).balance - _claimReserveWei >= amountEthWei,
			"Vault: insufficient liquidity"
		);
		payable(msg.sender).sendValue(amountEthWei);   // reverts on failure
	}

	/* ----------------------- Liquidity inflow -------------------------- */
	function depositFromRestaker() external payable onlyRole(RESTAKER_ROLE) {}

	/* -------------- Oracle reserve / release management ---------------- */
	function reserveForClaims(uint256 ethWei)
		external onlyRole(ORACLE_ROLE)
	{ _claimReserveWei += ethWei; }

	/**
	 * @dev Called by WithdrawalQueue when a user claims ready ETH.
	 */
	function releaseClaim(address payable user, uint256 ethWei)
		external
		nonReentrant
		wrstETHNotPaused
		onlyRole(QUEUE_ROLE)
	{
		_claimReserveWei -= ethWei;
		user.sendValue(ethWei);                      // reverts on failure
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
		require(newRestaker != address(0), "Vault: zero Restaker");
		address old = getRoleMember(RESTAKER_ROLE, 0);
		_revokeRole(RESTAKER_ROLE, old);
		_grantRole(RESTAKER_ROLE,  newRestaker);
		emit RestakerChanged(old, newRestaker);
	}

	function setOracle(address newOracle)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(newOracle != address(0), "Vault: zero Oracle");
		address old = getRoleMember(ORACLE_ROLE, 0);
		_revokeRole(ORACLE_ROLE, old);
		_grantRole(ORACLE_ROLE,  newOracle);
		emit OracleChanged(old, newOracle);
	}

	function setQueue(address newQueue)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(newQueue != address(0), "Vault: zero Queue");
		address old = getRoleMember(QUEUE_ROLE, 0);
		_revokeRole(QUEUE_ROLE, old);
		_grantRole(QUEUE_ROLE,  newQueue);
		emit QueueChanged(old, newQueue);
	}

	/* ----------------------- Asset sweeping ---------------------------- */
	/**
	 * @dev Idle ETH / ERC-20 sweeping. Only the licensed restaker can call.
	 */
	function sweep(address token, address to, uint256 amount)
		external onlyRole(RESTAKER_ROLE)
	{
		if (token == address(0)) {
			payable(to).sendValue(amount);               // reverts on failure
		} else {
			// ERC-20 sweep — compatible with tokens that return no bool
			bytes memory data =
				abi.encodeWithSelector(IERC20Upgradeable.transfer.selector, to, amount);
			(bool ok, bytes memory ret) = token.call(data);
			require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "Vault: sweep ERC-20");
		}
	}

	/* --------------------- Receive plain ETH --------------------------- */
	receive() external payable {}
}
