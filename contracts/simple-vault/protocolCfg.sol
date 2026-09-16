// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ProtocolCfg is AccessControl, Pausable {
    bytes32 public constant PROTOCOL_OWNER_ROLE =
        keccak256("PROTOCOL_OWNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    mapping(IERC20 asset => bool isSupported) public isSupportedUnderlyingAsset;
    event UnderlyingAssetAdded(IERC20 indexed asset, address indexed _by);
    event UnderlyingAssetRemoved(IERC20 indexed asset, address indexed _by);

    constructor(
        address _defaultAdmin,
        address _protocolOwner,
        address _pauser
    ) {
        require(
            _defaultAdmin != address(0) &&
                _protocolOwner != address(0) &&
                _pauser != address(0),
            "Invalid zero address"
        );
        _grantRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _grantRole(PROTOCOL_OWNER_ROLE, _protocolOwner);
        _grantRole(PAUSER_ROLE, _pauser);
    }

    function addUnderlyingAsset(IERC20 asset) external {
        require(hasRole(PROTOCOL_OWNER_ROLE, msg.sender), "Not protocol owner");
        require(address(asset) != address(0), "Invalid zero address");
        require(!isSupportedUnderlyingAsset[asset], "Asset already supported");
        isSupportedUnderlyingAsset[asset] = true;
        emit UnderlyingAssetAdded(asset, msg.sender);
    }

    function removeUnderlyingAsset(IERC20 asset) external {
        require(hasRole(PROTOCOL_OWNER_ROLE, msg.sender), "Not protocol owner");
        require(isSupportedUnderlyingAsset[asset], "Asset not supported");
        isSupportedUnderlyingAsset[asset] = false;
        emit UnderlyingAssetRemoved(asset, msg.sender);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
