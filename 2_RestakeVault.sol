// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───────────────────────── OpenZeppelin upgradeable ───────────────────────── */
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

/* ──────────────────────────── External interfaces ─────────────────────────── */
interface IWrstToken {
	function paused() external view returns (bool);
}

// --- WETH9 minimal interface ---
interface IWETH9 is IERC20Upgradeable {
	function deposit() external payable;
	function withdraw(uint256) external;
}

/**
 * @title RestakeVault
 * @notice Restaking / un-restaking manager.
 */
contract RestakeVault is
	AccessControlEnumerableUpgradeable,
	ReentrancyGuardUpgradeable
{
	using AddressUpgradeable   for address payable;
	using SafeERC20Upgradeable for IERC20Upgradeable;

	/* ------------------------------ Roles ------------------------------ */
	bytes32 public constant RESTAKER_ROLE = keccak256("RESTAKER_ROLE");
	bytes32 public constant ORACLE_ROLE   = keccak256("ORACLE_ROLE");
	bytes32 public constant QUEUE_ROLE    = keccak256("QUEUE_ROLE");
	/// @notice Granted **only** to the wrstETH contract – gate for incoming ETH.
	bytes32 public constant WRSTETH_ROLE   = keccak256("WRSTETH_ROLE");

	/* ------------------------- Pending addresses ----------------------- */
	address public pendingAdmin;
	address public pendingRestaker;

	/* -------------------- External contract addresses ------------------ */
	IWrstToken public wrstETHToken;   ///< wrstETH proxy (for pause checks)
	IWETH9     public wETH; 

	/* --------------------------- State vars ---------------------------- */
	uint256 public claimReserveEthAmt;    // Reserved for queued withdrawals

	/* ------------------------------ Events ----------------------------- */
	event AdminProposed(address oldAdmin, address newAdmin);
	event AdminChanged(address oldAdmin, address newAdmin);
	
	event RestakerProposed(address oldRestaker, address newRestaker);
	event RestakerChanged(address oldRestaker, address newRestaker);

	event OracleChanged(address oldOracle, address newOracle);
	event QueueChanged(address oldQueue, address newQueue);

	/* ------------------------------ Initializer ------------------------ */
	function initialize(
		address admin,
		address restaker,
		address oracle,
		address queue,
		address wrstETHAddr,
		address wETHAddr
	) external initializer {
		__AccessControlEnumerable_init();
		__ReentrancyGuard_init();

		_grantRole(DEFAULT_ADMIN_ROLE, admin);
		_grantRole(RESTAKER_ROLE,     restaker);
		_grantRole(ORACLE_ROLE,       oracle);
		_grantRole(QUEUE_ROLE,        queue);
		_grantRole(WRSTETH_ROLE,      wrstETHAddr); 

		wrstETHToken = IWrstToken(wrstETHAddr);
		wETH         = IWETH9(wETHAddr); 
	}

	/* ------------------------- Modifiers ------------------------------- */
	modifier wrstETHNotPaused() {
		require(!wrstETHToken.paused(), "Vault: wrstETH paused");
		_;
	}

	/* ----------------------- Liquidity outflow ------------------------- */
	/**
	 * @notice Move assets to a restaking venue.
	 * @param ethAmt Amount of ETH to withdraw (in Wei).
	 */
	function withdrawForRestaking(uint256 ethAmt)
		external
		nonReentrant
		wrstETHNotPaused
		onlyRole(RESTAKER_ROLE)
	{
		require(
			address(this).balance - claimReserveEthAmt >= ethAmt,
			"Vault: insufficient liquidity"
		);
		payable(msg.sender).sendValue(ethAmt);   // reverts on failure
	}

	/* ----------------------- Liquidity inflow -------------------------- */
	function depositFromRestaker() external payable onlyRole(RESTAKER_ROLE) {}
	
	/**
	 * @notice Accepts wETH deposits from the wrstETH contract.
	 *         Unwraps the received wETH into ETH for further restaking.
	 * @param wethAmt Amount of wETH to deposit (in Wei).
	 */
	function depositFromWrstETH(uint256 wethAmt)
		external
		nonReentrant
		onlyRole(WRSTETH_ROLE)
	{
		require(wethAmt > 0, "Vault: zero wethAmt");
		// Unwrap wETH into ETH. The resulting ETH will be managed by the vault.
		wETH.withdraw(wethAmt);
	}

	/* -------------- Oracle reserve / release management ---------------- */
	/**
	 * @notice Reserves ETH for queued withdrawals.
	 * @param ethAmt Amount of ETH to reserve (in Wei).
	 */
	function reserveForClaims(uint256 ethAmt)
		external onlyRole(ORACLE_ROLE)
	{ claimReserveEthAmt += ethAmt; }

	/**
	 * @dev Called by WithdrawalQueue when a user claims ready ETH.
	 * @param user The address of the user receiving the funds (ETH/wETH).
	 * @param ethAmt The amount of ETH to release (in Wei).
	 * @param wethAmt The amount of wETH to release (in Wei).
	 */
	function releaseClaim(
		address payable user,
		uint256 ethAmt,
		uint256 wethAmt
	)
		external
		nonReentrant
		wrstETHNotPaused
		onlyRole(QUEUE_ROLE)
	{
		// Effects: update state before external calls
		claimReserveEthAmt -= ethAmt + wethAmt;

		// Convert ETH to wETH if requested
		// Interactions: external calls after state changes
		if (wethAmt > 0) {
			wETH.deposit{value: wethAmt}();
			wETH.safeTransfer(user, wethAmt);
		}
		if (ethAmt > 0) user.sendValue(ethAmt); // reverts on failure
	}

	/* ------------------------ Role rotation (admin) -------------------- */
	/* ---------------------- Two-phase: ADMIN --------------------------- */
	function proposeAdmin(address newAdmin)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(newAdmin != address(0), "Vault: zero admin");
		pendingAdmin = newAdmin;
		emit AdminProposed(getRoleMember(DEFAULT_ADMIN_ROLE, 0), newAdmin);
	}
	
	function acceptAdmin() external {
		require(msg.sender == pendingAdmin, "Vault: not pending admin");
		address old = getRoleMember(DEFAULT_ADMIN_ROLE, 0);
	
		_grantRole(DEFAULT_ADMIN_ROLE, pendingAdmin);
		_revokeRole(DEFAULT_ADMIN_ROLE, old);
	
		emit AdminChanged(old, pendingAdmin);
		pendingAdmin = address(0);
	}
	
	/* --------------------- Two-phase: RESTAKER ------------------------- */
	function proposeRestaker(address newRestaker)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(newRestaker != address(0), "Vault: zero restaker");
		pendingRestaker = newRestaker;
		emit RestakerProposed(getRoleMember(RESTAKER_ROLE, 0), newRestaker);
	}
	
	function acceptRestaker() external {
		require(msg.sender == pendingRestaker, "Vault: not pending restaker");
		address old = getRoleMember(RESTAKER_ROLE, 0);
	
		_grantRole(RESTAKER_ROLE, pendingRestaker);
		_revokeRole(RESTAKER_ROLE, old);
	
		emit RestakerChanged(old, pendingRestaker);
		pendingRestaker = address(0);
	}

	/* -------------------- One-step rotations (Oracle / Queue) ---------- */
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

	/* --------------------- Receive plain ETH --------------------------- */
	/**
	 * @notice Accepts plain ETH transfers (required for wETH.withdraw()).
	 *         Leaving this function empty allows the contract to receive ETH from wETH and other contracts.
	 *         This is the recommended approach for vaults working with wETH.
	 */
	receive() external payable {}
}
