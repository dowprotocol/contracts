// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Errors} from "./Errors.sol";
import {EpochManagerStore} from "./EpochManagerStore.sol";

contract EpochManager {
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    address public admin;
    EpochManagerStore public store;

    event VaultAuthorized(address indexed vault, bool authorized);
    event EpochCreated(
        uint256 indexed epochId,
        uint256 startAt,
        uint256 subscriptionStartAt,
        uint256 interestEndAt,
        uint256 endAt,
        uint256 claimEndAt,
        uint256 apyBps
    );
    event EpochSettled(uint256 indexed epochId, uint256 apyBps, uint256 badDebtBps);
    event EpochTimesUpdated(
        address indexed operator,
        uint256 indexed epochId,
        uint256 oldSubscriptionStartAt,
        uint256 oldStartAt,
        uint256 oldInterestEndAt,
        uint256 oldEndAt,
        uint256 oldClaimEndAt,
        uint256 newSubscriptionStartAt,
        uint256 newStartAt,
        uint256 newInterestEndAt,
        uint256 newEndAt,
        uint256 newClaimEndAt
    );

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Errors.NotAdmin();
        _;
    }

    modifier onlyVault() {
        if (!store.authorizedVaults(msg.sender)) revert Errors.NotAuthorized();
        _;
    }

    constructor(address storeAddress, address initialAdmin) {
        if (storeAddress == address(0) || initialAdmin == address(0)) {
            revert Errors.InvalidZeroAddress();
        }
        store = EpochManagerStore(storeAddress);
        admin = initialAdmin;
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert Errors.InvalidZeroAddress();
        admin = newAdmin;
    }

    function authorizeVault(address vault, bool authorized)
        external
        virtual
        onlyAdmin
    {
        store.setAuthorizedVault(vault, authorized);
        emit VaultAuthorized(vault, authorized);
    }

    function createEpoch(
        uint256 startAt,
        uint256 epochDurationInDays,
        uint256 epochInterestDuration,
        uint256 subscriptionWindow,
        uint256 claimWindow,
        uint256 apyBps,
        bool opened
    ) external virtual onlyVault returns (uint256 epochId) {
        if (startAt <= block.timestamp) revert Errors.InvalidEpochStartTime();
        if (epochDurationInDays == 0) revert Errors.InvalidDuration();
        if (epochInterestDuration == 0) revert Errors.InvalidDuration();
        if (subscriptionWindow == 0) revert Errors.InvalidDuration();
        if (claimWindow == 0) revert Errors.InvalidDuration();
        if (apyBps > BPS_DENOMINATOR) revert Errors.InvalidAPY();

        epochId = store.epochIdByStartAt(startAt);
        if (epochId != 0) revert Errors.InvalidEpochStartTime();

        uint256 epochDurationSeconds = epochDurationInDays * 1 days;
        if (epochInterestDuration > epochDurationSeconds)
            revert Errors.InvalidDuration();
        if (subscriptionWindow > startAt) revert Errors.InvalidDuration();

        uint256 subscriptionStartAt = startAt - subscriptionWindow;
        uint256 endAt = startAt + epochDurationSeconds;
        uint256 interestEndAt = startAt + epochInterestDuration;
        uint256 claimEndAt = endAt + claimWindow;

        uint256 latestEpochId = store.nextEpochId();
        if (latestEpochId != 0) {
            (, , , , uint256 latestEndAt, , , , ) = store.epochs(latestEpochId);
            if (startAt < latestEndAt) revert Errors.InvalidEpochProgression();
        }

        epochId = store.incrementNextEpochId();

        store.createEpoch(
            epochId,
            startAt,
            subscriptionStartAt,
            interestEndAt,
            endAt,
            claimEndAt,
            apyBps,
            0,
            false
        );
        store.setEpochIdByStart(startAt, epochId);
        store.setEpochOpened(epochId, opened);

        emit EpochCreated(
            epochId,
            startAt,
            subscriptionStartAt,
            interestEndAt,
            endAt,
            claimEndAt,
            apyBps
        );
    }

    function setEpochOpen(
        uint256 epochId,
        bool opened
    ) external virtual onlyVault {
        (uint256 id, , , , , , , , ) = store.epochs(epochId);
        if (id == 0) revert Errors.EpochNotFound();
        store.setEpochOpened(epochId, opened);
    }

    function setSubscriptionEpoch(uint256 epochId) external virtual onlyVault {
        (uint256 id, uint256 startAt, , , , , , , ) = store.epochs(epochId);
        if (id == 0) revert Errors.EpochNotFound();
        if (!store.epochOpened(epochId)) revert Errors.EpochNotOpened();
        if (startAt <= block.timestamp) revert Errors.InvalidEpochStartTime();

        store.setSubscriptionEpochId(epochId);
    }

    function updateEpochTimes(
        uint256 epochId,
        uint256 subscriptionStartAt,
        uint256 startAt,
        uint256 interestEndAt,
        uint256 endAt,
        uint256 claimEndAt
    ) external virtual onlyAdmin {
        (
            uint256 id,
            uint256 oldStartAt,
            uint256 oldSubscriptionStartAt,
            uint256 oldInterestEndAt,
            uint256 oldEndAt,
            uint256 oldClaimEndAt,
            ,
            ,
            bool settled
        ) = store.epochs(epochId);
        if (id == 0) revert Errors.EpochNotFound();
        if (settled) revert Errors.EpochSettled();
        if (startAt == 0) revert Errors.InvalidEpochStartTime();
        if (
            subscriptionStartAt > startAt ||
            startAt >= interestEndAt ||
            interestEndAt > endAt ||
            endAt >= claimEndAt
        ) {
            revert Errors.InvalidEpochProgression();
        }

        uint256 ts = block.timestamp;
        if (
            (oldSubscriptionStartAt <= ts && ts < oldStartAt) ||
            (subscriptionStartAt <= ts && ts < startAt)
        ) {
            revert Errors.InvalidEpochProgression();
        }

        uint256 existingEpochId = store.epochIdByStartAt(startAt);
        if (existingEpochId != 0 && existingEpochId != epochId) {
            revert Errors.InvalidEpochStartTime();
        }

        if (startAt != oldStartAt) {
            if (store.epochIdByStartAt(oldStartAt) == epochId) {
                store.setEpochIdByStart(oldStartAt, 0);
            }
            store.setEpochIdByStart(startAt, epochId);
        } else if (existingEpochId == 0) {
            store.setEpochIdByStart(startAt, epochId);
        }

        store.setEpochTimes(
            epochId,
            subscriptionStartAt,
            startAt,
            interestEndAt,
            endAt,
            claimEndAt
        );

        emit EpochTimesUpdated(
            msg.sender,
            epochId,
            oldSubscriptionStartAt,
            oldStartAt,
            oldInterestEndAt,
            oldEndAt,
            oldClaimEndAt,
            subscriptionStartAt,
            startAt,
            interestEndAt,
            endAt,
            claimEndAt
        );
    }

    function getEpochIdByStartAt(
        uint256 startAt
    ) external view virtual returns (uint256) {
        return store.epochIdByStartAt(startAt);
    }

    function isEpochOpen(uint256 epochId) external view virtual returns (bool) {
        return store.epochOpened(epochId);
    }

    function subscriptionEpochId() external view virtual returns (uint256) {
        return store.subscriptionEpochId();
    }

    function settleEpoch(uint256 apyBps, uint256 badDebtBps, uint256 epochId) external virtual onlyVault {
        (
            uint256 id,
            uint256 startAt,
            ,
            ,
            ,
            ,
            ,
            ,
            bool settled
        ) = store.epochs(epochId);
        if (id == 0) revert Errors.EpochNotFound();
        if (settled) revert Errors.EpochSettled();
        if (block.timestamp < startAt) revert Errors.InvalidEpochProgression();
        if (apyBps > BPS_DENOMINATOR || badDebtBps > BPS_DENOMINATOR) revert Errors.InvalidAPY();
        store.setEpochApyBps(epochId, apyBps);
        store.setEpochBadDebt(epochId, badDebtBps);
        store.setEpochSettled(epochId, true);
        emit EpochSettled(epochId, apyBps, badDebtBps);
    }

    function getEpoch(
        uint256 epochId
    )
        external
        view
        virtual
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
        (, startAt, subscriptionStartAt, interestEndAt, endAt, claimEndAt, apyBps, badDebtBps, settled) = store.epochs(epochId);
    }

    function forfeitedYield(
        uint256 principalPart,
        uint256 currentYield,
        uint256 epochApyBps,
        uint256 maturity,
        uint256 currentTs
    ) external pure virtual returns (uint256) {
        if (currentYield == 0) return 0;
        if (currentTs >= maturity) return 0;
        uint256 remaining = maturity - currentTs;
        uint256 remainingEquivalent = Math.mulDiv(
            principalPart * epochApyBps,
            remaining,
            BPS_DENOMINATOR * SECONDS_PER_YEAR,
            Math.Rounding.Floor
        );
        return
            currentYield < remainingEquivalent
                ? currentYield
                : remainingEquivalent;
    }

    function accruedYieldByEpochApy(
        uint256 principal,
        uint256 epochApyBps,
        uint256 epochStartAt,
        uint256 calcAt,
        uint256 epochEndAt
    ) external pure virtual returns (uint256) {
        if (principal == 0 || epochApyBps == 0) return 0;
        uint256 effectiveDuration = _effectiveStakingDuration(
            epochStartAt,
            calcAt,
            epochEndAt
        );
        if (effectiveDuration == 0) return 0;

        uint256 annualizedYield = Math.mulDiv(
            principal,
            epochApyBps,
            BPS_DENOMINATOR,
            Math.Rounding.Floor
        );
        return
            Math.mulDiv(
                annualizedYield,
                effectiveDuration,
                SECONDS_PER_YEAR,
                Math.Rounding.Floor
            );
    }

    function effectiveStakingDuration(
        uint256 epochStartAt,
        uint256 calcAt,
        uint256 epochEndAt
    ) external pure virtual returns (uint256) {
        return
            _effectiveStakingDuration(
                epochStartAt,
                calcAt,
                epochEndAt
            );
    }

    function _effectiveStakingDuration(
        uint256 epochStartAt,
        uint256 calcAt,
        uint256 epochEndAt
    ) internal pure returns (uint256) {
        if (epochEndAt <= epochStartAt) return 0;
        if (calcAt <= epochStartAt) return 0;

        uint256 cappedAt = calcAt > epochEndAt ? epochEndAt : calcAt;
        uint256 stakeDuration = cappedAt - epochStartAt;
        uint256 epochDuration = epochEndAt - epochStartAt;

        uint256 remaining = epochDuration - stakeDuration;
        if (stakeDuration <= remaining) return 0;
        uint256 effective = stakeDuration - remaining;
        return effective > epochDuration ? epochDuration : effective;
    }
}
