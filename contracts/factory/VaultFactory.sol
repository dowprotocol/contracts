// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Errors} from "../Errors.sol";

interface IVaultConfigArtifactsDeployer {
    function deploy(
        address factoryAdmin
    ) external returns (address vaultConfigStore, address vaultConfig);
}

interface IVaultStoreDeployer {
    function deploy(address factoryAdmin) external returns (address vaultStore);
}

interface IVaultLogicDeployer {
    function deploy(
        address vaultStore,
        address vaultConfig
    ) external returns (address vault);
}

interface IRedeemVaultDeployer {
    function deploy(
        address vault,
        address vaultStore,
        address vaultConfig
    ) external returns (address redeemVault);
}

interface IEpochArtifactsDeployer {
    function deploy(
        address factoryAdmin
    ) external returns (address epochManagerStore, address epochManager);
}

interface IVaultConfigStoreRef {
    function setLogic(address _logic) external;

    function transferOwnership(address newOwner) external;
}

interface IVaultConfigRef {
    function initialize(
        string memory _vaultName,
        address _underlyingAsset,
        uint256 _vaultMaxCap,
        uint256 _firstEpochStartAt,
        address _dowConfig,
        uint256 _minDepositAmount
    ) external;

    function initializeWithUnderlyingAssets(
        string memory _vaultName,
        address[] memory _underlyingAssets,
        uint256 _vaultMaxCap,
        uint256 _firstEpochStartAt,
        address _dowConfig,
        uint256 _minDepositAmount
    ) external;

    function setVault(address _vault) external;

    function setStrategyManager(address _strategyManager) external;

    function setEmergencyRedeemManager(address _emergencyRedeemManager) external;

    function setMaxCapacity(uint256 _maxCap) external;

    function grantRole(bytes32 role, address account) external;

    function revokeRole(bytes32 role, address account) external;
}

interface IVaultStoreRef {
    function setLogic(address _logic) external;

    function setAuthorizedLogic(address _logic, bool authorized) external;

    function transferOwnership(address newOwner) external;
}

interface IVaultRef {

    function setDrtRedeemVault(address redeemVault) external;

    function setActivityLogger(address _activityLogger) external;

    function setEpochManager(address _epochManager) external;

    function syncStoreCore() external;
}

interface IRedeemVaultRef {
    function syncStoreCore() external;

    function setEarlyWithdrawReview(address reviewAddress) external;
}

interface IEarlyWithdrawReviewRef {
    function setVaultApproved(address vault, bool approved) external;
}

interface IEpochManagerStoreRef {
    function setLogic(address _logic) external;

    function transferOwnership(address newOwner) external;
}

interface IEpochManagerRef {
    function authorizeVault(address vault, bool authorized) external;

    function setAdmin(address newAdmin) external;
}

interface IVaultActivityLoggerRef {
    function authorizeVault(address vault, bool authorized) external;
}

contract VaultFactory is AccessControl, ReentrancyGuard {
    enum VaultStatus {
        Configured,
        CoreDeployed,
        Created,
        Initialized
    }

    struct VaultRecord {
        uint256 vaultId;
        address vaultAddress;
        string vaultName;
        address vaultConfigStoreAddress;
        address vaultConfigAddress;
        address vaultStoreAddress;
        address redeemVaultAddress;
        address epochManagerStoreAddress;
        address epochManagerAddress;
        VaultStatus status;
        address deployer;
        uint256 deployedAt;
    }

    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

    address public protocolCfgAddress;
    uint256 public VaultId;

    address public activityLogger;

    address public vaultConfigArtifactsDeployer;
    address public vaultStoreDeployer;
    address public vaultLogicDeployer;
    address public redeemVaultDeployer;
    address public epochArtifactsDeployer;
    address public earlyWithdrawReviewContract;

    mapping(uint256 => VaultRecord) public vaultRecords;
    mapping(uint256 => address) public redeemVaultByVaultId;
    uint256[] public vaultIds;
    mapping(address => uint256[]) public deployerVaultIds;

    event DeployerAdded(address indexed deployer);
    event DeployerRemoved(address indexed deployer);
    event VaultCreated(
        uint256 indexed vaultId,
        address indexed vaultAddress,
        string vaultName,
        address vaultStore,
        address vaultCfg,
        address redeemVault,
        address epochManager
    );
    event VaultDeploymentStarted(
        uint256 indexed vaultId,
        string vaultName,
        address vaultConfigStore,
        address vaultConfig
    );
    event VaultCoreDeployed(
        uint256 indexed vaultId,
        address indexed vaultAddress,
        address vaultStore,
        address redeemVault
    );
    event ActivityLoggerUpdated(
        address indexed oldActivityLogger,
        address indexed newActivityLogger
    );
    event VaultFactoryDeployersUpdated(address indexed by);
    event ProtocolCfgAddressUpdated(
        address indexed oldAddress,
        address indexed newAddress
    );
    event EarlyWithdrawReviewContractUpdated(
        address indexed oldReview,
        address indexed newReview
    );
    event VaultInitialized(
        uint256 indexed vaultId,
        address indexed vaultOwner,
        address indexed initializedBy
    );

    constructor(address _protocolCfgAddress) {
        _notZeroAddress(_protocolCfgAddress);
        VaultId = 0;
        protocolCfgAddress = _protocolCfgAddress;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DEPLOYER_ROLE, msg.sender);
    }

    function _notZeroAddress(address account) internal pure virtual {
        if (account == address(0)) revert Errors.InvalidZeroAddress();
    }

    function _onlyFactoryAdmin(address account) internal view virtual {
        if (!hasRole(DEFAULT_ADMIN_ROLE, account)) {
            revert Errors.NotAdmin();
        }
    }

    function _requireDeployersConfigured() internal view {
        if (
            vaultConfigArtifactsDeployer == address(0) ||
            vaultStoreDeployer == address(0) ||
            vaultLogicDeployer == address(0) ||
            redeemVaultDeployer == address(0) ||
            epochArtifactsDeployer == address(0) ||
            earlyWithdrawReviewContract == address(0)
        ) {
            revert Errors.InvalidZeroAddress();
        }
    }

    function addDeployer(
        address deployer
    ) external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(DEPLOYER_ROLE, deployer);
        emit DeployerAdded(deployer);
    }

    function removeDeployer(
        address deployer
    ) external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(DEPLOYER_ROLE, deployer);
        emit DeployerRemoved(deployer);
    }

    function configureDeployers(
        address _vaultConfigArtifactsDeployer,
        address _vaultStoreDeployer,
        address _vaultLogicDeployer,
        address _redeemVaultDeployer,
        address _epochArtifactsDeployer
    ) external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        _setVaultConfigArtifactsDeployer(_vaultConfigArtifactsDeployer);
        _setVaultStoreDeployer(_vaultStoreDeployer);
        _setVaultLogicDeployer(_vaultLogicDeployer);
        _setRedeemVaultDeployer(_redeemVaultDeployer);
        _setEpochArtifactsDeployer(_epochArtifactsDeployer);
        emit VaultFactoryDeployersUpdated(msg.sender);
    }

    function setVaultConfigArtifactsDeployer(
        address _vaultConfigArtifactsDeployer
    ) external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        _setVaultConfigArtifactsDeployer(_vaultConfigArtifactsDeployer);
        emit VaultFactoryDeployersUpdated(msg.sender);
    }

    function setVaultStoreDeployer(
        address _vaultStoreDeployer
    ) external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        _setVaultStoreDeployer(_vaultStoreDeployer);
        emit VaultFactoryDeployersUpdated(msg.sender);
    }

    function setVaultLogicDeployer(
        address _vaultLogicDeployer
    ) external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        _setVaultLogicDeployer(_vaultLogicDeployer);
        emit VaultFactoryDeployersUpdated(msg.sender);
    }

    function setRedeemVaultDeployer(
        address _redeemVaultDeployer
    ) external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRedeemVaultDeployer(_redeemVaultDeployer);
        emit VaultFactoryDeployersUpdated(msg.sender);
    }

    function setEpochArtifactsDeployer(
        address _epochArtifactsDeployer
    ) external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        _setEpochArtifactsDeployer(_epochArtifactsDeployer);
        emit VaultFactoryDeployersUpdated(msg.sender);
    }

    function setEarlyWithdrawReviewContract(
        address reviewAddress
    ) external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldReview = earlyWithdrawReviewContract;
        _notZeroAddress(reviewAddress);
        earlyWithdrawReviewContract = reviewAddress;
        emit EarlyWithdrawReviewContractUpdated(oldReview, reviewAddress);
    }

    function _setVaultConfigArtifactsDeployer(
        address _vaultConfigArtifactsDeployer
    ) internal {
        _notZeroAddress(_vaultConfigArtifactsDeployer);
        vaultConfigArtifactsDeployer = _vaultConfigArtifactsDeployer;
    }

    function _setVaultStoreDeployer(address _vaultStoreDeployer) internal {
        _notZeroAddress(_vaultStoreDeployer);
        vaultStoreDeployer = _vaultStoreDeployer;
    }

    function _setVaultLogicDeployer(address _vaultLogicDeployer) internal {
        _notZeroAddress(_vaultLogicDeployer);
        vaultLogicDeployer = _vaultLogicDeployer;
    }

    function _setRedeemVaultDeployer(address _redeemVaultDeployer) internal {
        _notZeroAddress(_redeemVaultDeployer);
        redeemVaultDeployer = _redeemVaultDeployer;
    }

    function _setEpochArtifactsDeployer(address _epochArtifactsDeployer) internal {
        _notZeroAddress(_epochArtifactsDeployer);
        epochArtifactsDeployer = _epochArtifactsDeployer;
    }

    // Step 1: Deploy and initialize the vault config artifacts only.
    function deployVault(
        string memory vaultName,
        address underlyingAsset,
        uint256 _firstEpochStartAt,
        uint256 vaultMaxCap,
        uint256 minDepositAmount
    ) external virtual nonReentrant onlyRole(DEPLOYER_ROLE) returns (uint256 vaultId) {
        address[] memory underlyingAssets = new address[](1);
        underlyingAssets[0] = underlyingAsset;
        if (_firstEpochStartAt <= block.timestamp)
            revert Errors.InvalidEpochStartTime();
        return _deployVaultConfig(
            vaultName,
            underlyingAssets,
            _firstEpochStartAt,
            vaultMaxCap,
            minDepositAmount
        );
    }

    // Step 2: Deploy the vault logic stack. Kept separate from deployVault to
    // stay below the BSC mainnet per-transaction gas cap.
    function deployVaultCore(
        uint256 vaultId_
    ) external virtual nonReentrant onlyRole(DEPLOYER_ROLE) {
        _checkVaultIdValidity(vaultId_);
        VaultRecord storage r = vaultRecords[vaultId_];
        if (r.status != VaultStatus.Configured) revert Errors.InvalidVaultStatus();
        if (msg.sender != r.deployer) revert Errors.NotAuthorized();

        address vaultStoreAddress = IVaultStoreDeployer(vaultStoreDeployer)
            .deploy(address(this));
        address vaultAddress = IVaultLogicDeployer(vaultLogicDeployer).deploy(
            vaultStoreAddress,
            r.vaultConfigAddress
        );
        IVaultStoreRef(vaultStoreAddress).setLogic(vaultAddress);

        address redeemVaultAddress = IRedeemVaultDeployer(redeemVaultDeployer)
            .deploy(vaultAddress, vaultStoreAddress, r.vaultConfigAddress);

        r.vaultStoreAddress = vaultStoreAddress;
        r.vaultAddress = vaultAddress;
        r.redeemVaultAddress = redeemVaultAddress;
        r.status = VaultStatus.CoreDeployed;

        emit VaultCoreDeployed(
            vaultId_,
            vaultAddress,
            vaultStoreAddress,
            redeemVaultAddress
        );
    }

    // Step 3: Deploy the epoch manager stack and mark the vault ready for
    // initializeVault().
    function deployVaultEpoch(
        uint256 vaultId_
    ) external virtual nonReentrant onlyRole(DEPLOYER_ROLE) {
        _checkVaultIdValidity(vaultId_);
        VaultRecord storage r = vaultRecords[vaultId_];
        if (r.status != VaultStatus.CoreDeployed) revert Errors.InvalidVaultStatus();
        if (msg.sender != r.deployer) revert Errors.NotAuthorized();

        (
            address epochManagerStoreAddress,
            address epochManagerAddress
        ) = IEpochArtifactsDeployer(epochArtifactsDeployer).deploy(address(this));

        r.epochManagerStoreAddress = epochManagerStoreAddress;
        r.epochManagerAddress = epochManagerAddress;
        r.status = VaultStatus.Created;
        redeemVaultByVaultId[vaultId_] = r.redeemVaultAddress;

        emit VaultCreated(
            vaultId_,
            r.vaultAddress,
            r.vaultName,
            r.vaultStoreAddress,
            r.vaultConfigAddress,
            r.redeemVaultAddress,
            epochManagerAddress
        );
    }

    // Step 4: Wire references, authorize on logger/review, and transfer ownership.
    function initializeVault(
        uint256 vaultId_,
        address vaultOwner
    ) external virtual nonReentrant onlyRole(DEPLOYER_ROLE) {
        _checkVaultIdValidity(vaultId_);
        VaultRecord memory r = vaultRecords[vaultId_];
        if (r.status != VaultStatus.Created) revert Errors.InvalidVaultStatus();
        if (msg.sender != r.deployer) revert Errors.NotAuthorized();
        _notZeroAddress(vaultOwner);

        IVaultStoreRef(r.vaultStoreAddress).setAuthorizedLogic(r.redeemVaultAddress, true);
        IVaultRef(r.vaultAddress).syncStoreCore();
        IRedeemVaultRef(r.redeemVaultAddress).syncStoreCore();
        IVaultConfigRef(r.vaultConfigAddress).setVault(r.vaultAddress);
        IVaultRef(r.vaultAddress).setDrtRedeemVault(r.redeemVaultAddress);

        IEpochManagerStoreRef(r.epochManagerStoreAddress).setLogic(r.epochManagerAddress);
        IEpochManagerRef(r.epochManagerAddress).authorizeVault(r.vaultAddress, true);
        IEpochManagerRef(r.epochManagerAddress).authorizeVault(r.redeemVaultAddress, true);
        IVaultRef(r.vaultAddress).setEpochManager(r.epochManagerAddress);

        address reviewAddress = earlyWithdrawReviewContract;
        IEarlyWithdrawReviewRef(reviewAddress).setVaultApproved(
            r.redeemVaultAddress,
            true
        );
        IRedeemVaultRef(r.redeemVaultAddress).setEarlyWithdrawReview(reviewAddress);

        if (activityLogger != address(0)) {
            IVaultActivityLoggerRef(activityLogger).authorizeVault(
                r.vaultAddress,
                true
            );
            IVaultActivityLoggerRef(activityLogger).authorizeVault(
                r.redeemVaultAddress,
                true
            );
            IVaultRef(r.vaultAddress).setActivityLogger(activityLogger);
        }

        IVaultConfigRef(r.vaultConfigAddress).grantRole(
            DEFAULT_ADMIN_ROLE,
            vaultOwner
        );
        IVaultConfigRef(r.vaultConfigAddress).revokeRole(
            DEFAULT_ADMIN_ROLE,
            address(this)
        );
        IVaultConfigStoreRef(r.vaultConfigStoreAddress).transferOwnership(
            vaultOwner
        );
        IVaultStoreRef(r.vaultStoreAddress).transferOwnership(vaultOwner);
        IEpochManagerStoreRef(r.epochManagerStoreAddress).transferOwnership(
            vaultOwner
        );
        IEpochManagerRef(r.epochManagerAddress).setAdmin(vaultOwner);

        vaultRecords[vaultId_].status = VaultStatus.Initialized;

        emit VaultInitialized(vaultId_, vaultOwner, msg.sender);
    }

    function _deployVaultConfig(
        string memory vaultName,
        address[] memory underlyingAssets,
        uint256 _firstEpochStartAt,
        uint256 vaultMaxCap,
        uint256 minDepositAmount
    ) internal returns (uint256 vaultId) {
        _requireDeployersConfigured();
        if (underlyingAssets.length == 0) revert Errors.InvalidZeroAddress();

        (
            address vaultConfigStoreAddress,
            address vaultConfigAddress
        ) = IVaultConfigArtifactsDeployer(vaultConfigArtifactsDeployer).deploy(
                address(this)
            );
        IVaultConfigStoreRef(vaultConfigStoreAddress).setLogic(vaultConfigAddress);
        IVaultConfigRef(vaultConfigAddress).initializeWithUnderlyingAssets(
            vaultName,
            underlyingAssets,
            vaultMaxCap,
            _firstEpochStartAt,
            protocolCfgAddress,
            minDepositAmount
        );

        vaultId = _registerVaultConfig(
            vaultConfigStoreAddress,
            vaultConfigAddress,
            vaultName
        );
    }

    function setActivityLogger(
        address _activityLogger
    ) external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        _notZeroAddress(_activityLogger);
        address oldActivityLogger = activityLogger;
        activityLogger = _activityLogger;

        emit ActivityLoggerUpdated(oldActivityLogger, _activityLogger);
    }

    function disableActivityLogger() external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldActivityLogger = activityLogger;
        activityLogger = address(0);
        emit ActivityLoggerUpdated(oldActivityLogger, address(0));
    }

    function setProtocolCfgAddress(
        address _protocolCfgAddress
    ) external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        _notZeroAddress(_protocolCfgAddress);
        address old = protocolCfgAddress;
        protocolCfgAddress = _protocolCfgAddress;
        emit ProtocolCfgAddressUpdated(old, _protocolCfgAddress);
    }

    function _registerVaultConfig(
        address vaultConfigStoreAddress,
        address vaultConfigAddress,
        string memory vaultName
    ) private returns (uint256 vaultId) {
        VaultId = VaultId + 1;
        vaultId = VaultId;
        vaultRecords[VaultId] = VaultRecord({
            vaultId: VaultId,
            vaultAddress: address(0),
            vaultName: vaultName,
            vaultConfigStoreAddress: vaultConfigStoreAddress,
            vaultConfigAddress: vaultConfigAddress,
            vaultStoreAddress: address(0),
            redeemVaultAddress: address(0),
            epochManagerStoreAddress: address(0),
            epochManagerAddress: address(0),
            status: VaultStatus.Configured,
            deployer: msg.sender,
            deployedAt: block.timestamp
        });
        vaultIds.push(VaultId);
        deployerVaultIds[msg.sender].push(VaultId);
        emit VaultDeploymentStarted(
            VaultId,
            vaultName,
            vaultConfigStoreAddress,
            vaultConfigAddress
        );
    }

    function checkVault(
        uint256 vaultId_
    ) external view virtual returns (VaultRecord memory) {
        _checkVaultIdValidity(vaultId_);
        return vaultRecords[vaultId_];
    }

    function getDeployedVaultCount() external view virtual returns (uint256) {
        return VaultId;
    }

    function getVaults() external view virtual returns (VaultRecord[] memory) {
        VaultRecord[] memory _vaultRecords = new VaultRecord[](VaultId);
        for (uint256 i = 1; i <= VaultId; i++) {
            _vaultRecords[i - 1] = vaultRecords[i];
        }
        return _vaultRecords;
    }

    function getVaultsPaged(
        uint256 page,
        uint256 pageSize
    ) external view virtual returns (VaultRecord[] memory) {
        if (page == 0 || pageSize == 0) {
            return new VaultRecord[](0);
        }
        uint256 total = vaultIds.length;
        uint256 startIndex = (page - 1) * pageSize;
        if (startIndex >= total) {
            return new VaultRecord[](0);
        }
        uint256 endIndex = startIndex + pageSize;
        if (endIndex > total) {
            endIndex = total;
        }
        VaultRecord[] memory _vaultRecords = new VaultRecord[](
            endIndex - startIndex
        );
        for (uint256 i = startIndex; i < endIndex; i++) {
            _vaultRecords[i - startIndex] = vaultRecords[vaultIds[i]];
        }
        return _vaultRecords;
    }

    function getDeployerVaultCount(
        address deployer
    ) external view virtual returns (uint256) {
        return deployerVaultIds[deployer].length;
    }

    function getVaultsByDeployer(
        address deployer
    ) external view virtual returns (VaultRecord[] memory) {
        uint256[] memory _vaultIds = deployerVaultIds[deployer];
        VaultRecord[] memory _vaultRecords = new VaultRecord[](_vaultIds.length);
        for (uint256 i = 0; i < _vaultIds.length; i++) {
            _vaultRecords[i] = vaultRecords[_vaultIds[i]];
        }
        return _vaultRecords;
    }

    function getVaultsByDeployedPaged(
        address deployer,
        uint256 page,
        uint256 pageSize
    ) external view virtual returns (VaultRecord[] memory) {
        if (page == 0 || pageSize == 0) {
            return new VaultRecord[](0);
        }
        uint256[] memory _vaultIds = deployerVaultIds[deployer];
        uint256 startIndex = (page - 1) * pageSize;
        if (startIndex >= _vaultIds.length) {
            return new VaultRecord[](0);
        }
        uint256 endIndex = startIndex + pageSize;
        if (endIndex > _vaultIds.length) {
            endIndex = _vaultIds.length;
        }
        VaultRecord[] memory _vaultRecords = new VaultRecord[](
            endIndex - startIndex
        );
        for (uint256 i = startIndex; i < endIndex; i++) {
            _vaultRecords[i - startIndex] = vaultRecords[_vaultIds[i]];
        }
        return _vaultRecords;
    }

    function _checkVaultIdValidity(uint256 vaultId_) internal view virtual {
        if (vaultId_ == 0 || vaultId_ > VaultId) {
            revert Errors.VaultRecordNotFound();
        }
    }
}
