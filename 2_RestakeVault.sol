// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*─────────────── OpenZeppelin ───────────────*/
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/*─────────────── External interfaces ───────*/
interface IWrstToken {
    function paused() external view returns (bool);
}

/*─────────────── RestakeVault ───────*/
contract RestakeVault is AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    /*---------------- Roles ----------------*/
    bytes32 public constant SPENDER_ROLE = keccak256("SPENDER_ROLE");
    bytes32 public constant ORACLE_ROLE  = keccak256("ORACLE_ROLE");

    /*---------------- Storage --------------*/
    IWrstToken public wrst;          ///< token contract to query pause status
    uint256    public claimReserve;  ///< ETH reserved for users (FIFO queue)

    /*--------------- Initialiser -----------*/
    function initialize(
        address admin,
        address spender,
        address oracle,
        address wrstAddr
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SPENDER_ROLE,       spender);
        _grantRole(ORACLE_ROLE,        oracle);

        wrst = IWrstToken(wrstAddr);
    }

    modifier notPausedToken() {
        require(!wrst.paused(), "RestakeVault: wrst paused");
        _;
    }

    /*--------------- withdraw ----------------*/
    function withdrawToRestaker(address payable to, uint256 amount)
        external
        notPausedToken
        onlyRole(SPENDER_ROLE)
    {
        require(
            address(this).balance - claimReserve >= amount,
            "RestakeVault: insufficient free liquidity"
        );
        (bool sent, ) = to.call{value: amount}("");
        require(sent, "RestakeVault: transfer fail");
    }

    /*--------------- Inbound: hedging return -----------*/
    function returnFromRestaker() external payable onlyRole(SPENDER_ROLE) {}

    /*--------------- Oracle reserve / release ----------*/
    function reserveForClaims(uint256 ethWei)
        external
        onlyRole(ORACLE_ROLE)
    {
        claimReserve += ethWei;
    }

    /**
     * @dev Sends ETH to user when his ticket is finalized.
     */
    function releaseClaim(address payable to, uint256 ethWei)
        external
        notPausedToken
        onlyRole(ORACLE_ROLE)
    {
        claimReserve -= ethWei;
        (bool ok, ) = to.call{value: ethWei}("");
        require(ok, "RestakeVault: release fail");
    }

    receive() external payable {}
}
