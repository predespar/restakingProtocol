// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*─────────────── OpenZeppelin ───────────────*/
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/*─────────────── External interfaces ───────*/
interface IWrstO {
	function setRateWei(uint256) external;
	function resetDailyCounters() external;
	function paused() external view returns(bool);
}
interface IVaultO {
	function claimReserveWei() external view returns(uint256);
}
interface IQueueO {
	function process(uint256) external;
}

contract RestakingOracle is AccessControlUpgradeable {
	bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

	IWrstO  public wrst;
	IVaultO public vault;
	IQueueO public queue;

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
		wrst  = IWrstO(wrstAddr);
		vault = IVaultO(vaultAddr);
		queue = IQueueO(queueAddr);
	}

	function pushReport(uint256 newRateWei)
		external onlyRole(KEEPER_ROLE)
	{
		wrst.setRateWei(newRateWei);
		wrst.resetDailyCounters();                // resets 24h windows

		if(wrst.paused()) return; 
		uint256 free = address(vault).balance - vault.claimReserveWei();
		if(free>0) queue.process(free);
	}
}
