// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───────────────────────── OpenZeppelin upgradeable ───────────────────────── */
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";

/* ──────────────────────────── External interfaces ─────────────────────────── */
interface IWrstOracle {
	function setRateWei(uint256) external;
	function resetDailyCounters() external;
	function paused() external view returns (bool);
}
interface IVaultOracle {
	function getClaimReserveWei() external view returns (uint256);
}
interface IQueueOracle {
	function process(uint256 availableWei) external;
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

	/* ---------------------------- Events ------------------------------ */
	event AdminProposed(  address indexed oldAdmin,   address indexed newAdmin);
	event AdminChanged(   address indexed oldAdmin,   address indexed newAdmin);
	
	event KeeperProposed( address indexed oldKeeper,  address indexed newKeeper);
	event KeeperChanged(  address indexed oldKeeper,  address indexed newKeeper);

	/* ---------------------------- Initializer ------------------------- */
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
	function pushReport(uint256 newRateWei)
		external
		onlyRole(KEEPER_ROLE)
	{
		/* ---------- Update price & reset daily mint counters ---------- */
		wrstETHToken.setRateWei(newRateWei);
		wrstETHToken.resetDailyCounters();

		/* ---------- Move excess liquidity to the queue --------------- */
		if (wrstETHToken.paused()) return;      // bunker mode

		uint256 free = address(vault).balance - vault.getClaimReserveWei();
		if (free > 0) queue.processEth(free);
	}
}
