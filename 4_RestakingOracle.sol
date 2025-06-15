// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───────────────────────── OpenZeppelin upgradeable ───────────────────────── */
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
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
contract RestakingOracle is Ownable2StepUpgradeable, AccessControlEnumerableUpgradeable {
	bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

	/* ------------------------- Pending addresses ----------------------- */
	address public pendingKeeper;

	/* ------------------------- External links ------------------------- */
	IWrstOracle  public wrstETHToken;
	IVaultOracle public vault;
	IQueueOracle public queue;

	/* ---------------------------- Events ------------------------------ */
	event KeeperProposed(address oldKeeper, address newKeeper);
	event KeeperChanged(address oldKeeper, address newKeeper);
	event NewRatePushed(uint256 newRate, uint256 freeToQueue);

	/* ---------------------------- Initializer ------------------------- */
	/**
	 * @notice Initializes the RestakingOracle contract.
	 * @param owner_ Address to be set as contract owner.
	 * @param keeper Address to be granted KEEPER_ROLE.
	 * @param wrstETHaddr Address of the wrstETH token contract.
	 * @param vaultAddr Address of the vault contract.
	 * @param queueAddr Address of the withdrawal queue contract.
	 */
	function initialize(
		address owner_,
		address keeper,
		address wrstETHaddr,
		address vaultAddr,
		address queueAddr
	) external initializer {
		__Ownable2Step_init();
		__AccessControlEnumerable_init();

		_transferOwnership(owner_);
		_grantRole(KEEPER_ROLE, keeper);

		wrstETHToken = IWrstOracle(wrstETHaddr);
		vault        = IVaultOracle(vaultAddr);
		queue        = IQueueOracle(queueAddr);
	}

	/* ----------------------- Two-phase: KEEPER ------------------------ */
	function proposeKeeper(address newKeeper)
		external onlyOwner
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

		// Move all excess liquidity to the withdrawal queue
		if (wrstETHToken.paused()) return;

		uint256 free = address(vault).balance - vault.claimReserveEthAmt();
		if (free > 0) {
			queue.processEth(free);
		}

		emit NewRatePushed(newRate, free);
	}
}
