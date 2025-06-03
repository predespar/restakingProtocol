// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*─────────────── OpenZeppelin ───────────────*/
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/*─────────────── External interfaces ───────*/
interface IVault {
    function reserveForClaims(uint256 ethWei) external;
    function paused() external view returns (bool);
}

/*─────────────── Wrapped Restaked Ether (wrstETH) ───────*/
contract WrstETH is
    ERC20BurnableUpgradeable,
    ERC20PermitUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    /*---------------- Roles ----------------*/
    bytes32 public constant FREEZER_ROLE       = keccak256("FREEZER_ROLE");
    bytes32 public constant PAUSER_ROLE        = keccak256("PAUSER_ROLE");
    bytes32 public constant CAP_MANAGER_ROLE   = keccak256("CAP_MANAGER_ROLE");
    bytes32 public constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 public constant ORACLE_ROLE        = keccak256("ORACLE_ROLE");
    bytes32 public constant QUEUE_ROLE         = keccak256("QUEUE_ROLE");

    /*---------------- Immutable ----------------*/
    uint256 public immutable initialCapWei;    ///< cap at deployment

    /*---------------- Storage ----------------*/
    IVault  public vault;          ///< ETH vault contract
    uint256 public rateWei;        ///< ETH per 1 wrst (18 decimals)

    uint256 public maxSupplyWei;   ///< current cap
    uint256 public dayMintLimitWei;
    uint256 public dayBurnLimitWei;

    uint256 public mintedTodayWei;
    uint256 public burnedTodayWei;
    uint64  public currentDayIndex;   ///< floor(block.timestamp / 1 days)

    mapping(address => bool) private _frozen;

    /*---------------- Events ----------------*/
    event Frozen(address indexed);
    event Unfrozen(address indexed);
    event Confiscated(address indexed, uint256 amountWei);
    event CapChanged(uint256 oldCapWei, uint256 newCapWei);
    event DailyLimitsChanged(uint256 mintWei, uint256 burnWei);
    event RateChanged(uint256 oldRateWei, uint256 newRateWei);

    /*---------------- Initializer ----------------*/
    function initialize(
        address admin,
        address freezer,
        address pauser,
        address vaultAddr,
        uint256 capWei,
        uint256 dailyPercent        // e.g. 10 for 10 %
    ) external initializer
    {
        __ERC20_init("Wrapped Restaked ETH", "wrstETH");
        __ERC20Permit_init("Wrapped Restaked ETH");
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FREEZER_ROLE,       freezer);
        _grantRole(PAUSER_ROLE,        pauser);
        _grantRole(CAP_MANAGER_ROLE,   admin);
        _grantRole(LIMIT_MANAGER_ROLE, admin);

        vault           = IVault(vaultAddr);
        rateWei         = 1e18;               // 1 wrst = 1 ETH at T0
        maxSupplyWei    = capWei;
        initialCapWei   = capWei;

        uint256 limitWei = capWei * dailyPercent / 100;
        _setDailyLimits(limitWei, limitWei);

        currentDayIndex = uint64(block.timestamp / 1 days);
    }

    /*---------------- Freeze logic ----------------*/
    function freeze(address acct)   external onlyRole(FREEZER_ROLE) {
        _frozen[acct] = true;
        emit Frozen(acct);
    }
    function unfreeze(address acct) external onlyRole(FREEZER_ROLE) {
        _frozen[acct] = false;
        emit Unfrozen(acct);
    }
    function confiscate(address acct) external onlyRole(FREEZER_ROLE) {
        require(_frozen[acct], "WrstETH: not frozen");
        uint256 bal = balanceOf(acct);
        _burn(acct, bal);
        emit Confiscated(acct, bal);
    }
    function isFrozen(address acct) external view returns (bool) {
        return _frozen[acct];
    }

    /*---------------- Pause / unpause ----------------*/
    function pause()   external onlyRole(PAUSER_ROLE) { _pause();  }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause();}

    /*---------------- Cap & daily-limit control ----------------*/
    function setCap(uint256 newCapWei) external onlyRole(CAP_MANAGER_ROLE) {
        require(newCapWei > 0, "WrstETH: cap 0");
        emit CapChanged(maxSupplyWei, newCapWei);
        maxSupplyWei = newCapWei;
    }

    function setDailyLimits(uint256 mintWei, uint256 burnWei)
        external onlyRole(LIMIT_MANAGER_ROLE)
    {
        _setDailyLimits(mintWei, burnWei);
    }
    function _setDailyLimits(uint256 m, uint256 b) internal {
        dayMintLimitWei = m;
        dayBurnLimitWei = b;
        emit DailyLimitsChanged(m, b);
    }

    /*---------------- View helpers ----------------*/
    function wrstByEth(uint256 ethWei) public view returns (uint256) {
        return ethWei * 1e18 / rateWei;
    }
    function ethByWrst(uint256 wrstWei) public view returns (uint256) {
        return wrstWei * rateWei / 1e18;
    }

    /*---------------- ERC20 transfer hook ----------------*/
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amt
    ) internal override {
        require(!paused(), "WrstETH: paused");
        require(!_frozen[from] && !_frozen[to], "WrstETH: frozen");
        super._beforeTokenTransfer(from, to, amt);
    }

    /*---------------- Deposit ----------------*/
    function deposit()
        external
        payable
        whenNotPaused
        returns (uint256 minted)
    {
        require(msg.value > 0, "WrstETH: zero ETH");

        uint256 wrstWei = wrstByEth(msg.value);
        _enforceDailyMint(wrstWei);

        uint256 roomWei = maxSupplyWei - totalSupply();
        require(roomWei > 0, "WrstETH: cap reached");
        if (wrstWei > roomWei) wrstWei = roomWei;

        mintedTodayWei += wrstWei;
        minted = wrstWei;

        _mint(msg.sender, wrstWei);

        uint256 ethUsed = ethByWrst(wrstWei);
        (bool okVault, ) = address(vault).call{value: ethUsed}("");
        require(okVault, "WrstETH: vault push fail");

        uint256 refund = msg.value - ethUsed;
        if (refund > 0) {
            (bool okRefund, ) = payable(msg.sender).call{value: refund}("");
            require(okRefund, "WrstETH: refund fail");
        }
    }

    /*---------------- Withdrawal burn ----------------*/
    function burnForWithdrawal(address from, uint256 wrstWei)
        external
        whenNotPaused
        onlyRole(QUEUE_ROLE)
        returns (uint256 ethWei)
    {
        require(
            burnedTodayWei + wrstWei <= dayBurnLimitWei,
            "WrstETH: daily burn cap"
        );
        burnedTodayWei += wrstWei;

        ethWei = ethByWrst(wrstWei);
        _burn(from, wrstWei);
        vault.reserveForClaims(ethWei);
    }

    /*---------------- Oracle-only functions ----------------*/
    function setRateWei(uint256 newRateWei) external onlyRole(ORACLE_ROLE) {
        emit RateChanged(rateWei, newRateWei);
        rateWei = newRateWei;
    }
    function resetDailyCounters() external onlyRole(ORACLE_ROLE) {
        mintedTodayWei  = 0;
        burnedTodayWei  = 0;
        currentDayIndex = uint64(block.timestamp / 1 days);
    }

    /*---------------- Internals ----------------*/
    function _enforceDailyMint(uint256 wrstWei) internal view {
        require(
            mintedTodayWei + wrstWei <= dayMintLimitWei,
            "WrstETH: daily mint cap"
        );
    }

    /* allow Vault to receive ETH back */
    receive() external payable {}
}
