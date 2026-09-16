// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Errors} from "./Errors.sol";

contract DowConfig is Ownable, Pausable {
    uint16 private constant DEFAULT_PROTOCOL_FEE_BPS = 50; // 0.5%
    uint16 public protocol_fee_bps;
    address public protocol_fee_receiver;

    mapping(address => bool) public pausers;

    mapping(address => bool) public allowedLiquidityAssets;

    event ProtocolFeeUpdated(uint16 oldFee, uint16 newFee, address by);
    event ProtocolFeeReceiverUpdated(address indexed newReceiver, address by);
    event AllowedLiquidityAssetAdded(address indexed asset, address by);
    event AllowedLiquidityAssetRemoved(address indexed asset, address by);
    event PauserAdded(address indexed pauser, address by);
    event PauserRemoved(address indexed pauser, address by);
    event ProtocolInitialized(address by, address owner);

    modifier onlyPauser() {
        if (!pausers[msg.sender]) revert Errors.NotPauser();
        _;
    }

    constructor(address _owner) Ownable(_owner) {
        protocol_fee_bps = DEFAULT_PROTOCOL_FEE_BPS;
        emit ProtocolInitialized(msg.sender, _owner);
    }

    function setProtocolFeeReceiver(address newReceiver) external onlyOwner {
        if (newReceiver == address(0)) revert Errors.InvalidZeroAddress();
        protocol_fee_receiver = newReceiver;
        emit ProtocolFeeReceiverUpdated(newReceiver, msg.sender);
    }

    function setProtocolFee(uint16 newFee) external onlyOwner {
        if (newFee > 10000) revert Errors.InvalidFee();
        uint16 oldFee = protocol_fee_bps;
        protocol_fee_bps = newFee;
        emit ProtocolFeeUpdated(oldFee, newFee, msg.sender);
    }

    function setLiquidityAsset(address asset, bool valid) external onlyOwner {
        if (asset == address(0)) revert Errors.InvalidZeroAddress();
        if (valid) {
            allowedLiquidityAssets[asset] = true;
            emit AllowedLiquidityAssetAdded(asset, msg.sender);
        } else {
            allowedLiquidityAssets[asset] = false;
            emit AllowedLiquidityAssetRemoved(asset, msg.sender);
        }
    }

    function addPauser(address pauser) external onlyOwner {
        pausers[pauser] = true;
        emit PauserAdded(pauser, msg.sender);
    }

    function removePauser(address pauser) external onlyOwner {
        pausers[pauser] = false;
        emit PauserRemoved(pauser, msg.sender);
    }

    function pause() external onlyPauser {
        _pause();
    }

    function unpause() external onlyPauser {
        _unpause();
    }

    function isAllowedLiquidityAsset(
        address asset
    ) external view returns (bool) {
        return allowedLiquidityAssets[asset];
    }
}
