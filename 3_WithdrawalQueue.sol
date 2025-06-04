// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

interface IWrappedTokenQueue {
	function burnForWithdrawal(address, uint256) external returns (uint256);
	function paused() external view returns (bool);
	function isFrozen(address) external view returns (bool);
}
interface IVaultQueue {
	function releaseClaim(address payable, uint256) external;
}

/**
 * @dev FIFO queue for withdrawals: each request is represented by an NFT ticket.
 *      (ETH flavour — token symbol wrsETHNFT)
 */
contract WithdrawalQueueETH is ERC721Upgradeable, AccessControlUpgradeable {
	bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

	struct Ticket { uint256 want; uint256 ready; }

	IWrappedTokenQueue public token;   ///< wrstETH token proxy
	IVaultQueue        public vault;   ///< RestakeVault proxy

	uint256 public nextId;
	uint256 public head;
	mapping(uint256 => Ticket) public tickets;

	/* ───────── Init ─── */
	function initialize(
		address admin,
		address tokenAddr,
		address vaultAddr
	) external initializer {
		__ERC721_init("wrstETH Withdrawal Ticket", "wrsETHNFT");
		__AccessControl_init();
		_grantRole(DEFAULT_ADMIN_ROLE, admin);

		token = IWrappedTokenQueue(tokenAddr);
		vault = IVaultQueue(vaultAddr);
		nextId = 1;
	}

	/* ───────── User → request ─── */
	function requestWithdraw(uint256 wrstWei) external returns (uint256 id) {
		require(!token.paused(),             "Queue: paused");
		require(!token.isFrozen(msg.sender), "Queue: frozen");

		uint256 ethWei = token.burnForWithdrawal(msg.sender, wrstWei);
		id             = nextId++;
		tickets[id]    = Ticket(ethWei, 0);
		_mint(msg.sender, id);
	}

	/* ───────── User → claim ─── */
	function claim(uint256 id) external {
		require(!token.paused(), "Queue: paused");
		require(ownerOf(id) == msg.sender, "Queue: !owner");
		require(!token.isFrozen(msg.sender), "Queue: frozen");

		Ticket storage t = tickets[id];
		uint256 ready    = t.ready;
		require(ready > 0, "Queue: not ready");

		t.ready = 0;
		vault.releaseClaim(payable(msg.sender), ready);
		if (t.want == 0) _burn(id);
	}

	/* ───────── Oracle → distribute ─── */
	function process(uint256 availableWei, uint256 maxTickets)
		external onlyRole(ORACLE_ROLE)
	{
		uint256 free      = availableWei;
		uint256 processed = 0;

		while (free > 0 && head < nextId && processed < maxTickets) {
			Ticket storage t = tickets[++head];
			if (t.want == 0) { processed++; continue; }

			uint256 part = t.want;
			if (part > free) part = free;

			t.want  -= part;
			t.ready += part;
			free    -= part;
			processed++;
		}
	}
}
