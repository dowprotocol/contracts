// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import "./protocolCfg.sol";
import "./Vault.sol";
contract VaultFactory is AccessControl {
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 public constant POOL_OPERATOR_ROLE = keccak256("POOL_OPERATOR_ROLE");
    ProtocolCfg public  protocolCfg;
    event VaultCreated(address indexed vault, address indexed deployedBy, address indexed defaultAdmin, uint256 depositDeadline, IERC20[] underlyingAssets, IERC20 shareToken);
    event ProtocolCfgUpdated(address indexed protocolCfg,address indexed _by);
    constructor(address _defaultAdmin,address _owner,address _protocolCfg) {
        require(_defaultAdmin != address(0) && _owner != address(0) && _protocolCfg != address(0), "Invalid zero address");
        protocolCfg = ProtocolCfg(_protocolCfg);
        _grantRole(OWNER_ROLE,_owner);
        _grantRole(DEFAULT_ADMIN_ROLE,_defaultAdmin);
    }
    function setProtocolCfg(address _protocolCfg) external {
        require(hasRole(OWNER_ROLE, msg.sender), "Not owner");
        require(_protocolCfg != address(0), "Invalid zero address");
        protocolCfg = ProtocolCfg(_protocolCfg);
        emit ProtocolCfgUpdated(address(protocolCfg), msg.sender);
    }
    function createVault(address _defaultAdmin,address _admin,uint256 _miniDepositAmt,uint256 _maxCapacity,uint256 _stakingDays,uint256 _depositDeadline,IERC20[] memory _underlyingAssets,IERC20 _shareToken) external {
        require(address(protocolCfg) != address(0), "Protocol cfg not set");
        require(!protocolCfg.paused(),"Protocol has been paused");
        require(hasRole(POOL_OPERATOR_ROLE, msg.sender), "Not pool operator");
        Vault vault = new Vault(_defaultAdmin, _admin,_miniDepositAmt, _maxCapacity, _stakingDays, _depositDeadline, _underlyingAssets, _shareToken);
        emit VaultCreated(address(vault), msg.sender, _defaultAdmin, _depositDeadline, _underlyingAssets, _shareToken);
    }
}
