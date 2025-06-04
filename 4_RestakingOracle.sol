// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

interface IWrappedTokenOracle {
	function setRateWei(uint256) external;
	function resetDailyCounters() external;
	function paused() external view returns (bool);
}
interface IVaultOracle {
	function getClaimReserveWei() external view returns (uint256);
}
interface IQueueOracle {
	function process(uint256, uint256) external;
}

/**
 * @notice Keeper contract: updates price, resets daily limits and moves free liquidity.
 *         (ETH flavour)
 */
contract RestakingOracleETH is AccessControlUpgradeable {
	bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

	IWrappedTokenOracle public token;
	IVaultOracle       public vault;
	IQueueOracle       public queue;

	event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);

	function initialize(
		address admin,
		address keeper,
		address tokenAddr,
		address vaultAddr,
		address queueAddr
	) external initializer {
		__AccessControl_init();
		_grantRole(DEFAULT_ADMIN_ROLE, admin);
		_grantRole(KEEPER_ROLE,       keeper);

		token = IWrappedTokenOracle(tokenAddr);
		vault = IVaultOracle(vaultAddr);
		queue = IQueueOracle(queueAddr);
	}

	/* ───────── Admin → update keeper ───── */
	function setKeeper(address oldKeeper, address newKeeper)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		_revokeRole(KEEPER_ROLE, oldKeeper);
		_grantRole(KEEPER_ROLE,  newKeeper);
		emit KeeperUpdated(oldKeeper, newKeeper);
	}

	/* ───────── Off‑chain keeper triggers ───── */
	function pushReport(uint256 newRateWei, uint256 maxTickets)
		external onlyRole(KEEPER_ROLE)
	{
		// 1. push price + reset counters inside token
		token.setRateWei(newRateWei);
		token.resetDailyCounters();

		// 2. if token is paused — ничего не двигаем
		if (token.paused()) return;

		// 3. движём свободную ликвидность в очередь
		uint256 free = address(vault).balance - vault.getClaimReserveWei();
		if (free > 0) queue.process(free, maxTickets);
	}
}
