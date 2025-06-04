// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*─────────────── OpenZeppelin ───────────────*/
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/*─────────────── RestakeVault ───────*/
contract RestakeVault is AccessControlUpgradeable, ReentrancyGuardUpgradeable {
	/*──────── Roles ───────*/
	bytes32 public constant SPENDER_ROLE = keccak256("SPENDER_ROLE");
	bytes32 public constant ORACLE_ROLE  = keccak256("ORACLE_ROLE");

	/*──────── References ───*/
	address public wrstToken;            ///< wrstETH proxy

	/*──────── State ────────*/
	uint256 public claimReserveWei;      ///< ETH reserved for withdrawals

	/*──────── Initialiser ─*/
	function initialize(
		address admin,
		address spender,
		address oracle,
		address wrstAddr
	) external initializer {
		__AccessControl_init();
		__ReentrancyGuard_init();

		_grantRole(DEFAULT_ADMIN_ROLE, admin);
		_grantRole(SPENDER_ROLE,       spender);
		_grantRole(ORACLE_ROLE,        oracle);

		wrstToken = wrstAddr;
	}

	modifier tokenNotPaused() {
		(bool ok, bytes memory data) =
			wrstToken.staticcall(abi.encodeWithSignature("paused()"));
		require(ok && data.length==32 && !abi.decode(data,(bool)),
				"Vault: wrst paused");
		_;
	}

	/*──────── Outbound (restaking) ─*/
	function withdrawLiquidity(address payable to, uint256 amountWei)
		external tokenNotPaused onlyRole(SPENDER_ROLE)
	{
		require(
			address(this).balance - claimReserveWei >= amountWei,
			"Vault: insufficient free liquidity"
		);
		(bool sent,) = to.call{value: amountWei}("");
		require(sent,"Vault: transfer fail");
	}

	/*──────── Inbound (hedge return) ─*/
	function depositLiquidity() external payable onlyRole(SPENDER_ROLE) {}

	/*──────── Oracle reserve / release ─*/
	function reserveForClaims(uint256 ethWei)
		external onlyRole(ORACLE_ROLE)
	{ claimReserveWei += ethWei; }

	function releaseClaim(address payable user,uint256 ethWei)
		external tokenNotPaused onlyRole(ORACLE_ROLE) nonReentrant
	{
		claimReserveWei -= ethWei;
		(bool ok,) = user.call{value: ethWei}("");
		require(ok,"Vault: claim transfer");
	}

	receive() external payable {}
}
