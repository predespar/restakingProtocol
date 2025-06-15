// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───────────────────────── OpenZeppelin upgradeable ───────────────────────── */
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

/* ──────────────────────────── External interfaces ─────────────────────────── */
interface IWrstToken {
	function paused() external view returns (bool);
	function totalSupply() external view returns (uint256);
	function getETHByWrstETH(uint256 wrstEthAmt) external view returns (uint256);
}

// --- WETH9 minimal interface ---
interface IWETH9 is IERC20Upgradeable {
	function deposit() external payable;
	function withdraw(uint256) external;
}

interface IWithdrawalQueue {
	function totalEthReleased() external view returns (uint256);
	function totalEthOrdered() external view returns (uint256);
}

/**
 * @title RestakeVault
 * @notice Restaking / un-restaking manager.
 */
contract RestakeVault is
	Ownable2StepUpgradeable,
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
	address public pendingRestaker;

	/* -------------------- External contract addresses ------------------ */
	IWrstToken public wrstETHToken;   ///< wrstETH proxy (for pause checks)
	IWETH9     public wETH; 
	IWithdrawalQueue public withdrawalQueue;

	/* --------------------------- State vars ---------------------------- */
	uint256 public claimReserveEthAmt;    // Reserved for queued withdrawals

	/// @notice Portion of wrstETH totalSupply (in %) to always keep in the vault for fast withdrawals
	uint256 public withdrawReserve; // e.g. 50 means 2% (1/50)

	/* ------------------------------ Events ----------------------------- */
	event AdminProposed(address oldAdmin, address newAdmin);
	event AdminChanged(address oldAdmin, address newAdmin);
	
	event RestakerProposed(address oldRestaker, address newRestaker);
	event RestakerChanged(address oldRestaker, address newRestaker);

	event OracleChanged(address oldOracle, address newOracle);
	event QueueChanged(address oldQueue, address newQueue);

	event InsufficientLiquidity(uint256 available, uint256 reserved, uint256 requested);
	event ClaimReleased(address user, uint256 ethAmt, uint256 wethAmt);

	/* ------------------------------ Initializer ------------------------ */
	function initialize(
		address admin,
		address restaker,
		address oracle,
		address queue,
		address wrstETHAddr,
		address wETHAddr
	) external initializer {
		__Ownable2Step_init();
		__AccessControlEnumerable_init();
		__ReentrancyGuard_init();

		_transferOwnership(admin);
		_grantRole(RESTAKER_ROLE, restaker);
		_grantRole(ORACLE_ROLE,   oracle);
		_grantRole(QUEUE_ROLE,    queue);
		_grantRole(WRSTETH_ROLE,  wrstETHAddr);

		wrstETHToken = IWrstToken(wrstETHAddr);
		wETH         = IWETH9(wETHAddr);
		withdrawalQueue = IWithdrawalQueue(queue);

		withdrawReserve = 50; // default: 2% of totalSupply
	}

	/* ------------------------- Modifiers ------------------------------- */
	modifier wrstETHNotPaused() {
		require(!wrstETHToken.paused(), "Vault: wrstETH paused");
		_;
	}

	/* ----------------------- Liquidity outflow ------------------------- */
	/**
	 * @notice Transfers all available surplus ETH to RESTAKER_ROLE for restaking.
	 *         Surplus = contract balance minus claimReserveEthAmt minus fast withdrawal reserve.
	 *         Fast withdrawal reserve = wrstETH.getETHByWrstETH(wrstETH.totalSupply() / withdrawReserve)
	 *         Reverts if no surplus is available.
	 */
	function withdrawForRestaking()
		external
		nonReentrant
		wrstETHNotPaused
		onlyRole(RESTAKER_ROLE)
	{
		uint256 fastReserve = 0;
		if (withdrawReserve > 0) {
			uint256 totalSupply = wrstETHToken.totalSupply();
			uint256 reserveShares = totalSupply / withdrawReserve;
			fastReserve = wrstETHToken.getETHByWrstETH(reserveShares);
		}
		uint256 minBalance = claimReserveEthAmt + fastReserve;
		uint256 surplus;
		unchecked {
			surplus = address(this).balance > minBalance
				? address(this).balance - minBalance
				: 0;
		}
		require(surplus > 0, "Vault: no surplus to withdraw");
		payable(msg.sender).sendValue(surplus);
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
		external
		nonReentrant
		onlyRole(WRSTETH_ROLE)
	{ claimReserveEthAmt += ethAmt; }

	/**
	 * @dev Called by WithdrawalQueue when a user claims ready ETH.
	 *      External calls (ETH/wETH transfer) are performed before state update intentionally:
	 *      both are atomic and will revert together if any fails, so reserve is only reduced on success.
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
		// Interactions: external calls before state changes (intentional ordering)
		if (wethAmt > 0) {
			// Convert ETH to wETH if requested
			wETH.deposit{value: wethAmt}();
			wETH.safeTransfer(user, wethAmt);
		}
		if (ethAmt > 0) user.sendValue(ethAmt); // reverts on failure

		// Effects: update state after external calls
		claimReserveEthAmt -= ethAmt + wethAmt;

		emit ClaimReleased(user, ethAmt, wethAmt);
	}
	
	/* --------------------- Two-phase: RESTAKER ------------------------- */
	function proposeRestaker(address newRestaker)
		external onlyOwner
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
	function setOracle(address newOracle) external onlyOwner {
		require(newOracle != address(0), "Vault: zero Oracle");
		address old = getRoleMember(ORACLE_ROLE, 0);
		_grantRole(ORACLE_ROLE, newOracle);
		_revokeRole(ORACLE_ROLE, old);
		emit OracleChanged(old, newOracle);
	}

	function setQueue(address newQueue) external onlyOwner {
		require(newQueue != address(0), "Vault: zero Queue");
		address old = getRoleMember(QUEUE_ROLE, 0);
		_grantRole(QUEUE_ROLE, newQueue);
		_revokeRole(QUEUE_ROLE, old);
		emit QueueChanged(old, newQueue);
	}

	/**
	 * @notice Sets the withdrawReserve parameter (portion of wrstETH totalSupply to keep in vault).
	 * @dev Only callable by owner.
	 * @param reserveDivisor New divisor (e.g. 50 means 2%).
	 */
	function setWithdrawReserve(uint256 reserveDivisor) external onlyOwner {
		require(reserveDivisor >= 1, "Vault: reserveDivisor must be >= 1");
		withdrawReserve = reserveDivisor;
	}

	/* --------------------- Receive plain ETH --------------------------- */
	/**
	 * @notice Accepts plain ETH transfers (required for wETH.withdraw()).
	 *         Leaving this function empty allows the contract to receive ETH from wETH and other contracts.
	 *         This is the recommended approach for vaults working with wETH.
	 */
	receive() external payable {}

	/**
	 * @notice Returns the current protocol balance (surplus or deficit) in ETH.
	 *         balance = WithdrawalQueue.totalEthReleased + address(this).balance - WithdrawalQueue.totalEthOrdered - claimReserveEthAmt
	 *         If balance > 0: surplus (can be restaked).
	 *         If balance < 0: deficit (should be withdrawn from restaking).
	 *         Invariant: released should never exceed ordered, but if it does, result may be incorrect.
	 * @return balanceWei Signed integer: positive = surplus, negative = deficit.
	 */
	function getProtocolBalance() external view returns (int256 balanceWei) {
		uint256 released = withdrawalQueue.totalEthReleased();
		uint256 ordered = withdrawalQueue.totalEthOrdered();
		uint256 onContract = address(this).balance;
		uint256 reserved = claimReserveEthAmt;

		// Defensive: released should not exceed ordered, but if it does, cap at ordered
		// Convert to int256 for correct sign handling
		if (released > ordered) {
			released = ordered;
		}

		balanceWei = int256(released) + int256(onContract) - int256(ordered) - int256(reserved);
		return balanceWei;
	}
}
