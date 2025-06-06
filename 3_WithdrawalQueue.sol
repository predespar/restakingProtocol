// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───────────────────────── OpenZeppelin upgradeable ───────────────────────── */
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";

/* ──────────────────────────── External interfaces ─────────────────────────── */
interface IWrappedTokenQueue {
	function burnForWithdrawal(address, uint256) external returns (uint256);
	function paused() external view returns (bool);
	function isFrozen(address) external view returns (bool);
}
interface IVaultQueue {
	function releaseClaim(address payable, uint256) external;
}

/**
 * @title WithdrawalQueue
 * @notice Each withdrawal request is represented by an ERC-721 NFT ticket (FIFO).
 *         Built for wrstETH; other assets can reuse the same pattern later.
 */
contract WithdrawalQueue is
	ERC721Upgradeable,
	AccessControlEnumerableUpgradeable
{
	/* ------------------------------ Roles ------------------------------ */
	bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

	/* ------------------------- Pending admin --------------------------- */
	address public pendingAdmin;

	/* ------------------------- External links ------------------------- */
	IWrappedTokenQueue public wrstETHToken;
	IVaultQueue        public vault;

	/* ----------------------- ETH-specific state ----------------------- */
	/// @dev id → order size in wei. id is cumulative sum at creation.
	mapping(uint256 => uint256) public ethOrders;

	uint256 public totalEthOrdered;            // wei requested
	uint256 public totalEthReleased;           // wei released by oracle

	uint256 public totalEthOrders;             // count of ETH orders
	uint256 public totalReleasedEthOrders;     // count already claimable
	
	/* ------------------------------ Events ----------------------------- */
	event AdminProposed(address indexed oldAdmin, address indexed newAdmin);
	event AdminChanged( address indexed oldAdmin, address indexed newAdmin);
	event OracleChanged(address indexed oldOracle, address indexed newOracle);

	/* ---------------------------- Initializer ------------------------- */
	function initialize(
		address admin,
		address oracle,
		address wrstETHtokenAddr,
		address vaultAddr
	) external initializer {
		__ERC721_init("wrstETH Withdrawal Ticket", "wrsETHNFT");
		__AccessControlEnumerable_init();

		_grantRole(DEFAULT_ADMIN_ROLE, admin);
		_grantRole(ORACLE_ROLE,       oracle);

		wrstETHToken = IWrappedTokenQueue(wrstETHtokenAddr);
		vault        = IVaultQueue(vaultAddr);
	}

	/* ------------------------ User: request ETH ----------------------- */
	function requestWithdrawEth(uint256 wrstETHWei)
		external returns (uint256 id)
	{
		require(!wrstETHToken.paused(),               "Queue: paused");
		require(!wrstETHToken.isFrozen(msg.sender),   "Queue: frozen");

		uint256 ethWei = wrstETHToken.burnForWithdrawal(msg.sender, wrstETHWei);

		// cumulative counters (ETH)
		totalEthOrdered += ethWei;
		unchecked { ++totalEthOrders; }

		id              = totalEthOrdered;        // unique, increasing
		ethOrders[id]   = ethWei;

		_mint(msg.sender, id);
	}

	/* ------------------------- User: claim ETH ------------------------ */
	function claimEth(uint256 id) external {
		require(!wrstETHToken.paused(),               "Queue: paused");
		require(ownerOf(id) == msg.sender,            "Queue: !owner");
		require(!wrstETHToken.isFrozen(msg.sender),   "Queue: frozen");
		require(id <= totalEthReleased,              "Queue: not ready");

		uint256 amt = ethOrders[id];
		require(amt > 0, "Queue: already claimed");

		delete ethOrders[id];
		unchecked { ++totalReleasedEthOrders; }

		_burn(id);
		vault.releaseClaim(payable(msg.sender), amt);
	}

	/* ---------------- Oracle: release ETH liquidity ------------------- */
	/**
	 * @param availableWei Free ETH sent by oracle from the vault
	 */
	function processEth(uint256 availableWei)
		external onlyRole(ORACLE_ROLE)
	{
		totalEthReleased += availableWei;
	}
	
	/* --------------------- Two-phase admin rotation ------------------- */
	function proposeAdmin(address newAdmin)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(newAdmin != address(0), "Queue: zero admin");
		pendingAdmin = newAdmin;
		emit AdminProposed(getRoleMember(DEFAULT_ADMIN_ROLE, 0), newAdmin);
	}

	function acceptAdmin() external {
		require(msg.sender == pendingAdmin, "Queue: not pending admin");
		address old = getRoleMember(DEFAULT_ADMIN_ROLE, 0);

		_grantRole(DEFAULT_ADMIN_ROLE, pendingAdmin);
		_revokeRole(DEFAULT_ADMIN_ROLE, old);

		emit AdminChanged(old, pendingAdmin);
		pendingAdmin = address(0);
	}

	/* ---------------------- One-step oracle rotation ------------------ */
	function setOracle(address newOracle)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(newOracle != address(0), "Queue: zero oracle");
		address old = getRoleMember(ORACLE_ROLE, 0);

		_grantRole(ORACLE_ROLE, newOracle);
		_revokeRole(ORACLE_ROLE, old);

		emit OracleChanged(old, newOracle);
	}
}
