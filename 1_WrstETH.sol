// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

interface IVault {
    function reserveForClaims(uint256) external;
}

contract WrstETH is
    ERC20PermitUpgradeable,
    ERC20BurnableUpgradeable,
    ERC20CappedUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    /*──────── roles ───────*/
    bytes32 public constant FREEZER_ROLE       = keccak256("FREEZER_ROLE");
    bytes32 public constant PAUSER_ROLE        = keccak256("PAUSER_ROLE");
    bytes32 public constant CAP_MANAGER_ROLE   = keccak256("CAP_MANAGER_ROLE");
    bytes32 public constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 public constant ORACLE_ROLE        = keccak256("ORACLE_ROLE");
    bytes32 public constant QUEUE_ROLE         = keccak256("QUEUE_ROLE");

    /*──────── storage ─────*/
    IVault   public vault;
    uint256  public rateWei;        // ETH per 1 wrst token (18d)

    uint256  public dailyLimitWei;
    uint256  private _mintedToday;
    uint256  private _burnedToday;
    uint64   private _dayIndex;

    mapping(address => bool) private _frozen;

    event Frozen(address);
    event Unfrozen(address);
    event FrozenBalanceWiped(address,uint256);
    event CapUpdated(uint256,uint256);
    event DailyLimitUpdated(uint256,uint256);

    /*──────── initializer ─*/
    function initialize(
        address admin,
        address freezer,
        address pauser,
        uint256 capWei,
        address vaultAddr
    ) external initializer {
        __ERC20_init("Wrapped Restaked ETH", "wrstETH");
        __ERC20Permit_init("Wrapped Restaked ETH");
        __ERC20Burnable_init();
        __ERC20Capped_init(capWei);
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FREEZER_ROLE,       freezer);
        _grantRole(PAUSER_ROLE,        pauser);
        _grantRole(CAP_MANAGER_ROLE,   admin);
        _grantRole(LIMIT_MANAGER_ROLE, admin);

        vault   = IVault(vaultAddr);
        rateWei = 1e18;
        dailyLimitWei = capWei / 10;          // 10 %
        _dayIndex     = uint64(block.timestamp / 1 days);
    }

    /*──────── modifiers ───*/
    function _updateRolling24h() internal {
        uint64 today = uint64(block.timestamp / 1 days);
        if (today > _dayIndex) {
            _dayIndex = today;
            _mintedToday = 0;
            _burnedToday = 0;
        }
    }

    /*──────── freeze logic */
    function freeze(address a)   external onlyRole(FREEZER_ROLE) { _frozen[a]=true;  emit Frozen(a);  }
    function unfreeze(address a) external onlyRole(FREEZER_ROLE) { _frozen[a]=false; emit Unfrozen(a);}
    function wipeFrozenAddress(address a)
        external
        onlyRole(FREEZER_ROLE)
    {
        require(_frozen[a], "not frozen");
        uint256 bal = balanceOf(a);
        _burn(a, bal);
        emit FrozenBalanceWiped(a, bal);
    }

    function isFrozen(address a) external view returns (bool) { return _frozen[a]; }

    /*──────── pausable ────*/
    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    /*──────── cap & limit */
    function setCap(uint256 newCap) external onlyRole(CAP_MANAGER_ROLE) {
        require(newCap >= totalSupply(), "below circulation");
        emit CapUpdated(cap(), newCap);
        _updateCap(newCap);
    }

    function setDailyLimitWei(uint256 w) external onlyRole(LIMIT_MANAGER_ROLE) {
        emit DailyLimitUpdated(dailyLimitWei, w);
        dailyLimitWei = w;
    }

    /*──────── public views */
    function getWrstETHByETH(uint256 ethWei) public view returns (uint256) {
        return (ethWei * 1e18) / rateWei;
    }
    function getETHByWrstETH(uint256 wrstWei) public view returns (uint256) {
        return (wrstWei * rateWei) / 1e18;
    }

    /*──────── internal hook */
    function _beforeTokenTransfer(address from, address to, uint256 amt)
        internal
        override
    {
        require(!paused(), "token paused");
        require(!_frozen[from] && !_frozen[to], "frozen");
        super._beforeTokenTransfer(from,to,amt);
    }

    /*──────── deposits ────*/
    function deposit() external payable whenNotPaused returns (uint256 minted) {
        require(msg.value > 0, "ZERO_ETH");
        _updateRolling24h();

        uint256 wrst = getWrstETHByETH(msg.value);
        uint256 room = cap() - totalSupply();
        require(room > 0, "CAP_REACHED");
        if (wrst > room) wrst = room;

        require(_mintedToday + wrst <= dailyLimitWei, "DAILY_MINT_CAP");
        _mintedToday += wrst;

        uint256 ethUsed = getETHByWrstETH(wrst);
        _mint(msg.sender, wrst);
        (bool ok, ) = address(vault).call{value: ethUsed}("");
        require(ok,"vault push fail");

        if (msg.value > ethUsed) {
            (bool ok2,) = msg.sender.call{value: msg.value - ethUsed}("");
            require(ok2,"refund fail");
        }
        return wrst;
    }

    /*──────── burn for queue */
    function burnForWithdrawal(address from, uint256 wrstWei)
        external
        onlyRole(QUEUE_ROLE)
        whenNotPaused
        returns (uint256 ethWei)
    {
        _updateRolling24h();
        require(_burnedToday + wrstWei <= dailyLimitWei, "DAILY_BURN_CAP");
        _burnedToday += wrstWei;

        ethWei = getETHByWrstETH(wrstWei);
        _burn(from, wrstWei);
        vault.reserveForClaims(ethWei);
    }

    /*──────── oracle update */
    function setRateWei(uint256 newRate) external onlyRole(ORACLE_ROLE) {
        rateWei = newRate;
    }

    /*──────── overrides (cap) */
    function _updateCap(uint256 newCap) internal {
        /// ERC20Capped internal setter
        assembly { sstore(0x45, newCap) }
    }
}
