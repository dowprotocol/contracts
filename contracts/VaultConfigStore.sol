// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DowConfig} from "./DowConfig.sol";
import {Errors} from "./Errors.sol";

contract VaultConfigStore {
    address public owner;
    address public logic;

    string public vaultName;
    mapping(address => bool) public supportedUnderlyingAssets;
    mapping(address => uint256) public underlyingAssetDecimals;
    address[] public underlyingAssetList;
    mapping(address => uint256) public underlyingAssetIndex;
    uint256 public normalizedDecimals;

    uint256 public maxCapacity;
    DowConfig public dowConfig;
    address public vault;

    uint256 public baseApyBps;
    uint256 public firstEpochStartAt;
    uint256 public earlyExitImmediateClaimDelay;
    uint256 public minDepositAmount;
    uint256[6] public earlyExitYieldPenaltyBpsByBand;
    uint256[6] public earlyExitImmediatePrincipalBpsByBand;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Errors.NotAdmin();
        _;
    }

    modifier onlyLogic() {
        if (msg.sender != logic) revert Errors.NotAuthorized();
        _;
    }

    constructor(address _owner) {
        if (_owner == address(0)) revert Errors.InvalidZeroAddress();
        owner = _owner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert Errors.InvalidZeroAddress();
        owner = newOwner;
    }

    function setLogic(address _logic) external onlyOwner {
        if (_logic == address(0)) revert Errors.InvalidZeroAddress();
        logic = _logic;
    }

    function setVaultName(string memory _vaultName) external onlyLogic {
        vaultName = _vaultName;
    }

    function setUnderlyingAssetSupported(
        address asset,
        uint8 decimals,
        bool enabled
    ) external onlyLogic {
        if (asset == address(0)) revert Errors.InvalidZeroAddress();
        _setUnderlyingAssetSupported(asset, decimals, enabled);
    }

    function _setUnderlyingAssetSupported(
        address asset,
        uint8 decimals,
        bool enabled
    ) internal {
        if (enabled) {
            if (underlyingAssetIndex[asset] == 0) {
                underlyingAssetList.push(asset);
                underlyingAssetIndex[asset] = underlyingAssetList.length;
                underlyingAssetDecimals[asset] = decimals;
            }
        } else {
            uint256 indexPlusOne = underlyingAssetIndex[asset];
            if (indexPlusOne == 0) {
                revert Errors.InvalidUnderlyingAsset();
            }
            uint256 index = indexPlusOne - 1;
            uint256 lastIndex = underlyingAssetList.length - 1;
            if (index != lastIndex) {
                address lastAsset = underlyingAssetList[lastIndex];
                underlyingAssetList[index] = lastAsset;
                underlyingAssetIndex[lastAsset] = index + 1;
            }
            underlyingAssetList.pop();
            underlyingAssetIndex[asset] = 0;
            underlyingAssetDecimals[asset] = 0;
        }
        supportedUnderlyingAssets[asset] = enabled;
    }

    function setNormalizedDecimals(uint256 _normalizedDecimals) external onlyLogic {
        normalizedDecimals = _normalizedDecimals;
    }

    function setDowConfig(address _dowConfig) external onlyLogic {
        dowConfig = DowConfig(_dowConfig);
    }

    function setMaxCapacity(uint256 _maxCapacity) external onlyLogic {
        maxCapacity = _maxCapacity;
    }

    function setVault(address _vault) external onlyLogic {
        vault = _vault;
    }

    function setBaseApyBps(uint256 _baseApyBps) external onlyLogic {
        baseApyBps = _baseApyBps;
    }

    function setFirstEpochStartAt(
        uint256 _firstEpochStartAt
    ) external onlyLogic {
        firstEpochStartAt = _firstEpochStartAt;
    }

    function setEarlyExitImmediatePrincipalBpsByBand(
        uint8 band,
        uint256 bps
    ) external onlyLogic {
        earlyExitImmediatePrincipalBpsByBand[band] = bps;
    }

    function setEarlyExitImmediateClaimDelay(
        uint256 _earlyExitImmediateClaimDelay
    ) external onlyLogic {
        earlyExitImmediateClaimDelay = _earlyExitImmediateClaimDelay;
    }

    function setMinDepositAmount(uint256 _minDepositAmount) external onlyLogic {
        minDepositAmount = _minDepositAmount;
    }

    function setEarlyExitYieldPenaltyBpsByBand(
        uint8 band,
        uint256 bps
    ) external onlyLogic {
        earlyExitYieldPenaltyBpsByBand[band] = bps;
    }

    function getUnderlyingAssetList() external view returns (address[] memory) {
        return underlyingAssetList;
    }
}
