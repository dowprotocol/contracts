// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Errors} from "./Errors.sol";
import {DowConfig} from "./DowConfig.sol";
import {VaultConfigStore} from "./VaultConfigStore.sol";

interface IVault {
    function isVaultOpen() external view returns (bool);
}

contract VaultConfig is AccessControl {
    VaultConfigStore public store;
    bool public initialized;

    bytes32 public constant STRATEGY_MANAGER_ROLE = keccak256("STRATEGY_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_REDEEM_REQUEST_ROLE = keccak256("EMERGENCY_REDEEM_REQUEST_ROLE");
    bytes32 public constant EMERGENCY_REDEEM_REVIEW_ROLE = keccak256("EMERGENCY_REDEEM_REVIEW_ROLE");

    event VaultNameUpdated(
        string indexed oldVaultName,
        string indexed newVaultName,
        address by
    );
    event BaseApyUpdated(uint256 oldApyBps, uint256 newApyBps, address by);
    event MaxCapacityUpdated(
        uint256 oldMaxCapacity,
        uint256 newMaxCapacity,
        address by
    );
    event FirstEpochStartUpdated(
        uint256 oldStartAt,
        uint256 newStartAt,
        address by
    );
    event EarlyExitImmediatePrincipalBandUpdated(
        uint8 indexed band,
        uint256 oldBps,
        uint256 newBps,
        address by
    );
    event EarlyExitImmediateClaimDelayUpdated(
        uint256 oldValue,
        uint256 newValue,
        address by
    );
    event EarlyExitYieldPenaltyBandUpdated(
        uint8 indexed band,
        uint256 oldValue,
        uint256 newValue,
        address by
    );
    event VaultUpdated(
        address indexed oldVault,
        address indexed newVault,
        address by
    );
    event UnderlyingAssetSupportUpdated(
        address indexed asset,
        bool enabled,
        address by
    );

    constructor(address storeAddress, address admin) {
        if (storeAddress == address(0) || admin == address(0)) {
            revert Errors.InvalidZeroAddress();
        }
        store = VaultConfigStore(storeAddress);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function initialize(
        string memory _vaultName,
        address _underlyingAsset,
        uint256 _vaultMaxCap,
        uint256 _firstEpochStartAt,
        address _dowConfig,
        uint256 _minDepositAmount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address[] memory assets = new address[](1);
        assets[0] = _underlyingAsset;
        _initialize(
            _vaultName,
            assets,
            _vaultMaxCap,
            _firstEpochStartAt,
            _dowConfig,
            _minDepositAmount
        );
    }

    function initializeWithUnderlyingAssets(
        string memory _vaultName,
        address[] memory _underlyingAssets,
        uint256 _vaultMaxCap,
        uint256 _firstEpochStartAt,
        address _dowConfig,
        uint256 _minDepositAmount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _initialize(
            _vaultName,
            _underlyingAssets,
            _vaultMaxCap,
            _firstEpochStartAt,
            _dowConfig,
            _minDepositAmount
        );
    }

    function _initialize(
        string memory _vaultName,
        address[] memory _underlyingAssets,
        uint256 _vaultMaxCap,
        uint256 _firstEpochStartAt,
        address _dowConfig,
        uint256 _minDepositAmount
    ) internal {
        if (initialized) revert Errors.VaultAlreadyInitialized();
        if (_dowConfig == address(0)) {
            revert Errors.InvalidZeroAddress();
        }
        if (_underlyingAssets.length == 0) {
            revert Errors.InvalidZeroAddress();
        }
        if (_vaultMaxCap == 0) revert Errors.InvalidZeroAmount();
        if (_firstEpochStartAt <= block.timestamp) {
            revert Errors.InvalidEpochStartTime();
        }
        store.setDowConfig(_dowConfig);
        store.setNormalizedDecimals(18);
        _setUnderlyingAssets(_underlyingAssets, true);
        store.setVaultName(_vaultName);
        store.setMaxCapacity(_vaultMaxCap);

        store.setBaseApyBps(1200);
        store.setFirstEpochStartAt(_firstEpochStartAt);
        store.setEarlyExitImmediatePrincipalBpsByBand(0, 7000);
        store.setEarlyExitImmediatePrincipalBpsByBand(1, 7000);
        store.setEarlyExitImmediatePrincipalBpsByBand(2, 7500);
        store.setEarlyExitImmediatePrincipalBpsByBand(3, 8500);
        store.setEarlyExitImmediatePrincipalBpsByBand(4, 9000);
        store.setEarlyExitImmediatePrincipalBpsByBand(5, 9000);
        store.setEarlyExitImmediateClaimDelay(0);

        store.setEarlyExitYieldPenaltyBpsByBand(0, 0);
        store.setEarlyExitYieldPenaltyBpsByBand(1, 2000);
        store.setEarlyExitYieldPenaltyBpsByBand(2, 3000);
        store.setEarlyExitYieldPenaltyBpsByBand(3, 5000);
        store.setEarlyExitYieldPenaltyBpsByBand(4, 7000);
        store.setEarlyExitYieldPenaltyBpsByBand(5, 9000);
        store.setMinDepositAmount(_minDepositAmount);

        initialized = true;
    }

    function _setUnderlyingAssets(
        address[] memory _underlyingAssets,
        bool enabled
    ) internal {
        DowConfig dc = store.dowConfig();

        for (uint256 i = 0; i < _underlyingAssets.length; i++) {
            uint8 decimals = IERC20Metadata(_underlyingAssets[i]).decimals();
            if(decimals > store.normalizedDecimals())
                revert Errors.InvalidUnderlyingDecimals();
            if (_underlyingAssets[i] == address(0))
                revert Errors.InvalidZeroAddress();
            if (enabled && !dc.isAllowedLiquidityAsset(_underlyingAssets[i])) {
                revert Errors.InvalidUnderlyingAsset();
            }
            store.setUnderlyingAssetSupported(_underlyingAssets[i], decimals, enabled);
        }
    }

    function vaultName() external view returns (string memory) {
        return store.vaultName();
    }

    function isUnderlyingAssetSupported(
        address asset
    ) external view returns (bool) {
        return store.supportedUnderlyingAssets(asset);
    }

    function underlyingAssetDecimals(
        address asset
    ) external view returns (uint256) {
        return store.underlyingAssetDecimals(asset);
    }

    function normalizedDecimals() external view returns (uint256) {
        return store.normalizedDecimals();
    }

    function underlyingAssetList() external view returns (address[] memory) {
        return store.getUnderlyingAssetList();
    }

    function maxCapacity() external view returns (uint256) {
        return store.maxCapacity();
    }

    function dowConfig() public view returns (DowConfig) {
        return store.dowConfig();
    }

    function vault() external view returns (address) {
        return store.vault();
    }

    function strategyManager(address account) public view returns (bool) {
        if (!hasRole(STRATEGY_MANAGER_ROLE, account)) {
            return false;
        }
        return true;
    }

    function emergencyRedeemRequester(address account) public view returns (bool) {
        if (!hasRole(EMERGENCY_REDEEM_REQUEST_ROLE, account)) {
            return false;
        }
        return true;
    } 
    function emergencyRedeemReviewer(address account) public view returns (bool) {
        if (!hasRole(EMERGENCY_REDEEM_REVIEW_ROLE, account)) {
            return false;
        }
        return true;
    }

    function baseApyBps() external view returns (uint256) {
        return store.baseApyBps();
    }

    function firstEpochStartAt() external view returns (uint256) {
        return store.firstEpochStartAt();
    }

    function earlyExitImmediatePrincipalBpsByBand(
        uint8 band
    ) external view returns (uint256) {
        if (band >= 6) revert Errors.InvalidDuration();
        return store.earlyExitImmediatePrincipalBpsByBand(band);
    }

    function earlyExitImmediatePrincipalBpsByStakedDays(
        uint256 stakedDays
    ) public view returns (uint256) {
        uint8 band = _earlyExitYieldPenaltyBand(stakedDays);
        return store.earlyExitImmediatePrincipalBpsByBand(band);
    }

    function earlyExitImmediateClaimDelay() external view returns (uint256) {
        return store.earlyExitImmediateClaimDelay();
    }

    function minDepositAmount() external view returns (uint256) {
        return store.minDepositAmount();
    }

    function earlyExitYieldPenaltyBpsByBand(
        uint8 band
    ) external view returns (uint256) {
        if (band >= 6) revert Errors.InvalidDuration();
        uint256 coefficientBps = store.earlyExitYieldPenaltyBpsByBand(band);
        return 10000 - coefficientBps;
    }

    function earlyExitYieldPenaltyBpsByStakedDays(
        uint256 stakedDays
    ) public view returns (uint256) {
        uint8 band = _earlyExitYieldPenaltyBand(stakedDays);
        uint256 coefficientBps = store.earlyExitYieldPenaltyBpsByBand(band);
        return 10000 - coefficientBps;
    }

    function earlyExitYieldCoefficientBpsByBand(
        uint8 band
    ) external view returns (uint256) {
        if (band >= 6) revert Errors.InvalidDuration();
        return store.earlyExitYieldPenaltyBpsByBand(band);
    }

    function earlyExitYieldCoefficientBpsByStakedDays(
        uint256 stakedDays
    ) public view returns (uint256) {
        uint8 band = _earlyExitYieldPenaltyBand(stakedDays);
        return store.earlyExitYieldPenaltyBpsByBand(band);
    }

    function onlyVaultOwner(address account) public view virtual {
        if (!hasRole(DEFAULT_ADMIN_ROLE, account)) {
            revert Errors.NotVaultOwner();
        }
    }

    function onlyProtocolAndVaultOn() external view virtual {
        if (dowConfig().paused()) revert Errors.ProtocolPaused();
        address vaultAddress = store.vault();
        if (vaultAddress == address(0)) revert Errors.VaultClosed();
        if (!IVault(vaultAddress).isVaultOpen()) revert Errors.VaultClosed();
    }

    function setVault(address _vault) external virtual {
        onlyVaultOwner(msg.sender);
        if (_vault == address(0)) revert Errors.InvalidZeroAddress();
        address oldVault = store.vault();
        store.setVault(_vault);
        emit VaultUpdated(oldVault, _vault, msg.sender);
    }

    function setVaultName(string memory _vaultName) external virtual {
        onlyVaultOwner(msg.sender);
        string memory oldVaultName = store.vaultName();
        store.setVaultName(_vaultName);
        emit VaultNameUpdated(oldVaultName, _vaultName, msg.sender);
    }

    function setUnderlyingAssetSupported(
        address asset,
        bool enabled
    ) external virtual {
        onlyVaultOwner(msg.sender);
        address[] memory assets = new address[](1);
        assets[0] = asset;
        _setUnderlyingAssets(assets, enabled);
        emit UnderlyingAssetSupportUpdated(asset, enabled, msg.sender);
    }

    function setBaseApy(uint256 _baseApyBps) external virtual {
        onlyVaultOwner(msg.sender);
        if (_baseApyBps > 5000) revert Errors.InvalidAPY();
        uint256 oldApyBps = store.baseApyBps();
        store.setBaseApyBps(_baseApyBps);
        emit BaseApyUpdated(oldApyBps, _baseApyBps, msg.sender);
    }

    function setMaxCapacity(uint256 _maxCapacity) external virtual {
        onlyVaultOwner(msg.sender);
        if (_maxCapacity == 0) revert Errors.InvalidZeroAmount();
        uint256 oldMaxCapacity = store.maxCapacity();
        store.setMaxCapacity(_maxCapacity);
        emit MaxCapacityUpdated(oldMaxCapacity, _maxCapacity, msg.sender);
    }

   

    function setFirstEpochStartAt(uint256 _firstEpochStartAt) external virtual {
        onlyVaultOwner(msg.sender);
        if (_firstEpochStartAt == 0) revert Errors.InvalidDuration();
        if (_firstEpochStartAt <= block.timestamp) {
            revert Errors.InvalidEpochStartTime();
        }
        uint256 oldStart = store.firstEpochStartAt();
        store.setFirstEpochStartAt(_firstEpochStartAt);
        emit FirstEpochStartUpdated(oldStart, _firstEpochStartAt, msg.sender);
    }

    function setEarlyExitImmediatePrincipalBand(
        uint8 band,
        uint256 bps
    ) external virtual {
        onlyVaultOwner(msg.sender);
        if (band >= 6) revert Errors.InvalidDuration();
        if (bps > 10000) revert Errors.InvalidFee();
        uint256 oldBps = store.earlyExitImmediatePrincipalBpsByBand(band);
        store.setEarlyExitImmediatePrincipalBpsByBand(band, bps);
        emit EarlyExitImmediatePrincipalBandUpdated(
            band,
            oldBps,
            bps,
            msg.sender
        );
    }

    function setEarlyExitImmediateClaimDelay(
        uint256 _earlyExitImmediateClaimDelay
    ) external virtual {
        onlyVaultOwner(msg.sender);
        uint256 oldValue = store.earlyExitImmediateClaimDelay();
        store.setEarlyExitImmediateClaimDelay(_earlyExitImmediateClaimDelay);
        emit EarlyExitImmediateClaimDelayUpdated(
            oldValue,
            _earlyExitImmediateClaimDelay,
            msg.sender
        );
    }

    function setMinDepositAmount(uint256 _minDepositAmount) external virtual {
        onlyVaultOwner(msg.sender);
        store.setMinDepositAmount(_minDepositAmount);
    }

    function setEarlyExitYieldPenaltyBand(
        uint8 band,
        uint256 bps
    ) external virtual {
        onlyVaultOwner(msg.sender);
        if (band >= 6) revert Errors.InvalidDuration();
        if (bps > 10000) revert Errors.InvalidFee();
        uint256 oldCoefficient = store.earlyExitYieldPenaltyBpsByBand(band);
        uint256 oldPenalty = 10000 - oldCoefficient;
        uint256 coefficient = 10000 - bps;
        store.setEarlyExitYieldPenaltyBpsByBand(band, coefficient);
        emit EarlyExitYieldPenaltyBandUpdated(
            band,
            oldPenalty,
            bps,
            msg.sender
        );
    }

    function _earlyExitYieldPenaltyBand(
        uint256 stakedDays
    ) internal pure returns (uint8) {
        if (stakedDays <= 14) return 0;
        if (stakedDays <= 29) return 1;
        if (stakedDays <= 44) return 2;
        if (stakedDays <= 59) return 3;
        if (stakedDays <= 74) return 4;
        return 5;
    }
}
