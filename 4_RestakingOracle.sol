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
	function process(uint256 availableWei, uint256 maxTickets) external;
}

/**
 * @title RestakingOracle
 * @notice Keeper that pushes new price data and releases free liquidity
 *         from the vault into the withdrawal queue.
 */
contract RestakingOracle is AccessControlEnumerableUpgradeable {
	bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

	/* ------------------------- External links ------------------------- */
	IWrstOracle  public wrstETHToken;
	IVaultOracle public vault;
	IQueueOracle public queue;

	/* ---------------------------- Events ------------------------------ */
	event KeeperChanged(address oldKeeper, address newKeeper);

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

	/* ----------------------- Admin: rotate keeper --------------------- */
	function setKeeper(address newKeeper)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		emit KeeperChanged(getRoleMember(KEEPER_ROLE, 0), newKeeper);
		_revokeRole(KEEPER_ROLE, getRoleMember(KEEPER_ROLE, 0));
		_grantRole(KEEPER_ROLE,  newKeeper);
	}

	/* ------------------------- Main keeper job ------------------------ */
	function pushReport(uint256 newRateWei, uint256 maxTickets)
		external
		onlyRole(KEEPER_ROLE)
	{
		/* ---------- Update price & reset daily mint counters ---------- */
		wrstETHToken.setRateWei(newRateWei);
		wrstETHToken.resetDailyCounters();

		/* ---------- Move excess liquidity to the queue --------------- */
		if (wrstETHToken.paused()) return;      // bunker mode

		uint256 free = address(vault).balance - vault.getClaimReserveWei();
		if (free > 0) queue.processEth(free, maxTickets);
	}
}
