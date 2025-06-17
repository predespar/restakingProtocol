// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───────────────────────── OpenZeppelin upgradeable ───────────────────────── */
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";

/* ──────────────────────────── External interfaces ─────────────────────────── */
interface IWrstETH {
	function setRate(uint256) external;
	function resetDailyCounters() external;
}

/**
 * @title RstEthOracle
 * @notice Keeper that pushes new price data for wrstETH.
 */
contract RstEthOracle is Ownable2StepUpgradeable, AccessControlEnumerableUpgradeable {
	bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

	/* ------------------------- Pending addresses ----------------------- */
	address public pendingKeeper;

	/* ------------------------- External links ------------------------- */
	IWrstETH  public wrstETH;

	/* ---------------------------- Events ------------------------------ */
	event KeeperProposed(address oldKeeper, address newKeeper);
	event KeeperChanged(address oldKeeper, address newKeeper);
	event NewWrstEthRatePushed(uint256 newWrstEthRate);

	/* ---------------------------- Initializer ------------------------- */
	/**
	 * @notice Initializes the RstEthOracle contract.
	 * @param owner_ Address to be set as contract owner.
	 * @param keeper Address to be granted KEEPER_ROLE.
	 * @param wrstEthAddr Address of the wrstETH token contract.
	 */
	function initialize(
		address owner_,
		address keeper,
		address wrstEthAddr
	) external initializer {
		__Ownable2Step_init();
		__AccessControlEnumerable_init();

		_transferOwnership(owner_);
		_grantRole(KEEPER_ROLE, keeper);

		wrstETH = IWrstETH(wrstEthAddr);
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
	 * @notice Updates the ETH-to-wrstETH conversion rate (ethRate).
	 * @param newWrstEthRate New ETH-to-wrstETH conversion rate.
	 */
	function pushReport(uint256 newWrstEthRate)
		external
		onlyRole(KEEPER_ROLE)
	{
		// Update price and reset daily mint counters
		wrstETH.setRate(newWrstEthRate);
		wrstETH.resetDailyCounters();

		emit NewWrstEthRatePushed(newWrstEthRate);
	}
}
