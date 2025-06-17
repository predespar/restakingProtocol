// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───────────────────────── OpenZeppelin upgradeable ───────────────────────── */
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/* ──────────────────────────── External interfaces ─────────────────────────── */
interface IWrstETH {
	function burnForWithdrawal(uint256,address,address) external returns (uint256);
	function paused() external view returns (bool);
	function isFrozen(address) external view returns (bool);
	function allowance(address owner, address spender) external view returns (uint256);
	function queueApprove(address owner, address spender, uint256 subtractedValue) external;
}
interface IEthVault {
	function releaseClaim(address payable, uint256 ethWei, uint256 wethWei, bool instant) external;
	function claimReserveEthAmt() external view returns (uint256);
}

/**
 * @title WithdrawalEthQueue
 * @notice Each withdrawal request is represented by an ERC-721 NFT ticket (FIFO).
 *         Built for wrstETH; other assets can reuse the same pattern later.
 */
contract WithdrawalEthQueue is
	ERC721Upgradeable,
	Ownable2StepUpgradeable,
	ReentrancyGuardUpgradeable
{
	/* ------------------------- External links ------------------------- */
	IWrstETH	public wrstETH;
	IEthVault	public ethVault;

	/* ----------------------- ETH-specific state ----------------------- */
	/// @dev id → order size in wei. id is cumulative sum at creation.
	mapping(uint256 => uint256) public ethOrders;
	/// @dev id → timestamp when requestWithdrawEth was called
	mapping(uint256 => uint256) public ethOrderTimestamps;

	uint256 public totalEthOrdered;            // wei requested
	uint256 public totalEthReleased;           // wei released

	uint256 public totalEthOrders;             // count of ETH orders
	uint256 public totalReleasedEthOrders;     // count already claimable
	uint256 public totalReleasedEthOrdersTime; // total time (in seconds) for all processed orders

	/* ------------------------------ Events ----------------------------- */
	/**
	 * @notice Emitted when the ETH withdrawal queue is updated.
	 * @param newQueueTop The new value of totalEthReleased (queue top).
	 * @param pendingAmount The remaining amount of ETH pending in the queue.
	 */
	event QueueAdvanced(uint256 newQueueTop, uint256 pendingAmount);

	/* ---------------------------- Initializer ------------------------- */
	function initialize(
		address admin,
		address wrstEthAddr,
		address ethVaultAddr
	) external initializer {
		__ERC721_init("wrstETH Withdrawal Ticket", "wrsETHNFT");
		__Ownable2Step_init();
		__ReentrancyGuard_init();

		_transferOwnership(admin);

		wrstETH  = IWrstETH(wrstEthAddr);
		ethVault = IEthVault(ethVaultAddr);
	}

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
		require(!wrstETH.paused(), "Queue: paused");
		require(!wrstETH.isFrozen(receiver), "Queue: frozen");
		require(!wrstETH.isFrozen(owner), "Queue: frozen");
		if (owner != msg.sender) {
			uint256 allowed = wrstETH.allowance(owner, msg.sender);
			require(allowed >= ethShares, "Queue: insufficient allowance");
			// Decrease allowance by ethShares via wrstETH.queueApprove
			wrstETH.queueApprove(owner, msg.sender, ethShares);
		}

		uint256 ethWei = wrstETH.burnForWithdrawal(ethShares, receiver, owner);

		require(totalEthOrdered <= type(uint256).max - ethWei, "Queue: totalEthOrdered overflow");
		totalEthOrdered += ethWei;
		unchecked { ++totalEthOrders; }

		uint256 id = totalEthOrdered;        // unique, increasing
		uint256 ts = block.timestamp;
		ethOrders[id] = ethWei;
		ethOrderTimestamps[id] = ts;

		
		if (free > 0) ethQueueUpdate();

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
			ethVault.releaseClaim(payable(receiver), ethAmt, wETHamt, true); // instant = true

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
	function claim(uint256 id, uint256 wETHamt) external nonReentrant returns (uint256[4] memory result) {
		require(!wrstETH.paused(),              "Queue: paused");
		require(ownerOf(id) == msg.sender,           "Queue: !owner");
		require(!wrstETH.isFrozen(msg.sender),  "Queue: frozen");
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
		ethVault.releaseClaim(payable(msg.sender), ethAmt, wETHamt, false); // instant = false

		result[0] = id;
		result[1] = ts;
		result[2] = ethAmt;
		result[3] = wETHamt;
		return result;
	}

	/**
	 * @notice Updates the ETH withdrawal queue state.
	 *         Determines the total amount of ETH requested for withdrawal (pending),
	 *         checks the available ETH on the vault,
	 *         and advances the queue by updating `totalEthReleased` accordingly.
	 *         Any excess ETH remains available for other operations (e.g., restaking).
	 *
	 * @dev Called after every deposit (from user or RESTAKER_ROLE) and in `tryWithdraw`.
	 *      This function ensures that the queue is always up to date with the available liquidity.
	 */
	function ethQueueUpdate() public {
		// Calculate the available ETH amount in the vault
		uint256 availableEthAmt = address(ethVault).balance - ethVault.claimReserveEthAmt();
		// Calculate the total amount of ETH requested for withdrawal (pending)
		uint256 pending = totalEthOrdered > totalEthReleased
			? totalEthOrdered - totalEthReleased
			: 0;
		uint256 toRelease = availableEthAmt < pending ? availableEthAmt : pending;
		require(totalEthReleased <= type(uint256).max - toRelease, "Queue: totalEthReleased overflow");
		// Update the total released ETH amount = advances the queue.
		if (toRelease > 0) totalEthReleased += toRelease;
		// Emit event with new queue top and remaining pending amount
		emit QueueAdvanced(totalEthReleased, totalEthOrdered > totalEthReleased ? totalEthOrdered - totalEthReleased : 0);
		// Any excess (availableEthAmt > pending) is not reserved and remains available for restaking.
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
	 * @return ready True if claim can be called for this id (id released and not yet claimed).
	 * @return alreadyClaimed True if the claim was already processed (id released and already claimed).
	 */
	function isClaimReady(uint256 id) external view returns (bool ready, bool alreadyClaimed) {
		bool released = id <= totalEthReleased;
		bool exists = ethOrders[id] > 0;
		return (released, exists);
	}
}
