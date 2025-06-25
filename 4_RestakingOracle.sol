// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ───────────────────────── OpenZeppelin upgradeable ───────────────────────── */
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";

/* ────────────────────────────  Chainlink ETH/USD ─────────────────────────── */
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/* ──────────────────────────── External interfaces ─────────────────────────── */
interface IWrstX {
	function setRate(uint256) external;
	function resetDailyCounters() external;
}

interface IPointsController {
    function accrueDailyPoints(address token, uint256 usdPerShare) external;
}

/**
 * @title wrstOracle
 * @notice Keeper that pushes new price data for wrstX.
 */
contract wrstOracle is Ownable2StepUpgradeable, AccessControlEnumerableUpgradeable {
	bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

	/* ------------------------- Pending addresses ----------------------- */
	address public pendingKeeper;

	/* ------------------------- External links ------------------------- */
	IWrstX					public wrstETH;
	IPointsController		public points;
	AggregatorV3Interface	public priceEthUsdFeed;

	/* ---------------------------- Events ------------------------------ */
	event KeeperProposed(address oldKeeper, address newKeeper);
	event KeeperChanged(address oldKeeper, address newKeeper);
	event NewWrstEthRatePushed(uint256 newWrstEthRate);
	event WrstETHChanged(address oldWrstETH, address newWrstETH);
	event PointsControllerChanged(address oldController, address newController);
	event ChainlinkEthUsdChanged(address oldFeed, address newFeed);

	/* ---------------------------- Initializer ------------------------- */
	/**
	 * @notice Initializes the wrstOracle contract.
	 * @param owner_ Address to be set as contract owner.
	 * @param keeper Address to be granted KEEPER_ROLE.
	 * @param _wrstEth Address of the wrstETH token contract.
	 */
	function initialize(
		address owner_,
		address keeper,
		address _wrstEth,
		address _points,
		address _chainlinkEthUsd
	) external initializer {
		__Ownable2Step_init();
		__AccessControlEnumerable_init();

		_transferOwnership(owner_);
		_grantRole(KEEPER_ROLE, keeper);

		wrstETH			= IWrstX(_wrstEth);
		points			= IPointsController(_points); 
		priceEthUsdFeed	= AggregatorV3Interface(_chainlinkEthUsd);
	}

	/* ---------------------------- Admin functions ---------------------------- */
	/**
	 * @notice Sets a new wrstETH contract address.
	 * @param wrstEthAddr Address of the new wrstETH contract.
	 */
	function setWrstETH(address wrstEthAddr) external onlyOwner {
		require(wrstEthAddr != address(0), "Oracle: zero wrstETH");
		address old = address(wrstETH);
		wrstETH = IWrstX(wrstEthAddr);
		emit WrstETHChanged(old, wrstEthAddr);
	}

	/**
	 * @notice Sets a new PointsController contract address.
	 * @param pointsAddr Address of the new PointsController contract.
	 */
	function setPointsController(address pointsAddr) external onlyOwner {
		require(pointsAddr != address(0), "Oracle: zero points controller");
		address old = address(points);
		points = IPointsController(pointsAddr);
		emit PointsControllerChanged(old, pointsAddr);
	}

	/**
	 * @notice Sets a new Chainlink ETH/USD price feed address.
	 * @param chainlinkEthUsd Address of the new Chainlink ETH/USD price feed.
	 */
	function setChainlinkEthUsd(address chainlinkEthUsd) external onlyOwner {
		require(chainlinkEthUsd != address(0), "Oracle: zero Chainlink feed");
		address old = address(priceEthUsdFeed);
		priceEthUsdFeed = AggregatorV3Interface(chainlinkEthUsd);
		emit ChainlinkEthUsdChanged(old, chainlinkEthUsd);
	}

	/* ----------------------- Two-phase: KEEPER ------------------------ */
	function proposeKeeper(address newKeeper)
		external onlyOwner
	{
		require(newKeeper != address(0), "Oracle: zero keeper");
		pendingKeeper = newKeeper;
		emit KeeperProposed(getRoleMember(KEEPER_ROLE, 0), newKeeper);
	}
	
	function acceptKeeper() external {
		require(msg.sender == pendingKeeper, "Oracle: not pending keeper");
		address old = getRoleMember(KEEPER_ROLE, 0);

		_grantRole(KEEPER_ROLE, pendingKeeper);
		_revokeRole(KEEPER_ROLE, old);

		emit KeeperChanged(old, pendingKeeper);
		pendingKeeper = address(0);
	}

	/* ------------------------- Main keeper job ------------------------ */
	/**
	 * @notice Updates the X-to-wrstX conversion rate (ethRate).
	 * @param newWrstEthRate New ETH-to-wrstETH conversion rate.
	 */
	function pushReport(uint256 newWrstEthRate)
		external
		onlyRole(KEEPER_ROLE)
	{
		// Update price and reset daily mint counters
		wrstETH.setRate(newWrstEthRate);
		wrstETH.resetDailyCounters();

		if (address(points) != address(0)) {
			(
				uint80 roundId,
				int256 ethUsd,
				uint256 startedAt,
				uint256 updatedAt,
				uint80 answeredInRound
			) = priceEthUsdFeed.latestRoundData();

			// Chainlink feed safety checks (similar to Aave/Spark/Compound):
			require(ethUsd > 0, "Oracle: invalid Chainlink price");
			require(updatedAt != 0 && startedAt != 0, "Oracle: Chainlink round not complete");
			require(answeredInRound >= roundId, "Oracle: stale Chainlink round");
			require(block.timestamp - updatedAt < 1 days, "Oracle: Chainlink price too old");

			uint256 usdPerShare = newWrstEthRate * uint256(ethUsd) / 1e8; // wrstETH is 18 dec, ethUsd is 8 dec
			points.accrueDailyPoints(address(wrstETH), usdPerShare);
		}

		emit NewWrstEthRatePushed(newWrstEthRate);
	}
}
