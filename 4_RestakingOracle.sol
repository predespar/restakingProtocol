// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*─────────────── OpenZeppelin ───────────────*/
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/*─────────────── External interfaces ───────*/
interface IWrstOracle {
    function setRateWei(uint256) external;
    function resetDailyCounters() external;
    function paused() external view returns (bool);
}
interface IVaultOracle {
    function claimReserve() external view returns (uint256);
}
interface IQueueOracle {
    function process(uint256) external;
}

/**
 * @title  RestakingOracle
 * @notice Keeper pushes new rate and distributes free ETH to queue
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

    /**
     * @param newRateWei ETH per wrst (18 decimals)
     */
    function pushReport(uint256 newRateWei) external onlyRole(KEEPER_ROLE) {
        // 1️⃣ update price
        wrst.setRateWei(newRateWei);

        // 2️⃣ reset mint/burn counters (once per 24 h)
        wrst.resetDailyCounters();

        // 3️⃣ distribute free liquidity unless token paused
        if (wrst.paused()) return;

        uint256 free = address(vault).balance - vault.claimReserve();
        if (free > 0) queue.process(free);
    }
}
