// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultConfig} from "./VaultConfig.sol";
import {DowConfig} from "./DowConfig.sol";
import {VaultActivityLogger} from "./VaultActivityLogger.sol";
import {VaultStore} from "./VaultStore.sol";
import {VaultCommonBase} from "./VaultCommonBase.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Errors} from "./Errors.sol";

interface IVaultDRT {
    function mint(address to, uint256 amount) external;

    function burn(address from, uint256 amount) external;
}

interface IRedeemVaultPendingRef {
    function ensureNoPendingEarlyWithdraw(uint256 positionId) external;
}

interface IEpochManagerRef {
    function createEpoch(
        uint256 startAt,
        uint256 epochDurationInDays,
        uint256 epochInterestDuration,
        uint256 subscriptionWindow,
        uint256 claimWindow,
        uint256 apyBps,
        bool opened
    ) external returns (uint256 epochId);

    function setEpochOpen(uint256 epochId, bool opened) external;

    function setSubscriptionEpoch(uint256 epochId) external;

    function settleEpoch(
        uint256 apyBps,
        uint256 badDebtBps,
        uint256 epochId
    ) external;

    function getEpochIdByStartAt(
        uint256 startAt
    ) external view returns (uint256);

    function isEpochOpen(uint256 epochId) external view returns (bool);

    function subscriptionEpochId() external view returns (uint256);
}

contract Vault is VaultCommonBase, ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public redeemVault;

    bytes32 public constant ALLOWED_TO_OPERATE_TOKEN_ROLE =
        keccak256("ALLOWED_TO_OPERATE_TOKEN_ROLE");
    uint256 internal constant DEFAULT_AUTO_ROLL_CONFIRMATION_WINDOW = 7 days;
    mapping(uint256 => uint256) public cancelAutoRollDeadlineByEpoch;
    mapping(uint256 => bool) public epochDepositPolicyEnabled;
    mapping(uint256 => mapping(address => bool))
        public epochDepositAssetAllowed;

    event Deposit(
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint256 positionId,
        bytes32 indexed referralCode
    );
    event VaultOpened(address by);
    event VaultOff(address by);
    event VaultClosed(address by);

    event APYRefreshed(address indexed _by, uint256 apyBps, uint256 timestamp);
    event StrategyDeposited(
        address indexed user,
        IERC20 indexed asset,
        uint256 received,
        uint256 timestamp
    );
    event FundsWithdrawnForLending(
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint256 newBorrowedAmount,
        uint256 timestamp
    );

    event EpochManagerUpdated(
        address indexed oldManager,
        address indexed newManager
    );
    event EpochDrtSet(uint256 indexed epochId, address indexed drtAddress);
    event AutoRollCancelled(
        uint256 indexed positionId,
        address indexed user,
        uint256 epochId
    );
    event CancelAutoRollDeadlineSet(
        uint256 indexed epochId,
        uint256 deadline
    );
    event EpochDepositAssetAllowedUpdated(
        uint256 indexed epochId,
        address indexed asset,
        bool allowed
    );
    event EpochDepositPolicyEnabledUpdated(
        uint256 indexed epochId,
        bool enabled
    );
    event PositionAutoRolled(
        uint256 indexed positionId,
        address indexed user,
        uint256 newEpochId,
        address _by
    );
    event PositionAutoRollSkipped(
        uint256 indexed positionId,
        address indexed user,
        uint256 epochId
    );
    event EmergencyUnderlyingWithdrawn(
        address indexed operator,
        address indexed to,
        address indexed asset,
        uint256 amount
    );
    event EmergencyUnderlyingWithdrawRequested(
        uint256 indexed requestId,
        address indexed requester,
        address indexed to,
        address asset,
        uint256 amount
    );

    modifier onlyStrategyManager() {
        if (!vaultConfig.strategyManager(msg.sender))
            revert Errors.NotStrategyManager();
        _;
    }

    modifier onlyEmergencyRedeemRequester() {
        if (!vaultConfig.emergencyRedeemRequester(msg.sender))
            revert Errors.NotAuthorized();
        _;
    }

    modifier onlyEmergencyRedeemReviewer() {
        if (!vaultConfig.emergencyRedeemReviewer(msg.sender))
            revert Errors.NotAuthorized();
        _;
    }

    modifier onlyRedeemVault() {
        if (msg.sender != redeemVault || redeemVault == address(0)) {
            revert Errors.NotAuthorized();
        }
        _;
    }

    constructor(address _store, address _vaultConfig) {
        _notZeroAddress(_store);
        _notZeroAddress(_vaultConfig);
        store = VaultStore(_store);
        vaultConfig = VaultConfig(_vaultConfig);
    }

    function syncStoreCore() external {
        vaultConfig.onlyVaultOwner(msg.sender);
        store.setCoreRefs(address(vaultConfig), vaultConfig.vaultName());
        if (store.nextPositionId() == 0) {
            store.setCounters(1, 1, 1);
        }
        if (store.nextEmergencyWithdrawRequestId() == 0) {
            store.setNextEmergencyWithdrawRequestId(1);
        }
    }

    function _requireEpochDrt(
        uint256 epochId
    ) internal view returns (IERC20 token) {
        token = _drtTokenRefByEpoch(epochId);
        if (address(token) == address(0)) revert Errors.InvalidZeroAddress();
    }

    function _movePositionDrt(
        address owner,
        uint256 fromEpochId,
        uint256 toEpochId,
        uint256 shares
    ) internal {
        if (shares == 0 || fromEpochId == toEpochId) return;
        IVaultDRT(address(_requireEpochDrt(fromEpochId))).burn(owner, shares);
        IVaultDRT(address(_requireEpochDrt(toEpochId))).mint(owner, shares);
    }

    function _validateDrtAddress(address drtAddress) internal view {
        if (drtAddress == address(0)) revert Errors.InvalidZeroAddress();
        if (drtAddress.code.length == 0) revert Errors.NotAContract();
    }

    function syncRolledPositionDrt(
        address owner,
        uint256 fromEpochId,
        uint256 toEpochId,
        uint256 shares
    ) external virtual onlyRedeemVault {
        _movePositionDrt(owner, fromEpochId, toEpochId, shares);
    }

    function _vaultStatus() internal view returns (VaultStore.VaultStatus) {
        return VaultStore.VaultStatus(store.vaultStatus());
    }

    function setDrtRedeemVault(address redeemVault_) external virtual {
        vaultConfig.onlyVaultOwner(msg.sender);
        _notZeroAddress(redeemVault_);
        address oldRedeemVault = redeemVault;
        redeemVault = redeemVault_;
        uint256[] memory epochIds = store.getDrtEpochIds();
        for (uint256 i = 0; i < epochIds.length; i++) {
            IERC20 drtTokenRef = _drtTokenRefByEpoch(epochIds[i]);
            if (address(drtTokenRef) != address(0)) {
                if (oldRedeemVault != address(0)) {
                    try IAccessControl(address(drtTokenRef)).revokeRole(
                        ALLOWED_TO_OPERATE_TOKEN_ROLE, oldRedeemVault
                    ) {} catch {}
                }
                try IAccessControl(address(drtTokenRef)).grantRole(
                    ALLOWED_TO_OPERATE_TOKEN_ROLE, redeemVault_
                ) {} catch {}
            }
        }
    }

    function fundRedeemVault(
        address asset,
        uint256 amount
    ) external virtual onlyRedeemVault {
        // _requireSupportedAsset(asset);
        if (amount == 0) revert Errors.InvalidZeroAmount();

        IERC20 ua = IERC20(asset);
        if (ua.balanceOf(address(this)) < amount)
            revert Errors.InsufficientLiquidity();
        ua.safeTransfer(redeemVault, amount);
    }

    function setActivityLogger(address _activityLogger) external virtual {
        vaultConfig.onlyVaultOwner(msg.sender);
        _notZeroAddress(_activityLogger);
        store.setActivityLogger(_activityLogger);
    }

    function setEpochManager(address _epochManager) external virtual {
        vaultConfig.onlyVaultOwner(msg.sender);
        address old = address(_epochManagerRef());
        store.setEpochManager(_epochManager);
        emit EpochManagerUpdated(old, _epochManager);
    }

    function configureEpoch(
        uint256 startAt,
        uint256 epochDurationInDays,
        uint256 epochInterestDuration,
        uint256 subscriptionWindow,
        uint256 claimWindow,
        uint256 apyBps,
        bool opened,
        bool useAsSubscriptionEpoch,
        address drtAddress,
        uint256 predecessorEpochId
    ) external virtual onlyStrategyManager returns (uint256 epochId) {
        _requireEpochManager();
        if (startAt <= block.timestamp) revert Errors.InvalidEpochStartTime();
        _validateDrtAddress(drtAddress);

        epochId = IEpochManagerRef(address(_epochManagerRef())).createEpoch(
            startAt,
            epochDurationInDays,
            epochInterestDuration,
            subscriptionWindow,
            claimWindow,
            apyBps,
            opened
        );

        store.setDrtTokenByEpoch(epochId, drtAddress);
        store.setEpochMaxCapacity(epochId, vaultConfig.maxCapacity());

        if (predecessorEpochId != 0) {
            (, , , uint256 predecessorEndAt, , , , ) = _getEpoch(
                predecessorEpochId
            );
            if (
                predecessorEndAt == 0 ||
                predecessorEndAt > startAt ||
                store.nextEpochByEpoch(predecessorEpochId) != 0
            ) {
                revert Errors.InvalidEpochProgression();
            }
            store.setEpochRolloverLink(predecessorEpochId, epochId);
        }

        if (redeemVault != address(0)) {
            try IAccessControl(drtAddress).grantRole(
                ALLOWED_TO_OPERATE_TOKEN_ROLE,
                redeemVault
            ) {} catch {}
        }

        if (useAsSubscriptionEpoch) {
            IEpochManagerRef(address(_epochManagerRef())).setSubscriptionEpoch(
                epochId
            );
        }

        emit EpochDrtSet(epochId, drtAddress);
    }

    function setEpochOpen(
        uint256 epochId,
        bool opened
    ) external virtual onlyStrategyManager {
        _requireEpochManager();
        IEpochManagerRef(address(_epochManagerRef())).setEpochOpen(
            epochId,
            opened
        );
    }

    function setSubscriptionEpoch(
        uint256 epochId
    ) external virtual onlyStrategyManager {
        _requireEpochManager();
        IEpochManagerRef(address(_epochManagerRef())).setSubscriptionEpoch(
            epochId
        );
    }

    function setEpochMaxCapacity(
        uint256 epochId,
        uint256 newCap
    ) external virtual {
        vaultConfig.onlyVaultOwner(msg.sender);
        if (newCap == 0) revert Errors.InvalidZeroAmount();
        if (newCap < store.grossDepositedByEpoch(epochId)) {
            revert Errors.ExceedMaxCapacity();
        }
        store.setEpochMaxCapacity(epochId, newCap);
    }

    function setCancelAutoRollDeadline(
        uint256 epochId,
        uint256 deadline
    ) external virtual {
        vaultConfig.onlyVaultOwner(msg.sender);
        if (epochId == 0) revert Errors.InvalidEpochId();
        if (deadline != 0) {
            (uint256 epochStartAt, , , uint256 epochEndAt, , , , ) = _getEpoch(
                epochId
            );
            if (epochStartAt == 0) revert Errors.EpochNotFound();
            uint256 nextEpochId = store.nextEpochByEpoch(epochId);
            uint256 deadlineUpperBound = epochEndAt;
            if (nextEpochId != 0) {
                (uint256 nextStartAt, , , , , , , ) = _getEpoch(nextEpochId);
                if (nextStartAt == 0) revert Errors.EpochNotFound();
                deadlineUpperBound = nextStartAt - 1;
            }
            if (deadline < epochStartAt || deadline > deadlineUpperBound) {
                revert Errors.InvalidEpochProgression();
            }
        }
        cancelAutoRollDeadlineByEpoch[epochId] = deadline;
        emit CancelAutoRollDeadlineSet(epochId, deadline);
    }

    function setEpochDepositAssetAllowed(
        uint256 epochId,
        address asset,
        bool allowed
    ) external virtual {
        vaultConfig.onlyVaultOwner(msg.sender);
        _requireExistingEpoch(epochId);
        _notZeroAddress(asset);
        if (allowed) _requireSupportedAsset(asset);
        epochDepositAssetAllowed[epochId][asset] = allowed;
        if (
            epochDepositPolicyEnabled[epochId] &&
            !_hasEffectiveEpochDepositAsset(epochId)
        ) revert Errors.EmptyEpochDepositAssetAllowlist();
        emit EpochDepositAssetAllowedUpdated(epochId, asset, allowed);
    }

    function setEpochDepositPolicyEnabled(
        uint256 epochId,
        bool enabled
    ) external virtual {
        vaultConfig.onlyVaultOwner(msg.sender);
        _requireExistingEpoch(epochId);
        if (enabled && !_hasEffectiveEpochDepositAsset(epochId)) {
            revert Errors.EmptyEpochDepositAssetAllowlist();
        }
        epochDepositPolicyEnabled[epochId] = enabled;
        emit EpochDepositPolicyEnabledUpdated(epochId, enabled);
    }

    function settleEpoch(
        uint256 epochApy,
        uint256 epochBadDebtBps,
        uint256 epochId
    ) external virtual onlyStrategyManager {
        _requireEpochManager();
        IEpochManagerRef(address(_epochManagerRef())).settleEpoch(
            epochApy,
            epochBadDebtBps,
            epochId
        );
    }

    function _autoRollDeadline(
        uint256 epochId,
        uint256 epochStartAt,
        uint256 epochEndAt
    ) internal view returns (uint256) {
        uint256 configured = cancelAutoRollDeadlineByEpoch[epochId];
        if (configured != 0) return configured;
        uint256 window = DEFAULT_AUTO_ROLL_CONFIRMATION_WINDOW;
        if (epochEndAt <= epochStartAt || epochEndAt - epochStartAt <= window)
            return epochStartAt;
        return epochEndAt - window;
    }

    function _strategyRollReadyAt(
        uint256 epochId,
        uint256 epochStartAt,
        uint256,
        uint256 epochEndAt
    ) internal view override returns (uint256) {
        return _autoRollDeadline(epochId, epochStartAt, epochEndAt);
    }

    function _requireSupportedAsset(address asset) internal view {
        if (!vaultConfig.isUnderlyingAssetSupported(asset))
            revert Errors.InvalidUnderlyingAsset();
        if (!vaultConfig.dowConfig().isAllowedLiquidityAsset(asset))
            revert Errors.InvalidUnderlyingAsset();
    }

    function _hasEffectiveEpochDepositAsset(
        uint256 epochId
    ) internal view returns (bool) {
        address[] memory assets = vaultConfig.underlyingAssetList();
        DowConfig dowConfig = vaultConfig.dowConfig();
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            if (
                epochDepositAssetAllowed[epochId][asset] &&
                vaultConfig.isUnderlyingAssetSupported(asset) &&
                dowConfig.isAllowedLiquidityAsset(asset)
            ) return true;
        }
        return false;
    }

    function _requireExistingEpoch(uint256 epochId) internal view {
        if (epochId == 0) revert Errors.InvalidEpochId();
        (uint256 epochStartAt, , , , , , , ) = _getEpoch(epochId);
        if (epochStartAt == 0) revert Errors.EpochNotFound();
    }

    function _ensureNoPendingEarlyWithdraw(uint256 positionId) internal {
        if (redeemVault != address(0)) {
            IRedeemVaultPendingRef(redeemVault).ensureNoPendingEarlyWithdraw(
                positionId
            );
            return;
        }
        if (store.pendingEarlyWithdrawRequestIdByPosition(positionId) != 0) {
            revert Errors.InvalidPositionStatus();
        }
    }

    function cancelAutoRoll(uint256 positionId) external virtual {
        vaultConfig.onlyProtocolAndVaultOn();
        VaultStore.Position memory p = _loadPosition(positionId);
        if (p.owner != msg.sender) revert Errors.NotPositionOwner();
        if (p.status != VaultStore.PositionStatus.Active || p.shares == 0)
            revert Errors.PositionClosed();
        _ensureNoPendingEarlyWithdraw(positionId);
        bool oldAutoRoll = p.autoRoll;
        p = _rollPositionIfNeeded(address(this), positionId, p);
        if (oldAutoRoll && !p.autoRoll) {
            emit AutoRollCancelled(positionId, msg.sender, p.epochId);
            return;
        }
        (uint256 epochStartAt, , , uint256 epochEndAt, , , , ) = _getEpoch(
            p.epochId
        );
        if (
            block.timestamp >=
            _autoRollDeadline(p.epochId, epochStartAt, epochEndAt)
        ) {
            revert Errors.CancellationWindowClosed();
        }
        p.autoRoll = false;
        _savePosition(p);
        _recordUserPosition(positionId);
        emit AutoRollCancelled(positionId, msg.sender, p.epochId);
    }

    function rollPositions(
        uint256[] calldata positionIds,
        uint256 targetEpochId
    ) external onlyStrategyManager {
        vaultConfig.onlyProtocolAndVaultOn();
        (uint256 targetStartAt, , , , , , , ) = _getEpoch(targetEpochId);
        if (
            !IEpochManagerRef(address(_epochManagerRef())).isEpochOpen(
                targetEpochId
            )
        ) {
            revert Errors.EpochNotOpened();
        }
        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 positionId = positionIds[i];
            VaultStore.Position memory p = _loadPosition(positionId);
            if (
                p.id == 0 ||
                p.status != VaultStore.PositionStatus.Active ||
                p.shares == 0 ||
                !p.autoRoll
            ) {
                continue;
            }
            (uint256 epochStartAt, , , uint256 epochEndAt, , , , ) = _getEpoch(
                p.epochId
            );
            if (
                store.nextEpochByEpoch(p.epochId) != targetEpochId ||
                block.timestamp <
                _autoRollDeadline(p.epochId, epochStartAt, epochEndAt)
            ) {
                continue;
            }
            if (block.timestamp >= targetStartAt) {
                _disableAutoRoll(positionId, p);
                emit PositionAutoRollSkipped(positionId, p.owner, p.epochId);
                continue;
            }
            uint256 oldEpochId = p.epochId;
            p = _rollPositionForStrategy(address(this), positionId, p);
            if (p.epochId == oldEpochId) {
                emit PositionAutoRollSkipped(positionId, p.owner, p.epochId);
            }
        }
    }

    function getVaultBasicPara()
        external
        view
        returns (
            uint256 depositCap,
            uint256 totalDeposits,
            uint256 apyBps,
            uint256 subStartTime,
            uint256 epochStartTime,
            uint256 interestEndAt,
            uint256 epochEndAt,
            uint256 protocolFee,
            address[] memory underlyingAssetList
        )
    {
        DowConfig dc = vaultConfig.dowConfig();
        _requireEpochManager();
        depositCap = vaultConfig.maxCapacity();
        totalDeposits = 0;
        uint256 epochId = IEpochManagerRef(address(_epochManagerRef()))
            .subscriptionEpochId();
        if (epochId != 0) {
            (epochStartTime, subStartTime, interestEndAt, epochEndAt, , , , ) = _getEpoch(epochId);
            depositCap = store.epochMaxCapacity(epochId);
            totalDeposits = store.grossDepositedByEpoch(epochId);
        }
        return (
            depositCap,
            totalDeposits,
            _currentApyBps(),
            subStartTime,
            epochStartTime,
            interestEndAt,
            epochEndAt,
            dc.protocol_fee_bps(),
            vaultConfig.underlyingAssetList()
        );
    }

    function getVaultDepositStats(
        uint256 epochId
    )
        external
        view
        returns (
            uint256 epochCap,
            uint256 grossDeposited,
            uint256 remainingCapacity,
            uint256 lifetimeDepositedPrincipal,
            uint256 currentTotalValueLocked
        )
    {
        epochCap = store.epochMaxCapacity(epochId);
        grossDeposited = store.grossDepositedByEpoch(epochId);
        return (
            epochCap,
            grossDeposited,
            epochCap > grossDeposited ? epochCap - grossDeposited : 0,
            store.lifetimeDepositedPrincipal(),
            store.totalValueLocked()
        );
    }

    function deposit(
        address asset,
        uint256 amount,
        bytes32 referralCode,
        bool autoRoll
    ) external virtual nonReentrant returns (uint256) {
        vaultConfig.onlyProtocolAndVaultOn();
        _requireSupportedAsset(asset);
        if (amount == 0) revert Errors.InvalidZeroAmount();
        uint256 epochId = _subscriptionEpochIdForDeposit(block.timestamp);
        if (
            epochDepositPolicyEnabled[epochId] &&
            !epochDepositAssetAllowed[epochId][asset]
        ) revert Errors.InvalidUnderlyingAsset();
        IERC20 ua = IERC20(asset);
        uint256 cashBefore = ua.balanceOf(address(this));
        ua.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = ua.balanceOf(address(this)) - cashBefore;
        if (received == 0) revert Errors.InvalidZeroAmount();
        uint256 normalizedReceived = _normalizeAmount(ua, received);
        uint256 minDeposit = vaultConfig.minDepositAmount();
        if (minDeposit > 0 && normalizedReceived < minDeposit) revert Errors.InvalidZeroAmount();
        uint256 epochCap = store.epochMaxCapacity(epochId);
        if (epochCap == 0) revert Errors.ExceedMaxCapacity();
        if (
            store.grossDepositedByEpoch(epochId) + normalizedReceived > epochCap
        ) {
            revert Errors.ExceedMaxCapacity();
        }

        uint256 shares = _assetToDrtAmount(ua, received);
        if (shares == 0) revert Errors.InvalidZeroShare();

        uint256 positionId = store.consumeNextPositionId();
        IVaultDRT(address(_requireEpochDrt(epochId))).mint(msg.sender, shares);
        (
            uint256 epochStartAt,
            ,
            uint256 epochInterestEndAt,
            uint256 epochEndAt,
            ,
            ,
            ,
        ) = _getEpoch(epochId);
        VaultStore.Position memory p = VaultStore.Position({
            id: positionId,
            owner: msg.sender,
            underlyingAsset: asset,
            principalAmount: received,
            shares: shares,
            accumulatedYield: 0,
            depositTime: block.timestamp,
            lockupEndTime: epochEndAt,
            lockupDuration: epochEndAt - epochStartAt,
            epochId: epochId,
            autoRoll: autoRoll,
            status: VaultStore.PositionStatus.Active
        });
        _savePosition(p);
        store.setPositionInterestEndAtSnapshot(positionId, epochInterestEndAt);
        if (store.getUserPositionCount(msg.sender) == 0) {
            store.setTotalUsers(store.totalUsers() + 1);
        }
        store.pushUserPosition(msg.sender, positionId);

        store.increaseEpochGrossDeposit(epochId, normalizedReceived);
        store.increaseLifetimeDepositedPrincipal(normalizedReceived);
        store.increaseTvl(address(this), asset, normalizedReceived, received);
        _increaseUserStakedAmount(address(this), msg.sender, ua, received);

        if (address(_activityLoggerRef()) != address(0)) {
            _activityLoggerRef().recordAction(
                msg.sender,
                VaultActivityLogger.UserActionType.Deposit,
                received,
                address(ua),
                address(_requireEpochDrt(epochId)),
                shares
            );
        }

        _recordUserPosition(positionId);

        emit Deposit(msg.sender, asset, received, positionId,referralCode);
        return positionId;
    }

    function refreshAPY(uint256 apyBps) external virtual onlyStrategyManager {
        vaultConfig.onlyProtocolAndVaultOn();
        store.setCurrentApyBps(apyBps);
        store.setLastRefreshTime(block.timestamp);
        emit APYRefreshed(msg.sender, apyBps, block.timestamp);
    }

    function strategyDeposit(
        address asset,
        uint256 amount
    ) external virtual onlyStrategyManager {
        if (amount == 0) revert Errors.InvalidZeroAmount();

        IERC20 ua = IERC20(asset);
        uint256 cashBefore = ua.balanceOf(address(this));
        ua.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = ua.balanceOf(address(this)) - cashBefore;
        if (received == 0) revert Errors.InvalidZeroAmount();
        uint256 borrowedByAsset = store.borrowedAmountByAsset(asset);
        if (borrowedByAsset != 0) {
            uint256 repaidAmount = received < borrowedByAsset
                ? received
                : borrowedByAsset;
            uint256 normalizedRepaid = _normalizeAmount(ua, repaidAmount);
            uint256 borrowedAmount = store.borrowedAmount();
            if (normalizedRepaid > borrowedAmount)
                revert Errors.InvalidRepayAmount();

            store.setBorrowedAmountByAsset(asset, borrowedByAsset - repaidAmount);
            store.setBorrowedAmount(borrowedAmount - normalizedRepaid);
        }
        emit StrategyDeposited(msg.sender, ua, received, block.timestamp);
    }

    function withdrawForLending(
        address asset,
        uint256 amount
    ) external virtual onlyStrategyManager {
        vaultConfig.onlyProtocolAndVaultOn();
        _requireSupportedAsset(asset);
        if (amount == 0) revert Errors.InvalidZeroAmount();

        IERC20 ua = IERC20(asset);
        uint256 cashBefore = ua.balanceOf(address(this));
        if (cashBefore < amount) revert Errors.InsufficientLiquidity();

        ua.safeTransfer(msg.sender, amount);
        uint256 borrowedAmount_ = store.borrowedAmount();
        uint256 borrowedByAsset = store.borrowedAmountByAsset(asset);
        store.setBorrowedAmountByAsset(asset, borrowedByAsset + amount);
        borrowedAmount_ += _normalizeAmount(ua, amount);
        store.setBorrowedAmount(borrowedAmount_);

        emit FundsWithdrawnForLending(
            msg.sender,
            asset,
            amount,
            borrowedAmount_,
            block.timestamp
        );
    }

    function setVaultStatus(VaultStore.VaultStatus status_) external virtual {
        vaultConfig.onlyVaultOwner(msg.sender);
        if (_vaultStatus() == VaultStore.VaultStatus.Closed) revert Errors.VaultClosed();
        store.setVaultStatus(status_);
        if (status_ == VaultStore.VaultStatus.On) {
            emit VaultOpened(msg.sender);
        } else if (status_ == VaultStore.VaultStatus.Off) {
            emit VaultOff(msg.sender);
        } else if (status_ == VaultStore.VaultStatus.Closed) {
            emit VaultClosed(msg.sender);
        } else {
            revert Errors.InvalidVaultStatus();
        }
    }

    function emergencyWithdrawUnderlying(
        address asset,
        address to,
        uint256 amount
    )
        external
        virtual
        onlyEmergencyRedeemRequester
        returns (uint256 requestId)
    {
        if (_vaultStatus() != VaultStore.VaultStatus.Closed) revert Errors.InvalidVaultStatus();
        _notZeroAddress(asset);
        _notZeroAddress(to);
        if (amount == 0) revert Errors.InvalidZeroAmount();

        requestId = store.consumeNextEmergencyWithdrawRequestId();
        store.upsertEmergencyWithdrawRequest(
            requestId,
            msg.sender,
            asset,
            to,
            amount
        );

        emit EmergencyUnderlyingWithdrawRequested(
            requestId,
            msg.sender,
            to,
            asset,
            amount
        );
    }

    function reviewEmergencyWithdrawUnderlying(
        uint256 requestId,
        bool approved
    ) external virtual nonReentrant onlyEmergencyRedeemReviewer {
        if (_vaultStatus() != VaultStore.VaultStatus.Closed) revert Errors.InvalidVaultStatus();
        VaultStore.EmergencyWithdrawRequest memory request;
        (
            request.id,
            request.requester,
            request.asset,
            request.to,
            request.amount
        ) = store.emergencyWithdrawRequests(requestId);
        if (request.id == 0) revert Errors.InvalidRequestId();

        if (!approved) {
            store.deleteEmergencyWithdrawRequest(requestId);
            return;
        }

        IERC20 ua = IERC20(request.asset);
        if (ua.balanceOf(address(this)) < request.amount) {
            revert Errors.InsufficientLiquidity();
        }
        store.deleteEmergencyWithdrawRequest(requestId);
        ua.safeTransfer(request.to, request.amount);

        emit EmergencyUnderlyingWithdrawn(
            msg.sender,
            request.to,
            request.asset,
            request.amount
        );
    }

    function _subscriptionEpochIdForDeposit(
        uint256 ts
    ) internal view returns (uint256 epochId) {
        _requireEpochManager();
        epochId = IEpochManagerRef(address(_epochManagerRef()))
            .subscriptionEpochId();
        if (epochId == 0) revert Errors.EpochNotFound();
        if (
            !IEpochManagerRef(address(_epochManagerRef())).isEpochOpen(epochId)
        ) {
            revert Errors.EpochNotOpened();
        }
        (uint256 startAt, uint256 subscriptionStartAt, , , , , , ) = _getEpoch(
            epochId
        );
        if (startAt <= ts) revert Errors.SubscriptionWindowClosed();
        if (ts < subscriptionStartAt) {
            revert Errors.SubscriptionWindowClosed();
        }
    }

    function _beforeRollPositionEpochSwitch(
        VaultStore.Position memory p,
        uint256 newEpochId
    ) internal override {
        _movePositionDrt(p.owner, p.epochId, newEpochId, p.shares);
    }

    function _emitPositionAutoRolled(
        uint256 positionId,
        address owner,
        uint256 newEpochId
    ) internal override {
        emit PositionAutoRolled(positionId, owner, newEpochId, msg.sender);
    }

    function _applyBadDebtTvlLoss(
        address vault,
        address asset,
        uint256 principalBefore,
        uint256 principalAfter
    ) internal override {
        if (principalAfter >= principalBefore) return;
        _decreaseTvlOrRevert(vault, IERC20(asset), principalBefore - principalAfter);
    }

    function _recordUserPosition(uint256 positionId) internal override {
        if (address(_activityLoggerRef()) == address(0)) return;
        VaultStore.Position memory p = _loadPosition(positionId);
        if (p.owner == address(0)) return;
        uint256 apy = _currentApyBps();
        if (apy == 0) apy = vaultConfig.baseApyBps();
        _activityLoggerRef().recordUserPosition(
            p.owner,
            address(this),
            store.vaultName(),
            positionId,
            p.epochId,
            p.lockupEndTime,
            p.underlyingAsset,
            p.principalAmount,
            apy,
            false,
            false,
            0,
            p.autoRoll
        );
    }

    function isVaultOpen() external view virtual returns (bool) {
        return _vaultStatus() == VaultStore.VaultStatus.On;
    }

}
