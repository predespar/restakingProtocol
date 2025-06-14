// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title TransparentProxy
 * @notice TransparentUpgradeableProxy with an additional deployment event for auditability.
 * @dev All logic for upgrading implementation and admin is delegated to ProxyAdmin.
 *      This contract does not expose any upgrade or admin functions itself.
 *      Use ProxyAdmin as the admin for all such proxies in the protocol.
 *      See OpenZeppelin's TransparentUpgradeableProxy for details.
 */
contract TransparentProxy is TransparentUpgradeableProxy {
    /**
     * @dev Emitted when the proxy is deployed.
     * @param admin The address of the proxy admin.
     * @param implementation The address of the implementation contract.
     * @param initData The initialization calldata.
     */
    event ProxyDeployed(
        address indexed admin,
        address indexed implementation,
        bytes initData
    );

    /**
     * @dev Initializes the proxy with an implementation, admin, and optional initialization calldata.
     * Emits a {ProxyDeployed} event.
     * @param _logic The address of the initial implementation.
     * @param _admin The address of the proxy admin.
     * @param _data Optional initialization calldata.
     */
    constructor(
        address _logic,
        address _admin,
        bytes memory _data
    ) TransparentUpgradeableProxy(_logic, _admin, _data) {
        emit ProxyDeployed(_admin, _logic, _data);
    }
}
