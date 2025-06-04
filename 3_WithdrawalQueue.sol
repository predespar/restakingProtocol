// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

interface IWrstQueue {
	function burnForWithdrawal(address,uint256) external returns(uint256);
	function paused() external view returns(bool);
	function isFrozen(address) external view returns(bool);
}
interface IVaultQueue {
	function releaseClaim(address payable,uint256) external;
}

/**
 * @dev FIFO queue: each request is an NFT.
 */
contract WithdrawalQueue is ERC721Upgradeable, AccessControlUpgradeable {
	bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

	struct Ticket { uint128 want; uint128 ready; }

	IWrstQueue  public wrst;
	IVaultQueue public vault;

	uint256 public nextId;
	uint256 public head;
	mapping(uint256 => Ticket) public tickets;

	/*──────── Init ─ */
	function initialize(
		address admin, address wrstAddr, address vaultAddr
	) external initializer {
		__ERC721_init("wrstETH Withdrawal Ticket","wrsNFT");
		__AccessControl_init();
		_grantRole(DEFAULT_ADMIN_ROLE, admin);

		wrst  = IWrstQueue(wrstAddr);
		vault = IVaultQueue(vaultAddr);
		nextId = 1;
	}

	/*──────── User → request ─ */
	function requestWithdraw(uint256 wrstWei) external returns(uint256 id) {
		require(!wrst.paused(),             "Queue: paused");
		require(!wrst.isFrozen(msg.sender), "Queue: frozen");

		uint256 ethWei = wrst.burnForWithdrawal(msg.sender, wrstWei);
		id = nextId++;
		tickets[id] = Ticket(uint128(ethWei),0);
		_mint(msg.sender, id);
	}

	/*──────── User → claim ─ */
	function claim(uint256 id) external {
		require(!wrst.paused(), "Queue: paused");
		require(ownerOf(id) == msg.sender, "Queue: !owner");
		require(!wrst.isFrozen(msg.sender),"Queue: frozen");

		Ticket storage t = tickets[id];
		uint256 ready = t.ready;
		require(ready > 0, "Queue: not ready");

		t.ready = 0;
		vault.releaseClaim(payable(msg.sender), ready);
		if (t.want == 0) _burn(id);
	}

	/*──────── Oracle → distribute ─ */
	function process(uint256 availableWei) external onlyRole(ORACLE_ROLE) {
		uint256 free = availableWei;
		while (free > 0 && head < nextId) {
			Ticket storage t = tickets[++head];
			if (t.want == 0) continue;

			uint256 part = t.want;
			if (part > free) part = free;

			t.want  -= uint128(part);
			t.ready += uint128(part);
			free    -= part;
		}
	}
}
