// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───────────────────────── OpenZeppelin upgradeable ───────────────────────── */
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/* ──────────────────────────── External interfaces ─────────────────────────── */
interface IWrappedTokenQueue {
	function burnForWithdrawal(uint256,address,address) external returns (uint256);
	function paused() external view returns (bool);
	function isFrozen(address) external view returns (bool);
}
interface IVaultQueue {
	function releaseClaim(address payable, uint256 ethWei, uint256 wethWei, bool instant) external;
}

/**
 * @title WithdrawalQueue
 * @notice Each withdrawal request is represented by an ERC-721 NFT ticket (FIFO).
 *         Built for wrstETH; other assets can reuse the same pattern later.
 */
contract WithdrawalQueue is
	ERC721Upgradeable,
	Ownable2StepUpgradeable,
	AccessControlEnumerableUpgradeable,
	ReentrancyGuardUpgradeable
{
	/* ------------------------------ Roles ------------------------------ */
	bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

	/* ------------------------- External links ------------------------- */
	IWrappedTokenQueue public wrstETHToken;
	IVaultQueue        public vault;

	/* ----------------------- ETH-specific state ----------------------- */
	/// @dev id → order size in wei. id is cumulative sum at creation.
	mapping(uint256 => uint256) public ethOrders;
	/// @dev id → timestamp when requestWithdrawEth was called
	mapping(uint256 => uint256) public ethOrderTimestamps;

	uint256 public totalEthOrdered;            // wei requested
	uint256 public totalEthReleased;           // wei released by oracle

	uint256 public totalEthOrders;             // count of ETH orders
	uint256 public totalReleasedEthOrders;     // count already claimable
	uint256 public totalReleasedEthOrdersTime; // total time (in seconds) for all processed orders

	/* ------------------------------ Events ----------------------------- */
	event AdminProposed(address indexed oldAdmin, address indexed newAdmin);
	event AdminChanged( address indexed oldAdmin, address indexed newAdmin);
	event OracleChanged(address indexed oldOracle, address indexed newOracle);

	/**
	 * @dev Emitted after processEth with current queue, free liquidity, surplus, and totalEthReleased.
	 * @param queueSize Amount of ETH in the withdrawal queue (totalEthOrdered - totalEthReleased)
	 * @param freeLiquidity Amount of ETH available for instant withdrawal (address(vault).balance - vault.claimReserveEthAmt())
	 * @param surplus Surplus/deficit in the vault (see RestakeVault logic)
	 * @param totalEthReleased Current value of totalEthReleased (top of the queue)
	 */
	event QueueVaultState(
		uint256 queueSize,
		uint256 freeLiquidity,
		int256 surplus,
		uint256 totalEthReleased
	);

	/* ---------------------------- Initializer ------------------------- */
	function initialize(
		address admin,
		address oracle,
		address wrstETHtokenAddr,
		address vaultAddr
	) external initializer {
		__ERC721_init("wrstETH Withdrawal Ticket", "wrsETHNFT");
		__Ownable2Step_init();
		__AccessControlEnumerable_init();
		__ReentrancyGuard_init();

		_transferOwnership(admin);
		_grantRole(ORACLE_ROLE, oracle);

		wrstETHToken = IWrappedTokenQueue(wrstETHtokenAddr);
		vault        = IVaultQueue(vaultAddr);
	}
	mapping(address => mapping(address => uint256)) private _withdrawAllowances;

	/**
	 * @notice Approve `spender` to request withdrawals of up to `amount` wrstETH shares on behalf of `owner`.
	 *         Analogous to ERC-20 approve.
	 *         Note: Calling approve repeatedly overwrites the previous value (does not increment or reset to zero first).
	 * @param spender Address allowed to request withdrawal.
	 * @param amount Maximum amount of wrstETH shares allowed.
	 * @return success True if approval succeeded.
	 */
	function approve(address spender, uint256 amount) external returns (bool success) {
		_withdrawAllowances[msg.sender][spender] = amount;
		emit WithdrawalApproval(msg.sender, spender, amount);
		return true;
	}

	/**
	 * @notice Returns the remaining number of wrstETH shares that `spender` is allowed to withdraw on behalf of `owner`.
	 * @param owner The address which owns the funds.
	 * @param spender The address which will spend the funds.
	 * @return remaining Remaining allowance.
	 */
	function allowance(address owner, address spender) public view returns (uint256 remaining) {
		return _withdrawAllowances[owner][spender];
	}

	event WithdrawalApproval(address indexed owner, address indexed spender, uint256 value);

	/* ------------------------ User: try withdraw ETH ----------------------- */
	/**
	 * @notice Requests withdrawal of ETH and attempts to immediately claim if possible.
	 *         If enough liquidity is available, user receives ETH/wETH instantly and no NFT is minted.
	 *         Otherwise, an NFT ticket is minted and user waits for their turn in the queue.
	 * @param ethShares Amount of wrstETH shares to withdraw.
	 * @param receiver Address to receive the NFT ticket or ETH/wETH.
	 * @param owner Address of the owner of the shares.
	 * @param wETHamt Amount of wETH user wants to receive (0 – all ETH).
	 * @return result Array: [NFT id (0 if claimed instantly), timestamp, ETH claimed, wETH claimed]
	 */
	function tryWithdraw(
		uint256 ethShares,
		address receiver,
		address owner,
		uint256 wETHamt
	) external nonReentrant returns (uint256[4] memory result) {
		require(!wrstETHToken.paused(),            "Queue: paused");
		require(!wrstETHToken.isFrozen(receiver),  "Queue: frozen");
		require(!wrstETHToken.isFrozen(owner),     "Queue: frozen");
		if (owner != msg.sender) {
			uint256 allowed = _withdrawAllowances[owner][msg.sender];
			require(allowed >= ethShares, "Queue: insufficient allowance");
			unchecked {
				_withdrawAllowances[owner][msg.sender] = allowed - ethShares;
			}
			emit WithdrawalApproval(owner, msg.sender, _withdrawAllowances[owner][msg.sender]);
		}

		uint256 ethWei = wrstETHToken.burnForWithdrawal(ethShares, receiver, owner);

		require(totalEthOrdered <= type(uint256).max - ethWei, "Queue: totalEthOrdered overflow");
		totalEthOrdered += ethWei;
		unchecked { ++totalEthOrders; }

		uint256 id = totalEthOrdered;        // unique, increasing
		uint256 ts = block.timestamp;
		ethOrders[id] = ethWei;
		ethOrderTimestamps[id] = ts;

		// Try to advance the queue with current free liquidity
		uint256 free = address(vault).balance - vault.claimReserveEthAmt();
		if (free > 0) {
			this.processEth(free);
		}

		// If claim is ready, immediately process and return funds, no NFT minted
		if (id <= totalEthReleased && ethOrders[id] > 0) {
			uint256 amt = ethOrders[id];
			require(amt >= wETHamt, "Queue: wETH value exceeded");

			// Calculate and accumulate processing time before deleting timestamp
			totalReleasedEthOrdersTime += block.timestamp - ethOrderTimestamps[id];

			delete ethOrders[id];
			delete ethOrderTimestamps[id];
			unchecked { ++totalReleasedEthOrders; }

			uint256 ethAmt = amt - wETHamt;
			vault.releaseClaim(payable(receiver), ethAmt, wETHamt, true); // instant = true

			// No NFT minted, return [0, timestamp, ETH, wETH]
			result[0] = 0;
			result[1] = ts;
			result[2] = ethAmt;
			result[3] = wETHamt;
			return result;
		}

		// Otherwise, mint NFT and return [id, timestamp, 0, 0]
		_mint(receiver, id);
		result[0] = id;
		result[1] = ts;
		result[2] = 0;
		result[3] = 0;
		return result;
	}

	/* --------------------------- User: claim -------------------------- */
	/**
	 * @param id       NFT ticket id
	 * @param wETHamt  How much of the total should be received in wETH (0 – all ETH)
	 */
	function claimEth(uint256 id, uint256 wETHamt) external nonReentrant returns (uint256[4] memory result) {
		require(!wrstETHToken.paused(),              "Queue: paused");
		require(ownerOf(id) == msg.sender,           "Queue: !owner");
		require(!wrstETHToken.isFrozen(msg.sender),  "Queue: frozen");
		require(id <= totalEthReleased,              "Queue: not ready");

		uint256 amt = ethOrders[id];
		require(amt > 0, "Queue: already claimed");
		require(amt >= wETHamt, "Queue: wETH value exceeded");

		uint256 ts = ethOrderTimestamps[id];

		// Calculate and accumulate processing time before deleting timestamp
		totalReleasedEthOrdersTime += block.timestamp - ts;

		delete ethOrders[id];
		delete ethOrderTimestamps[id];
		unchecked { ++totalReleasedEthOrders; }

		_burn(id);
		uint256 ethAmt = amt - wETHamt;
		vault.releaseClaim(payable(msg.sender), ethAmt, wETHamt, false); // instant = false

		result[0] = id;
		result[1] = ts;
		result[2] = ethAmt;
		result[3] = wETHamt;
		return result;
	}

	/* ---------------- Oracle: release ETH liquidity ------------------- */
	/**
	 * @notice Processes ETH liquidity released by the oracle or deposit logic.
	 *         Only the required amount for pending withdrawals is reserved; excess is ignored.
	 * @param availableEthAmt Amount of ETH available for release (in Wei).
	 */
	function processEth(uint256 availableEthAmt)
		external
		onlyRole(ORACLE_ROLE)
	{
		uint256 pending = totalEthOrdered > totalEthReleased
			? totalEthOrdered - totalEthReleased
			: 0;
		uint256 toRelease = availableEthAmt < pending ? availableEthAmt : pending;
		require(totalEthReleased <= type(uint256).max - toRelease, "Queue: totalEthReleased overflow");
		if (toRelease > 0) {
			totalEthReleased += toRelease;
		}
		// Any excess (availableEthAmt > pending) is not reserved and remains available for restaking.

		// --- Emit QueueVaultState event ---
		uint256 queueSize = totalEthOrdered - totalEthReleased;
		uint256 freeLiquidity = address(vault).balance - vault.claimReserveEthAmt();

		// Calculate surplus as in RestakeVault
		uint256 fastReserve = 0;
		uint256 withdrawReserve = 0;
		try vault.withdrawReserve() returns (uint256 wr) {
			withdrawReserve = wr;
		} catch {}
		if (withdrawReserve > 0) {
			uint256 totalSupply = 0;
			try wrstETHToken.totalSupply() returns (uint256 ts) {
				totalSupply = ts;
			} catch {}
			uint256 reserveShares = totalSupply / withdrawReserve;
			try wrstETHToken.getETHByWrstETH(reserveShares) returns (uint256 fr) {
				fastReserve = fr;
			} catch {}
		}
		uint256 minBalance = vault.claimReserveEthAmt() + fastReserve;
		int256 surplus = int256(address(vault).balance) - int256(minBalance);

		emit QueueVaultState(queueSize, freeLiquidity, surplus, totalEthReleased);
	}
	
	/* ---------------------- One-step oracle rotation ------------------ */
	function setOracle(address newOracle)
		external onlyOwner
	{
		require(newOracle != address(0), "Queue: zero oracle");
		address old = getRoleMember(ORACLE_ROLE, 0);

		_grantRole(ORACLE_ROLE, newOracle);
		_revokeRole(ORACLE_ROLE, old);

		emit OracleChanged(old, newOracle);
	}

	/**
	 * @notice Returns the average processing time (in seconds) for all processed withdrawal orders.
	 */
	function getAverageProcessingTime() public view returns (uint256) {
		if (totalReleasedEthOrders == 0) return 0;
		return totalReleasedEthOrdersTime / totalReleasedEthOrders;
	}

	/**
	 * @notice Returns the average withdrawal request size (in wei).
	 */
	function getAverageRequestSize() public view returns (uint256) {
		if (totalEthOrders == 0) return 0;
		return totalEthOrdered / totalEthOrders;
	}

	/**
	 * @notice Returns the average daily payout amount (in wei per 24 hours).
	 *         Calculated as totalEthOrdered / (totalReleasedEthOrdersTime / 1 days)
	 */
	function getAverageDailyPayout() public view returns (uint256) {
		if (totalReleasedEthOrdersTime == 0) return 0;
		return totalEthOrdered * 1 days / totalReleasedEthOrdersTime;
	}

	/**
	 * @notice Returns the claim status for a withdrawal ticket.
	 * @param id NFT ticket id.
	 * @return ready True if claimEth can be called for this id (id released and not yet claimed).
	 * @return alreadyClaimed True if the claim was already processed (id released and already claimed).
	 */
	function isClaimReady(uint256 id) external view returns (bool ready, bool alreadyClaimed) {
		bool released = id <= totalEthReleased;
		bool exists = ethOrders[id] > 0;
		return (released, exists);
	}

	/**
	 * @notice Returns a URI for the given NFT ticket (ERC-721 metadata).
	 *         Returns a generic JSON metadata string; can be replaced with a real URL if needed.
	 */
	function tokenURI(uint256 tokenId) public view override returns (string memory) {
		require(_exists(tokenId), "ERC721: invalid token ID");
		// Simple on-chain metadata as a data: URI (for demonstration)
		string memory json = string(abi.encodePacked(
			'{"name":"wrstETH Withdrawal Ticket #',
			_toString(tokenId),
			'","description":"wrstETH withdrawal queue NFT. Redeemable for ETH or wETH when processed.","attributes":[{"trait_type":"Order ID","value":"',
			_toString(tokenId),
			'"}]}'
		));
		return string(abi.encodePacked("data:application/json;base64,", _base64(bytes(json))));
	}

	// --- Internal helpers for tokenURI ---
	function _toString(uint256 value) internal pure returns (string memory) {
		if (value == 0) return "0";
		uint256 temp = value;
		uint256 digits;
		while (temp != 0) {
			digits++;
			temp /= 10;
		}
		bytes memory buffer = new bytes(digits);
		while (value != 0) {
			digits -= 1;
			buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
			value /= 10;
		}
		return string(buffer);
	}

	function _base64(bytes memory data) internal pure returns (string memory) {
		bytes memory TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
		uint256 len = data.length;
		if (len == 0) return "";
		uint256 encodedLen = 4 * ((len + 2) / 3);
		bytes memory result = new bytes(encodedLen + 32);
		bytes memory table = TABLE;
		assembly {
			let tablePtr := add(table, 1)
			let resultPtr := add(result, 32)
			for { let i := 0 } lt(i, len) {} {
				i := add(i, 3)
				let input := and(mload(add(data, i)), 0xffffff)
				let out := mload(add(tablePtr, and(shr(18, input), 0x3F)))
				out := shl(8, out)
				out := add(out, mload(add(tablePtr, and(shr(12, input), 0x3F))))
				out := shl(8, out)
				out := add(out, mload(add(tablePtr, and(shr(6, input), 0x3F))))
				out := shl(8, out)
				out := add(out, mload(add(tablePtr, and(input, 0x3F))))
				out := shl(224, out)
				mstore(resultPtr, out)
				resultPtr := add(resultPtr, 4)
			}
			switch mod(len, 3)
			case 1 { mstore(sub(resultPtr, 2), shl(240, 0x3d3d)) }
			case 2 { mstore(sub(resultPtr, 1), shl(248, 0x3d)) }
			mstore(result, encodedLen)
		}
		return string(result);
	}

	// --- EIP-165: supportsInterface for ERC-721 and (optionally) ERC-2981 ---
	function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, AccessControlEnumerableUpgradeable) returns (bool) {
		return super.supportsInterface(interfaceId);
	}
}
