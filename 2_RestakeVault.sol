// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

contract RestakeVault is AccessControlUpgradeable, ReentrancyGuardUpgradeable {
	/*──────── Roles ───────*/
	bytes32 public constant RESTAKER_ROLE = keccak256("RESTAKER_ROLE");
	bytes32 public constant ORACLE_ROLE   = keccak256("ORACLE_ROLE");

	/*──────── External refs ─────*/
	address public wrstETH;              ///< proxy address of wrstETH

	/*──────── State ─────┐
	 * claimReserveWei    │ reserved ETH owed to tickets (cannot be withdrawn)
	 *────────────────────┘*/
	uint256 public claimReserveWei;

	/*──────── Initialiser ─────*/
	function initialize(
		address admin,
		address restaker,
		address oracle,
		address wrstAddr
	) external initializer {
		__AccessControl_init();
		__ReentrancyGuard_init();

		_grantRole(DEFAULT_ADMIN_ROLE, admin);
		_grantRole(RESTAKER_ROLE,     restaker);
		_grantRole(ORACLE_ROLE,       oracle);

		wrstETH = wrstAddr;
	}

	/*──────── Modifier: token not paused ─────*/
	modifier wrstETHNotPaused() {
		(bool ok, bytes memory rtn) =
			wrstETH.staticcall(abi.encodeWithSignature("paused()"));
		require(ok && rtn.length == 32 && !abi.decode(rtn,(bool)),
				"Vault: wrstETH paused");
		_;
	}

	/*──────── Outbound: send to CEX/hedge ────*/
	function withdrawForRestaking(uint256 amountWei)
		external
		wrstETHNotPaused
		onlyRole(RESTAKER_ROLE)
	{
		require(
			address(this).balance - claimReserveWei >= amountWei,
			"Vault: insufficient liquidity"
		);
		(bool sent, ) = msg.sender.call{value: amountWei}("");
		require(sent,"Vault: ETH send fail");
	}

	/*──────── Inbound: restaker return ───────*/
	function depositFromRestaker() external payable onlyRole(RESTAKER_ROLE) {}

	/*──────── Oracle reserve / release ───────*/
	function reserveForClaims(uint256 ethWei)
		external onlyRole(ORACLE_ROLE)
	{ claimReserveWei += ethWei; }

	function releaseClaim(address payable user, uint256 ethWei)
		external
		wrstETHNotPaused
		onlyRole(ORACLE_ROLE)
		nonReentrant
	{
		claimReserveWei -= ethWei;
		(bool ok,) = user.call{value: ethWei}("");
		require(ok, "Vault: claim xfer");
	}

	/*──────── Accidental ETH / tokens recovery ─────*/
	function sweep(address token, address to, uint256 amount)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		if (token == address(0)) {
			(bool ok,) = to.call{value: amount}("");
			require(ok, "Vault: sweep ETH");
		} else {
			// ERC-20 sweep
			(bool ok, bytes memory rtn) =
				token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
			require(ok && (rtn.length == 0 || abi.decode(rtn,(bool))), "Vault: sweep token");
		}
	}

	receive() external payable {}
}
