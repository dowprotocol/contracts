// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Errors} from "./Errors.sol";
import {VaultConfig} from "./VaultConfig.sol";
import {VaultStore} from "./VaultStore.sol";
import {VaultActivityLogger} from "./VaultActivityLogger.sol";
import {EpochManager} from "./EpochManager.sol";

abstract contract VaultCommonBase {
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant DRT_DECIMALS = 18;

    VaultStore public store;
    VaultConfig public vaultConfig;

    function _notZeroAddress(address _address) internal pure {
        if (_address == address(0)) revert Errors.InvalidZeroAddress();
    }

    function _drtTokenRefByEpoch(uint256 epochId) internal view returns (IERC20) {
        return store.drtTokenByEpoch(epochId);
    }

    function _activityLoggerRef() internal view returns (VaultActivityLogger) {
        return store.activityLogger();
    }

    function _epochManagerRef() internal view returns (EpochManager) {
        return store.epochManager();
    }

    function _currentApyBps() internal view returns (uint256) {
        return store.currentApyBps();
    }

    function _assetDecimals(IERC20 asset) internal view returns (uint256) {
        return vaultConfig.underlyingAssetDecimals(address(asset));
    }

    function _normalizedDecimals() internal view returns (uint256) {
        return vaultConfig.normalizedDecimals();
    }

    function _normalizeAmount(
        IERC20 asset,
        uint256 amount
    ) internal view returns (uint256) {
        uint256 decimals = _assetDecimals(asset);
        uint256 normalizedDecimals = _normalizedDecimals();
        if (decimals == normalizedDecimals) {
            return amount;
        }
        return amount * (10 ** (normalizedDecimals - decimals));
    }

    function _increaseTvl(
        address vault,
        IERC20 asset,
        uint256 amount
    ) internal {
        store.increaseTvl(
            vault,
            address(asset),
            _normalizeAmount(asset, amount),
            amount
        );
    }

    function _decreaseTvlOrRevert(
        address vault,
        IERC20 asset,
        uint256 amount
    ) internal {
        store.decreaseTvlOrRevert(
            vault,
            address(asset),
            _normalizeAmount(asset, amount),
            amount
        );
    }

    function _increaseUserStakedAmount(
        address vault,
        address user,
        IERC20 asset,
        uint256 amount
    ) internal {
        store.increaseUserStaked(
            vault,
            user,
            address(asset),
            _normalizeAmount(asset, amount),
            amount
        );
    }

    function _decreaseUserStakedAmountOrRevert(
        address vault,
        address user,
        IERC20 asset,
        uint256 amount
    ) internal {
        store.decreaseUserStaked(
            vault,
            user,
            address(asset),
            _normalizeAmount(asset, amount),
            amount
        );
    }

    function _assetToDrtAmount(
        IERC20 asset,
        uint256 amount
    ) internal view returns (uint256) {
        uint256 decimals = _assetDecimals(asset);
        if (decimals == DRT_DECIMALS) {
            return amount;
        }
        return amount * (10 ** (DRT_DECIMALS - decimals));
    }

    function _loadPosition(
        uint256 positionId
    ) internal view returns (VaultStore.Position memory p) {
        VaultStore.PositionStatus statusRaw;
        (
            p.id,
            p.owner,
            p.underlyingAsset,
            p.principalAmount,
            p.shares,
            p.accumulatedYield,
            p.depositTime,
            p.lockupEndTime,
            p.lockupDuration,
            p.epochId,
            p.autoRoll,
            statusRaw
        ) = store.positions(positionId);
        p.status = statusRaw;
    }

    function _savePosition(VaultStore.Position memory p) internal {
        store.upsertPosition(
            p.id,
            p.owner,
            p.underlyingAsset,
            p.principalAmount,
            p.shares,
            p.accumulatedYield,
            p.depositTime,
            p.lockupEndTime,
            p.lockupDuration,
            p.epochId,
            p.autoRoll,
            uint8(p.status)
        );
    }

    function _disableAutoRoll(
        uint256 positionId,
        VaultStore.Position memory p
    ) internal returns (VaultStore.Position memory) {
        p.autoRoll = false;
        _savePosition(p);
        _recordUserPosition(positionId);
        return p;
    }

    function _getEpoch(
        uint256 epochId
    )
        internal
        view
        returns (
            uint256 startAt,
            uint256 subscriptionStartAt,
            uint256 interestEndAt,
            uint256 endAt,
            uint256 claimEndAt,
            uint256 apyBps,
            uint256 badDebtBps,
            bool settled
        )
    {
        _requireEpochManager();
        return _epochManagerRef().getEpoch(epochId);
    }

    function _requireEpochManager() internal view {
        if (address(_epochManagerRef()) == address(0)) {
            revert Errors.InvalidZeroAddress();
        }
    }

    function _accruedYieldByEpochApy(
        uint256 principal,
        uint256 epochApyBps,
        uint256 epochStartAt,
        uint256 calcAt,
        uint256 epochEndAt
    ) internal view returns (uint256) {
        _requireEpochManager();
        return
            _epochManagerRef().accruedYieldByEpochApy(
                principal,
                epochApyBps,
                epochStartAt,
                calcAt,
                epochEndAt
            );
    }

    function _principalAfterEpochBadDebt(
        uint256 epochId,
        uint256 principalAmount,
        bool requireSettled
    ) internal view returns (uint256) {
        (, , , , , , uint256 badDebtBps, bool settled) = _getEpoch(epochId);
        if (requireSettled && !settled) revert Errors.EpochNotSettled();
        if (badDebtBps > BPS_DENOMINATOR) badDebtBps = BPS_DENOMINATOR;
        return
            Math.mulDiv(
                principalAmount,
                BPS_DENOMINATOR - badDebtBps,
                BPS_DENOMINATOR,
                Math.Rounding.Floor
            );
    }

    function _positionSnapshotTimes(
        uint256 positionId,
        VaultStore.Position memory p
    )
        internal
        view
        returns (
            uint256 snapshotStartAt,
            uint256 snapshotEndAt,
            uint256 snapshotInterestEndAt
        )
    {
        snapshotEndAt = p.lockupEndTime;
        uint256 snapshotDuration = p.lockupDuration;
        snapshotInterestEndAt = store.positionInterestEndAtSnapshot(positionId);
        if (
            snapshotEndAt == 0 ||
            snapshotDuration == 0 ||
            snapshotEndAt <= snapshotDuration ||
            snapshotInterestEndAt == 0
        ) {
            revert Errors.InvalidEpochProgression();
        }
        snapshotStartAt = snapshotEndAt - snapshotDuration;
        if (
            snapshotInterestEndAt < snapshotStartAt ||
            snapshotInterestEndAt > snapshotEndAt
        ) {
            revert Errors.InvalidEpochProgression();
        }
    }

    function _rollPositionIfNeeded(
        address vault,
        uint256 positionId,
        VaultStore.Position memory p
    ) internal returns (VaultStore.Position memory) {
        return _rollPositionForContext(vault, positionId, p, false);
    }

    function _rollPositionForStrategy(
        address vault,
        uint256 positionId,
        VaultStore.Position memory p
    ) internal returns (VaultStore.Position memory) {
        return _rollPositionForContext(vault, positionId, p, true);
    }

    function _strategyRollReadyAt(
        uint256,
        uint256,
        uint256 interestEndAt,
        uint256
    ) internal view virtual returns (uint256) {
        return interestEndAt;
    }

    function _rollPositionForContext(
        address vault,
        uint256 positionId,
        VaultStore.Position memory p,
        bool allowGapRoll
    ) private returns (VaultStore.Position memory) {
        if (p.status != VaultStore.PositionStatus.Active || p.shares == 0) {
            return p;
        }
        (
            uint256 startAt,
            ,
            uint256 interestEndAt,
            uint256 endAt,
            ,
            uint256 apyBps,
            uint256 badDebtBps,
            bool settled
        ) = _getEpoch(p.epochId);
        uint256 readyAt = allowGapRoll
            ? _strategyRollReadyAt(p.epochId, startAt, interestEndAt, endAt)
            : endAt;
        if (readyAt == 0 || block.timestamp < readyAt || !p.autoRoll) return p;

        uint256 newEpochId = store.nextEpochByEpoch(p.epochId);
        if (
            newEpochId == 0 ||
            !_epochManagerRef().isEpochOpen(newEpochId)
        ) {
            return _disableAutoRoll(positionId, p);
        }

        (
            uint256 newStartAt,
            ,
            uint256 newInterestEndAt,
            uint256 newEndAt,
            ,
            ,
            ,
        ) = _getEpoch(newEpochId);
        if (block.timestamp >= newStartAt) {
            return _disableAutoRoll(positionId, p);
        }

        if (!allowGapRoll) return p;
        if (!settled) revert Errors.EpochNotSettled();
        if (badDebtBps > BPS_DENOMINATOR) badDebtBps = BPS_DENOMINATOR;

        uint256 principalAfterBadDebt = Math.mulDiv(
            p.principalAmount,
            BPS_DENOMINATOR - badDebtBps,
            BPS_DENOMINATOR,
            Math.Rounding.Floor
        );
        uint256 normalizedRolled = _normalizeAmount(
            IERC20(p.underlyingAsset),
            principalAfterBadDebt
        );
        if (
            store.grossDepositedByEpoch(newEpochId) + normalizedRolled >
            store.epochMaxCapacity(newEpochId)
        ) {
            return _disableAutoRoll(positionId, p);
        }

        (
            uint256 snapshotStartAt,
            uint256 snapshotEndAt,
            uint256 snapshotInterestEndAt
        ) = _positionSnapshotTimes(positionId, p);
        p.accumulatedYield += _accruedYieldByEpochApy(
            p.principalAmount,
            apyBps,
            snapshotStartAt,
            snapshotEndAt,
            snapshotInterestEndAt
        );
        _applyBadDebtTvlLoss(
            vault,
            p.underlyingAsset,
            p.principalAmount,
            principalAfterBadDebt
        );
        if (principalAfterBadDebt < p.principalAmount) {
            _decreaseUserStakedAmountOrRevert(
                vault,
                p.owner,
                IERC20(p.underlyingAsset),
                p.principalAmount - principalAfterBadDebt
            );
        }
        p.principalAmount = principalAfterBadDebt;
        store.increaseEpochGrossDeposit(newEpochId, normalizedRolled);

        _beforeRollPositionEpochSwitch(p, newEpochId);
        p.epochId = newEpochId;
        p.lockupEndTime = newEndAt;
        p.lockupDuration = newEndAt - newStartAt;
        _savePosition(p);
        store.setPositionInterestEndAtSnapshot(positionId, newInterestEndAt);
        _recordUserPosition(positionId);
        _emitPositionAutoRolled(positionId, p.owner, newEpochId);
        return p;
    }

    function _beforeRollPositionEpochSwitch(
        VaultStore.Position memory p,
        uint256 newEpochId
    ) internal virtual;

    function _emitPositionAutoRolled(
        uint256 positionId,
        address owner,
        uint256 newEpochId
    ) internal virtual;

    function _applyBadDebtTvlLoss(
        address vault,
        address asset,
        uint256 principalBefore,
        uint256 principalAfter
    ) internal virtual;

    function _recordUserPosition(uint256 positionId) internal virtual;
}
