// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

interface IWrappedRestakedToken {
	function paused() external view returns (bool);
}

contract RestakeVault is AccessControlUpgradeable, ReentrancyGuardUpgradeable {
	using AddressUpgradeable for address payable;

	/* ───────── Roles ───── */
	bytes32 public constant RESTAKER_ROLE = keccak256("RESTAKER_ROLE");
	bytes32 public constant ORACLE_ROLE   = keccak256("ORACLE_ROLE");

	/* ───────── External refs ───── */
	IWrappedRestakedToken public wrappedToken;   ///< wrstETH (or USD/BTC) proxy

	/* ───────── State ───── */
	uint256 private _claimReserveWei;            ///< reserved ETH for queued claims

	/* ───────── Events ──── */
	event RestakerUpdated(address indexed oldRestaker, address indexed newRestaker);
	event OracleUpdated(  address indexed oldOracle,   address indexed newOracle);

	/* ───────── Initialiser ─ */
	function initialize(
		address admin,
		address restaker,
		address oracle,
		address tokenAddr
	) external initializer {
		__AccessControl_init();
		__ReentrancyGuard_init();

		_grantRole(DEFAULT_ADMIN_ROLE, admin);
		_grantRole(RESTAKER_ROLE,     restaker);
		_grantRole(ORACLE_ROLE,       oracle);

		wrappedToken = IWrappedRestakedToken(tokenAddr);
	}

	/* ───────── Modifier: token not paused ───── */
	modifier tokenNotPaused() {
		require(!wrappedToken.paused(), "Vault: token paused");
		_;
	}

	/* ───────── Outbound: send to restaking venue ───── */
	function withdrawForRestaking(uint256 amountWei)
		external
		tokenNotPaused
		onlyRole(RESTAKER_ROLE)
		nonReentrant
	{
		require(address(this).balance - _claimReserveWei >= amountWei,
				"Vault: insufficient liquidity");
		payable(msg.sender).sendValue(amountWei);
	}

	/* ───────── Inbound: restaker return ───── */
	function depositFromRestaker() external payable onlyRole(RESTAKER_ROLE) {}

	/* ───────── Oracle reserve / release ───── */
	function reserveForClaims(uint256 ethWei) external onlyRole(ORACLE_ROLE) {
		_claimReserveWei += ethWei;
	}

	function releaseClaim(address payable user, uint256 ethWei)
		external tokenNotPaused onlyRole(ORACLE_ROLE) nonReentrant
	{
		_claimReserveWei -= ethWei;
		user.sendValue(ethWei);
	}

	/* ───────── Restricted getter for oracle ───── */
	function getClaimReserveWei() external view onlyRole(ORACLE_ROLE) returns (uint256) {
		return _claimReserveWei;
	}

	/* ───────── Admin updates ───── */
	function setRestaker(address oldRestaker, address newRestaker)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		_revokeRole(RESTAKER_ROLE, oldRestaker);
		_grantRole(RESTAKER_ROLE,  newRestaker);
		emit RestakerUpdated(oldRestaker, newRestaker);
	}

	function setOracle(address oldOracle, address newOracle)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		_revokeRole(ORACLE_ROLE, oldOracle);
		_grantRole(ORACLE_ROLE,  newOracle);
		emit OracleUpdated(oldOracle, newOracle);
	}

	/* ───────── Sweep accidental tokens ───── */
	function sweep(address token, address to, uint256 amount)
		external onlyRole(DEFAULT_ADMIN_ROLE)
	{
		if (token == address(0)) {
			payable(to).sendValue(amount);
		} else {
			(bool ok, bytes memory rtn) =
				token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
			require(ok && (rtn.length == 0 || abi.decode(rtn, (bool))), "Vault: sweep token");
		}
	}

	receive() external payable {}
}
