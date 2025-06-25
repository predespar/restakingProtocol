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
interface IWrstX {
	function paused() external view returns (bool);
	function totalSupply() external view returns (uint256);
	function previewWithdraw(uint256 shares) external view returns (uint256);
}

// --- WETH9 minimal interface ---
interface IWETH9 is IERC20Upgradeable {
	function deposit() external payable;
	function withdraw(uint256) external;
}

interface IEthQueue {
	function totalEthReleased() external view returns (uint256);
	function totalEthOrdered() external view returns (uint256);
}

/**
 * @title EthVault
 * @notice Restaking / un-restaking manager for ETH/wETH.
 */
contract EthVault is
	Ownable2StepUpgradeable,
	AccessControlEnumerableUpgradeable,
	ReentrancyGuardUpgradeable
{
	using AddressUpgradeable   for address payable;
	using SafeERC20Upgradeable for IERC20Upgradeable;

	/* ------------------------------ Roles ------------------------------ */
	bytes32 public constant RESTAKER_ROLE = keccak256("RESTAKER_ROLE");
	bytes32 public constant QUEUE_ROLE    = keccak256("QUEUE_ROLE");
	bytes32 public constant WRSTETH_ROLE   = keccak256("WRSTETH_ROLE");

	/* ------------------------- Pending addresses ----------------------- */
	address public pendingRestaker;

	/* -------------------- External contract addresses ------------------ */
	IWrstX public wrstETH;   ///< wrstETH proxy (for pause checks)
	IWETH9     public wETH; 
	IEthQueue public ethQueue;

	/* --------------------------- State vars ---------------------------- */
	uint256 public claimReserveEthAmt;    // Reserved for queued withdrawals

	/// @notice Portion of wrstETH totalSupply (in %) to always keep in the vault for fast withdrawals
	uint16 public withdrawReserve; // e.g. 50 means 2% (1/50)
	uint256 public lastWithdrawReserveUpdate;

	/* ------------------------------ Events ----------------------------- */
	event EthRestakerProposed(address oldRestaker, address newRestaker);
	event EthRestakerChanged(address oldRestaker, address newRestaker);

	event EthQueueChanged(address oldQueue, address newQueue);
	event WrstETHChanged(address oldWrstETH, address newWrstETH);
	event EthWithdrawReserveChanged(uint16 oldReserve, uint16 newReserve);

	event EthClaimReleased(address user, uint256 ethAmt, uint256 wethAmt, bool instant);

	/**
	 * @notice Emitted when the ETH vault balance changes.
	 * @param newBalance The current ETH vault balance (see ethVaultBalance()).
	 */
	event EthVaultBalance(int256 newBalance);

	/* ------------------------------ Initializer ------------------------ */
	function initialize(
		address admin,
		address restaker,
		address queue,
		address wrstETHAddr,
		address wETHAddr
	) external initializer {
		__Ownable2Step_init();
		__AccessControlEnumerable_init();
		__ReentrancyGuard_init();

		_transferOwnership(admin);
		_grantRole(RESTAKER_ROLE, restaker);
		_grantRole(QUEUE_ROLE,    queue);
		_grantRole(WRSTETH_ROLE,  wrstETHAddr);

		wrstETH = IWrstX(wrstETHAddr);
		wETH         = IWETH9(wETHAddr);
		ethQueue = IEthQueue(queue);

		withdrawReserve = 50; // default: 2% of totalSupply
	}

	/* ------------------------- Modifiers ------------------------------- */
	modifier wrstETHNotPaused() {
		require(!wrstETH.paused(), "Vault: wrstETH paused");
		_;
	}

	/* ----------------------- Liquidity outflow ------------------------- */
	/**
	 * @notice Transfers all available surplus ETH to RESTAKER_ROLE for restaking.
	 *         Surplus = contract balance minus claimReserveEthAmt minus fast withdrawal reserve.
	 *         Fast withdrawal reserve = wrstETH.previewWithdraw(wrstETH.totalSupply() / withdrawReserve)
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
			uint256 totalSupply = wrstETH.totalSupply();
			uint256 reserveShares = totalSupply / withdrawReserve;
			fastReserve = wrstETH.previewWithdraw(reserveShares);
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
		emit EthVaultBalance(ethVaultBalance());
	}

	/* ----------------------- Liquidity inflow -------------------------- */
	function depositFromRestaker() external payable onlyRole(RESTAKER_ROLE) {
		// Advance the withdrawal queue if there is free liquidity
		if (address(this).balance > claimReserveEthAmt) {
			ethQueue.ethQueueUpdate();
		}
		emit EthVaultBalance(ethVaultBalance());
	}
	
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
		// Advance the withdrawal queue if there is free liquidity
		if (address(this).balance > claimReserveEthAmt) {
			ethQueue.ethQueueUpdate();
		}
		emit EthVaultBalance(ethVaultBalance());
	}

	/**
	 * @notice Reserves ETH for queued withdrawals. Сalled by WrstETH.
	 * @param ethAmt Amount of ETH to reserve (in Wei).
	 */
	function reserveForClaims(uint256 ethAmt)
		external
		nonReentrant
		onlyRole(WRSTETH_ROLE)
	{
		claimReserveEthAmt += ethAmt;
		emit EthVaultBalance(ethVaultBalance());
	}

	/**
	 * @dev Called by WithdrawalQueue when a user claims ready ETH.
	 *      External calls (ETH/wETH transfer) are performed before state update intentionally:
	 *      both are atomic and will revert together if any fails, so reserve is only reduced on success.
	 * @param user The address of the user receiving the funds (ETH/wETH).
	 * @param ethAmt The amount of ETH to release (in Wei).
	 * @param wethAmt The amount of wETH to release (in Wei).
	 * @param instant True if claim was satisfied instantly (no NFT minted), false if from queue.
	 */
	function releaseClaim(
		address payable user,
		uint256 ethAmt,
		uint256 wethAmt,
		bool instant
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

		emit EthClaimReleased(user, ethAmt, wethAmt, instant);
		emit EthVaultBalance(ethVaultBalance());
	}
	
	/* --------------------- Two-phase: RESTAKER ------------------------- */
	function proposeRestaker(address newRestaker)
		external onlyOwner
	{
		require(newRestaker != address(0), "Vault: zero restaker");
		pendingRestaker = newRestaker;
		emit EthRestakerProposed(getRoleMember(RESTAKER_ROLE, 0), newRestaker);
	}
	
	function acceptRestaker() external {
		require(msg.sender == pendingRestaker, "Vault: not pending restaker");
		address old = getRoleMember(RESTAKER_ROLE, 0);
	
		_grantRole(RESTAKER_ROLE, pendingRestaker);
		_revokeRole(RESTAKER_ROLE, old);
	
		emit EthRestakerChanged(old, pendingRestaker);
		pendingRestaker = address(0);
	}

	/* -------------------- One-step rotations (Queue, wrstETH) ---------- */
	function setQueue(address newQueue) external onlyOwner {
		require(newQueue != address(0), "Vault: zero Queue");
		address old = getRoleMember(QUEUE_ROLE, 0);
		_grantRole(QUEUE_ROLE, newQueue);
		_revokeRole(QUEUE_ROLE, old);
		emit EthQueueChanged(old, newQueue);
	}

	function setWrstETH(address newWrstETH) external onlyOwner {
		require(newWrstETH != address(0), "Vault: zero wrstETH");
		address old = getRoleMember(WRSTETH_ROLE, 0);
		_grantRole(WRSTETH_ROLE, newWrstETH);
		_revokeRole(WRSTETH_ROLE, old);
		wrstETH = IWrstX(newWrstETH);
		emit WrstETHChanged(old, newWrstETH);
	}

	/**
	 * @notice Sets the withdrawReserve parameter (portion of wrstETH totalSupply to keep in vault).
	 *         Can only be called by owner and not more than once per 24 hours.
	 * @dev Only callable by owner.
	 * @param reserveDivisor New divisor (e.g. 50 means 2%).
	 */
	function setWithdrawReserve(uint256 reserveDivisor) external onlyOwner {
		require(block.timestamp >= lastWithdrawReserveUpdate + 24 hours, "Vault: update too soon");
		require(reserveDivisor >= 1 && reserveDivisor <= 10000, "Vault: reserveDivisor must be 1..10000");
		uint16 oldReserve = withdrawReserve;
		withdrawReserve = uint16(reserveDivisor);
		lastWithdrawReserveUpdate = block.timestamp;
		emit EthWithdrawReserveChanged(oldReserve, withdrawReserve);
	}

	/* --------------------- Receive plain ETH --------------------------- */
	/**
	 * @notice Accepts plain ETH transfers (required for wETH.withdraw()).
	 *         Leaving this function empty allows the contract to receive ETH from wETH and other contracts.
	 *         This is the recommended approach for vaults working with wETH.
	 */
	receive() external payable {}

	/**
	 * @notice Returns the current ETH vault balance (surplus or deficit) in ETH.
	 *         balance = WithdrawalEthQueue.totalEthReleased + address(this).balance
	 *                  - WithdrawalEthQueue.totalEthOrdered - claimReserveEthAmt
	 *                  - fast withdrawal reserve
	 *         If balance > 0: surplus (can be restaked).
	 *         If balance < 0: deficit (should be withdrawn from restaking).
	 *         Invariant: released should never exceed ordered, but if it does, result may be incorrect.
	 * @return balanceWei Signed integer: positive = surplus, negative = deficit.
	 */
	function ethVaultBalance() public view returns (int256) {
		uint256 released = ethQueue.totalEthReleased();
		uint256 ordered = ethQueue.totalEthOrdered();
		uint256 onContract = address(this).balance;
		uint256 reserved = claimReserveEthAmt;

		// Calculate fast withdrawal reserve
		uint256 fastReserve = 0;
		if (withdrawReserve > 0) {
			uint256 totalSupply = wrstETH.totalSupply();
			uint256 reserveShares = totalSupply / withdrawReserve;
			fastReserve = wrstETH.previewWithdraw(reserveShares);
		}

		// Defensive: released should not exceed ordered, but if it does, cap at ordered
		if (released > ordered) {
			released = ordered;
		}

		int256 balanceWei = int256(released)
			+ int256(onContract)
			- int256(ordered)
			- int256(reserved)
			- int256(fastReserve);
		return balanceWei;
	}
}
