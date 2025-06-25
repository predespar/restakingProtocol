// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

interface IWrstToken {
    function balanceOf(address) external view returns (uint256);
}

/**
 * @title PointsController
 * @notice Tracks global accPointsPerShare[token] indices and manages user points for all wrstX tokens.
 *         Points are NOT ERC-20 and are non-transferable.
 *
 * 1 point = 1 USD equivalent (18 decimals).
 *
 * Access:
 *   • TOKEN_ROLE  — wrstETH / wrstUSD / wrstBTC call settle*()
 *   • ORACLE_ROLE — RestakingOracle calls accrueDailyPoints()
 *   • DEFAULT_ADMIN_ROLE = contract owner (Ownable2Step)
 */
contract PointsController is
    Initializable,
    Ownable2StepUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    /* ---------- Roles ---------- */
    bytes32 public constant TOKEN_ROLE  = keccak256("TOKEN_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    /* ---------- Storage ---------- */
    address[] public tokens; // Enumerable list of supported wrstX tokens
    mapping(address => bool) public isToken; // Quick check for supported tokens
    mapping(address => uint256) public accPointsPerShare; // token => global index (1e18)
    mapping(address => mapping(address => uint256)) public debt; // token => user => debt
    mapping(address => uint256) public points; // user => accrued points

    /// @notice Claim phase state and claimed points info
    bool public claimable; // claim phase flag
    struct Claimed { uint256 amount; bool staked; }
    mapping(address => Claimed) public claimedPoints; // user => claimed info

    /* ---------- Events ---------- */
    event Accrued(address indexed token, uint256 newAcc);
    event PointsAccrued(address indexed user, uint256 amount);
    event ClaimedPoints(address indexed user, uint256 amount, bool staked);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);

    /* ---------- Initializer ---------- */
    function initialize() external initializer {
        __Ownable2Step_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
    }

    /* ================================================================
                                GOVERNANCE
    ================================================================ */

    /**
     * @notice Adds a new wrstX token to the controller.
     * @param token Address of the wrstX token.
     */
    function addToken(address token) external onlyOwner {
        require(!isToken[token], "PointsController: already added");
        isToken[token] = true;
        tokens.push(token);
        _grantRole(TOKEN_ROLE, token);
        emit TokenAdded(token);
    }

    /**
     * @notice Removes a wrstX token from the controller.
     * @param token Address of the wrstX token.
     */
    function removeToken(address token) external onlyOwner {
        require(isToken[token], "PointsController: not a token");
        isToken[token] = false;
        _revokeRole(TOKEN_ROLE, token);
        emit TokenRemoved(token);
        // Array cleanup is not critical for 3-5 tokens
    }

    /**
     * @notice Enables or disables the claim phase.
     * @param on True to enable claim phase, false to disable.
     */
    function setClaimable(bool on) external onlyOwner {
        claimable = on;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /* ================================================================
                          DAILY ACCRUAL  (oracle)
    ================================================================ */
    /**
     * @notice Accrues daily points for a wrstX token.
     * @dev Called by oracle once per wrstX per day.
     * @param token wrstX address
     * @param usdPerShare Daily delta, 18 decimals (see Oracle)
     */
    function accrueDailyPoints(address token, uint256 usdPerShare)
        external
        onlyRole(ORACLE_ROLE)
    {
        require(!claimable, "PointsController: claim phase on");
        require(isToken[token], "PointsController: unknown token");
        accPointsPerShare[token] += usdPerShare;
        emit Accrued(token, accPointsPerShare[token]);
    }

    /* ================================================================
                         SETTLEMENT  (wrstX-tokens)
    ================================================================ */
    /**
     * @notice Settles user points before a token transfer.
     * @dev Called by wrstX tokens with TOKEN_ROLE.
     * @param token wrstX token address
     * @param user User address
     */
    function settleBefore(address token, address user)
        external
        onlyRole(TOKEN_ROLE)
        whenNotPaused
    {
        if (!claimable) {
            uint256 balance = IWrstToken(token).balanceOf(user);
            uint256 newPoints =
                balance * accPointsPerShare[token] / 1e18 - debt[token][user];

            if (newPoints > 0) {
                points[user] += newPoints;
                emit PointsAccrued(user, newPoints);
            }
        }
        // If claimable == true, do nothing (allow transfer without points accrual)
    }

    /**
     * @notice Updates user debt after a token transfer.
     * @dev Called by wrstX tokens with TOKEN_ROLE.
     * @param token wrstX token address
     * @param user User address
     */
    function settleAfter(address token, address user)
        external
        onlyRole(TOKEN_ROLE)
        whenNotPaused
    {
        if (!claimable) {
            uint256 balance = IWrstToken(token).balanceOf(user);
            debt[token][user] = balance * accPointsPerShare[token] / 1e18;
        }
        // If claimable == true, do nothing (allow transfer without debt update)
    }

    /* ================================================================
                         USER  VIEW  HELPERS
    ================================================================ */
    /**
     * @notice Returns the total pending points for a user (accrued + unaccrued yet).
     * @param user User address
     * @return total Total pending points
     */
    function pendingPoints(address user) public view returns (uint256 total) {
        total = points[user];
        uint256 len = tokens.length;
        for (uint256 i; i < len; ++i) {
            address token = tokens[i];
            uint256 balance = IWrstToken(token).balanceOf(user);
            uint256 newPts  =
                balance * accPointsPerShare[token] / 1e18 - debt[token][user];
            total += newPts;
        }
        return total;
    }

    /* ================================================================
                               CLAIM
    ================================================================ */
    /**
     * @notice Claims all accrued points for the caller.
     */
    function claim() external nonReentrant {
        _claim(false);
    }

    /**
     * @notice Claims and stakes all accrued points for the caller.
     */
    function claimAndStake() external nonReentrant {
        _claim(true);
    }

    /**
     * @dev Internal claim logic.
     * @param stakeFlag True if staking, false otherwise.
     */
    function _claim(bool stakeFlag) internal whenNotPaused {
        require(claimable, "PointsController: claim phase off");

        uint256 amount = pendingPoints(_msgSender());
        require(amount > 0, "PointsController: zero");

        // Reset user debt for all tokens
        uint256 len = tokens.length;
        for (uint256 i; i < len; ++i) {
            address token = tokens[i];
            uint256 bal = IWrstToken(token).balanceOf(_msgSender());
            debt[token][_msgSender()] =
                bal * accPointsPerShare[token] / 1e18;
        }
        points[_msgSender()] = 0;

        claimedPoints[_msgSender()] = Claimed(amount, stakeFlag);
        emit ClaimedPoints(_msgSender(), amount, stakeFlag);
        // Minting WRST / sWRST is handled by a separate distributor
    }
}
