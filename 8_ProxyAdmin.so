// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title TwoStepProxyAdmin
 * @notice ProxyAdmin with two-step ownership transfer (Ownable2Step).
 *         All proxy upgrade and admin management functions are inherited from OpenZeppelin ProxyAdmin.
 * @dev Prevents renouncing ownership to ensure there is always a live admin.
 */
contract TwoStepProxyAdmin is ProxyAdmin, Ownable2Step {
    function renounceOwnership() public override onlyOwner {
        revert("TwoStepProxyAdmin: cannot renounce");
    }
}
