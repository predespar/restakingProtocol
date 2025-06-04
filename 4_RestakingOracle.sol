// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

interface IWrstOracle {
	function setRateWei(uint256) external;
	function resetDailyCounters() external;
	function paused() external view returns(bool);
}
interface IVaultOracle {
	function claimReserveWei() external view returns(uint256);
}
interface IQueueOracle {
	function process(uint256) external;
}

/**
 * @notice Keeper contract: pushes new price and moves free liquidity.
 */
contract RestakingOracle is AccessControlUpgradeable {
	bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

	IWrstOracle  public wrst;
	IVaultOracle public vault;
	IQueueOracle public queue;

	function initialize(
		address admin,
		address keeper,
		address wrstAddr,
		address vaultAddr,
		address queueAddr
	) external initializer {
		__AccessControl_init();
		_grantRole(DEFAULT_ADMIN_ROLE, admin);
		_grantRole(KEEPER_ROLE,       keeper);
		wrst  = IWrstOracle(wrstAddr);
		vault = IVaultOracle(vaultAddr);
		queue = IQueueOracle(queueAddr);
	}

	function pushReport(uint256 newRateWei)
		external onlyRole(KEEPER_ROLE)
	{
		wrst.setRateWei(newRateWei);
		wrst.resetDailyCounters();

		if (wrst.paused()) return;               // bunker-mode
		uint256 free = address(vault).balance - vault.claimReserveWei();
		if (free > 0) queue.process(free);
	}
}
