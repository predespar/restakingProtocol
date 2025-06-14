// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───────────────────────── OpenZeppelin upgradeable ───────────────────────── */
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";

/* ──────────────────────────── External interfaces ─────────────────────────── */
interface IWrstOracle {
	function setRate(uint256) external;
	function resetDailyCounters() external;
	function paused() external view returns (bool);
}
interface IVaultOracle {
	function claimReserveEthAmt() external view returns (uint256);
}
interface IQueueOracle {
	function processEth(uint256 availableWei) external;
}

/**
 * @title RestakingOracle
 * @notice Keeper that pushes new price data and releases free liquidity
 *         from the vault into the withdrawal queue.
 */
contract RestakingOracle is AccessControlEnumerableUpgradeable {
	bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

	/* ------------------------- Pending addresses ----------------------- */
	address public pendingAdmin;
	address public pendingKeeper;

	/* ------------------------- External links ------------------------- */
	IWrstOracle  public wrstETHToken;
	IVaultOracle public vault;
	IQueueOracle public queue;

	/// @notice Minimum free ETH threshold (in wei) required to trigger a queue transfer.
	uint256 public minFreeEthToQueue;

	/* ---------------------------- Events ------------------------------ */
	event AdminProposed(address oldAdmin, address newAdmin);
	event AdminChanged(address oldAdmin, address newAdmin);
	
	event KeeperProposed(address oldKeeper, address newKeeper);
	event KeeperChanged(address oldKeeper, address newKeeper);

	event NewRatePushed(uint256 newRate, uint256 freeToQueue);

	/* ---------------------------- Initializer ------------------------- */
	/**
	 * @notice Initializes the RestakingOracle contract.
	 * @param admin Address to be granted DEFAULT_ADMIN_ROLE.
	 * @param keeper Address to be granted KEEPER_ROLE.
	 * @param wrstETHaddr Address of the wrstETH token contract.
	 * @param vaultAddr Address of the vault contract.
	 * @param queueAddr Address of the withdrawal queue contract.
	 */
	function initialize(
		address admin,
		address keeper,
		address wrstETHaddr,
		address vaultAddr,
		address queueAddr
	) external initializer {
		__AccessControlEnumerable_init();
		_grantRole(DEFAULT_ADMIN_ROLE, admin);
		_grantRole(KEEPER_ROLE,       keeper);

		wrstETHToken = IWrstOracle(wrstETHaddr);
		vault        = IVaultOracle(vaultAddr);
		queue        = IQueueOracle(queueAddr);

		minFreeEthToQueue = 32 ether; // Default threshold is 32 ETH
	}

	/**
	 * @notice Sets the minimum free ETH threshold for queue transfers.
	 * @dev Only callable by an account with DEFAULT_ADMIN_ROLE.
	 * @param minWei The new minimum threshold in wei.
	 */
	function setMinFreeEthToQueue(uint256 minWei) external onlyRole(DEFAULT_ADMIN_ROLE) {
		minFreeEthToQueue = minWei;
	}

	/* ------------------------ Role rotation (admin) -------------------- */
	/* ----------------------- Two-phase: ADMIN ------------------------- */
	function proposeAdmin(address newAdmin)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(newAdmin != address(0), "Oracle: zero admin");
		pendingAdmin = newAdmin;
		emit AdminProposed(getRoleMember(DEFAULT_ADMIN_ROLE, 0), newAdmin);
	}
	
	function acceptAdmin() external {
		require(msg.sender == pendingAdmin, "Oracle: not pending admin");
		address old = getRoleMember(DEFAULT_ADMIN_ROLE, 0);
	
		_grantRole(DEFAULT_ADMIN_ROLE, pendingAdmin);
		_revokeRole(DEFAULT_ADMIN_ROLE, old);
	
		emit AdminChanged(old, pendingAdmin);
		pendingAdmin = address(0);
	}
	
	/* ----------------------- Two-phase: KEEPER ------------------------ */
	function proposeKeeper(address newKeeper)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(newKeeper != address(0), "Oracle: zero keeper");
		pendingKeeper = newKeeper;
		emit KeeperProposed(getRoleMember(KEEPER_ROLE, 0), newKeeper);
	}
	
	function acceptKeeper() external {
		require(msg.sender == pendingKeeper, "Oracle: not pending keeper");
		address old = getRoleMember(KEEPER_ROLE, 0);
	
		_grantRole(KEEPER_ROLE, pendingKeeper);
		_revokeRole(KEEPER_ROLE, old);
	
		emit KeeperChanged(old, pendingKeeper);
		pendingKeeper = address(0);
	}

	/* ------------------------- Main keeper job ------------------------ */
	/**
	 * @notice Updates the ETH-to-wrstETH conversion rate (ethRate) and releases excess liquidity.
	 * @param newRate New ETH-to-wrstETH conversion rate.
	 */
	function pushReport(uint256 newRate)
		external
		onlyRole(KEEPER_ROLE)
	{
		// Update price and reset daily mint counters
		wrstETHToken.setRate(newRate);
		wrstETHToken.resetDailyCounters();

		// Move excess liquidity to the withdrawal queue if above threshold
		if (wrstETHToken.paused()) return;

		uint256 free = address(vault).balance - vault.claimReserveEthAmt();
		if (free >= minFreeEthToQueue) {
			queue.processEth(free);
		}

		emit NewRatePushed(newRate, free);
	}
}
