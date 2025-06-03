// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*─────────────── OpenZeppelin ───────────────*/
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/*─────────────── External interfaces ───────*/
interface IWrstQueue {
    function burnForWithdrawal(address, uint256) external returns (uint256);
    function paused() external view returns (bool);
}
interface IVaultQueue {
    function releaseClaim(address payable, uint256) external;
}

/**
 * @title  WithdrawalQueue
 * @notice FIFO queue implemented as ERC-721 tickets; supports partial fills.
 */
contract WithdrawalQueue is ERC721Upgradeable, AccessControlUpgradeable {
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    struct Request {
        uint128 want;   ///< remaining ETH owed
        uint128 ready;  ///< ETH already reserved
    }

    IWrstQueue public wrst;
    IVaultQueue public vault;

    uint256 public nextId;
    uint256 public head;            ///< last processed index
    mapping(uint256 => Request) public requests;

    /*---------------- Initializer ----------------*/
    function initialize(
        address admin,
        address token,
        address vaultAddr
    ) external initializer {
        __ERC721_init("wrstETH Withdrawal Ticket", "wrsNFT");
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        wrst  = IWrstQueue(token);
        vault = IVaultQueue(vaultAddr);
        nextId = 1;
    }

    /*---------------- User actions ---------------*/
    function requestWithdraw(uint256 wrstWei) external returns (uint256 id) {
        require(!wrst.paused(), "Queue: token paused");

        uint256 ethWei = wrst.burnForWithdrawal(msg.sender, wrstWei);
        id = nextId++;

        requests[id] = Request(uint128(ethWei), 0);
        _mint(msg.sender, id);
    }

    function claim(uint256 id) external {
        require(!wrst.paused(), "Queue: token paused");
        require(ownerOf(id) == msg.sender, "Queue: not owner");

        Request storage r = requests[id];
        uint256 ready = r.ready;
        require(ready > 0, "Queue: not ready");

        r.ready = 0;
        vault.releaseClaim(payable(msg.sender), ready);

        if (r.want == 0) _burn(id);  // ticket fully satisfied
    }

    /*---------------- Oracle action ---------------*/
    function process(uint256 availableWei)
        external
        onlyRole(ORACLE_ROLE)
    {
        uint256 remaining = availableWei;

        while (remaining > 0 && head < nextId) {
            Request storage r = requests[++head];
            if (r.want == 0) continue;

            uint256 portion = r.want;
            if (portion > remaining) portion = remaining;

            r.want  -= uint128(portion);
            r.ready += uint128(portion);
            remaining -= portion;
        }
        /* any leftover ETH stays in vault as free liquidity */
    }
}
