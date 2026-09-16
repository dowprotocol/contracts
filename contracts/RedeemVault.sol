// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultConfig} from "./VaultConfig.sol";
import {DowConfig} from "./DowConfig.sol";
import {VaultActivityLogger} from "./VaultActivityLogger.sol";
import {VaultStore} from "./VaultStore.sol";
import {EarlyWithdrawReview} from "./EarlyWithdrawReview.sol";
import {VaultCommonBase} from "./VaultCommonBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Errors} from "./Errors.sol";

interface IVaultDRTRef {
    function totalSupply() external view returns (uint256);

    function burn(address from, uint256 amount) external;
}

interface IVaultFundingRef {
    function fundRedeemVault(address asset, uint256 amount) external;
}

interface IVaultDrtSyncRef {
    function syncRolledPositionDrt(
        address owner,
        uint256 fromEpochId,
        uint256 toEpochId,
        uint256 shares
    ) external;
}

contract RedeemVault is VaultCommonBase, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint8 internal constant SOURCE_EARLY = 0;
    uint8 internal constant REWARD_EARLY_IMMEDIATE = 0;
    uint8 internal constant REWARD_EARLY_RETAINED = 1;
    uint8 internal constant REWARD_EARLY_YIELD = 2;

    struct MaturityPayoutQuote {
        uint256 principalPart;
        uint256 protocolFee;
        address protocolFeeReceiver;
        uint256 fundAmount;
        uint256 userPayout;
    }

    address public vault;
    EarlyWithdrawReview public earlyWithdrawReview;
    mapping(uint256 => uint256) public earlyWithdrawClaimInitialApyBps;
    mapping(uint256 => uint256) public earlyWithdrawRequestApyBps;
    mapping(uint256 => uint256) private maturityClaimDirectClaimableAtByEpoch;
    uint256 internal constant DEFAULT_MATURITY_CLAIM_REVIEW_WINDOW = 7 days;
    mapping(uint256 => uint256) private maturityClaimReviewWindowByEpoch;

    event PositionAutoRolled(
        uint256 indexed positionId,
        address indexed user,
        uint256 newEpochId
    );
    event EarlyWithdrawRequested(
        uint256 indexed requestId,
        uint256 indexed positionId,
        address indexed requester,
        uint256 reviewDeadline
    );
    event EarlyWithdrawOpened(
        uint256 indexed claimId,
        uint256 indexed positionId,
        address indexed seller,
        uint256 immediatePrincipal,
        uint256 retainedPrincipal,
        uint256 forfeitedYield
    );
    event EarlyWithdrawTaken(
        uint256 indexed claimId,
        uint256 indexed positionId,
        address indexed seller,
        address buyer
    );
    event EarlyWithdrawSellerClaimed(
        uint256 indexed claimId,
        address indexed seller,
        uint256 amount
    );
    event EarlyWithdrawImmediateClaimed(
        uint256 indexed claimId,
        address indexed seller,
        uint256 amount
    );
    event EarlyWithdrawBuyerClaimed(
        uint256 indexed claimId,
        address indexed buyer,
        uint256 amount
    );
    event MaturityClaimFulfilled(
        uint256 indexed requestId,
        uint256 indexed positionId,
        address indexed owner,
        uint256 payout
    );
    event MaturityClaimDirectModeUpdated(
        uint256 indexed epochId,
        bool enabled,
        uint256 claimableAt
    );
    event YieldClaimed(
        uint256 indexed positionId,
        address indexed owner,
        uint256 netYield,
        uint256 fee
    );

    modifier onlyReviewContract() {
        if (msg.sender != address(earlyWithdrawReview))
            revert Errors.NotAuthorized();
        _;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert Errors.NotAuthorized();
        _;
    }

    modifier onlyEmergencyRedeemReviewer() {
        if (!vaultConfig.emergencyRedeemReviewer(msg.sender)) {
            revert Errors.NotAuthorized();
        }
        _;
    }

    constructor(address _vault, address _store, address _vaultConfig) {
        _notZeroAddress(_vault);
        _notZeroAddress(_store);
        _notZeroAddress(_vaultConfig);
        vault = _vault;
        store = VaultStore(_store);
        vaultConfig = VaultConfig(_vaultConfig);
    }

    function _scaleYieldBySettledApy(
        uint256 yieldAmount,
        uint256 claimId,
        uint256 epochId
    ) internal view returns (uint256) {
        uint256 initialApy = earlyWithdrawClaimInitialApyBps[claimId];
        if (initialApy == 0) return yieldAmount;
        (, , , , , uint256 settledApy, , ) = _getEpoch(epochId);
        if (settledApy >= initialApy) return yieldAmount;
        return
            Math.mulDiv(
                yieldAmount,
                settledApy,
                initialApy,
                Math.Rounding.Floor
            );
    }

    function _burnDrtForPrincipal(
        address owner,
        uint256 epochId,
        IERC20 asset,
        uint256 principalAmount
    ) internal {
        uint256 drtAmount = _assetToDrtAmount(asset, principalAmount);
        if (drtAmount == 0) return;
        IVaultDRTRef(address(_drtTokenRefByEpoch(epochId))).burn(
            owner,
            drtAmount
        );
    }

    function _loadEarlyWithdrawClaim(
        uint256 claimId
    ) internal view returns (VaultStore.EarlyWithdrawClaim memory t) {
        (
            t.id,
            t.positionId,
            t.seller,
            t.underlyingAsset,
            t.epochId,
            t.immediatePrincipal,
            t.immediateClaimableAfter,
            t.retainedPrincipal,
            t.sellerYieldAfterPenalty,
            t.forfeitedYield,
            t.forfeitedYieldFee,
            t.maturity,
            t.buyer,
            t.immediateClaimed,
            t.sellerClaimed,
            t.buyerClaimed
        ) = store.earlyWithdrawClaims(claimId);
    }

    function _latestEpochEndAt(
        uint256 epochId
    ) internal view returns (uint256 endAt) {
        (, , , endAt, , , , ) = _getEpoch(epochId);
        if (endAt == 0) revert Errors.EpochNotFound();
    }

    function _transferProtocolFeeTo(
        IERC20 feeAsset,
        address receiver,
        uint256 fee
    ) internal {
        if (fee == 0) return;
        _sendProtocolFee(feeAsset, receiver, fee);
    }

    function _sendProtocolFee(
        IERC20 feeAsset,
        address receiver,
        uint256 fee
    ) private {
        feeAsset.safeTransfer(receiver, fee);
    }

    function _requireApprovedEarlyWithdrawPosition(
        VaultStore.EarlyWithdrawClaim memory t,
        uint256 claimId
    ) internal view {
        if (
            store.approvedEarlyWithdrawClaimIdByPosition(t.positionId) !=
            claimId
        ) revert Errors.InvalidClaimId();
        if (!store.positionEarlyWithdrawn(t.positionId)) {
            revert Errors.PositionNotEarlyWithdrawn();
        }
        VaultStore.Position memory p = _loadPosition(t.positionId);
        if (p.id == 0) revert Errors.VaultRecordNotFound();
        if (
            p.status != VaultStore.PositionStatus.EarlyWithdrawApproved &&
            p.status != VaultStore.PositionStatus.Redeemed
        ) {
            revert Errors.InvalidPositionStatus();
        }
    }

    function syncStoreCore() external {
        vaultConfig.onlyVaultOwner(msg.sender);
        store.setCoreRefs(address(vaultConfig), vaultConfig.vaultName());
        if (store.nextPositionId() == 0) {
            store.setCounters(1, 1, 1);
        }
    }

    function bindVault(address newVault) external {
        vaultConfig.onlyVaultOwner(msg.sender);
        _notZeroAddress(newVault);
        vault = newVault;
    }

    function setEarlyWithdrawReview(address reviewAddress) external {
        vaultConfig.onlyVaultOwner(msg.sender);
        _notZeroAddress(reviewAddress);
        earlyWithdrawReview = EarlyWithdrawReview(reviewAddress);
    }

    function setMaturityClaimDirectMode(
        uint256 epochId,
        bool enabled,
        uint256 claimableAt
    ) external {
        vaultConfig.onlyVaultOwner(msg.sender);
        if (epochId == 0) revert Errors.InvalidEpochId();
        if (enabled && claimableAt == 0) revert Errors.InvalidZeroAmount();
        uint256 storedClaimableAt = enabled ? claimableAt : 0;
        maturityClaimDirectClaimableAtByEpoch[epochId] = storedClaimableAt;
        emit MaturityClaimDirectModeUpdated(
            epochId,
            enabled,
            storedClaimableAt
        );
    }

    function setMaturityClaimReviewWindow(
        uint256 epochId,
        uint256 window
    ) external {
        vaultConfig.onlyVaultOwner(msg.sender);
        if (epochId == 0) revert Errors.InvalidEpochId();
        if (window == 0) revert Errors.InvalidZeroAmount();
        maturityClaimReviewWindowByEpoch[epochId] = window;
    }

    function getMaturityClaimPolicy(
        uint256 epochId
    ) external view returns (bool reviewRequired, uint256 directClaimableAt) {
        directClaimableAt = maturityClaimDirectClaimableAtByEpoch[epochId];
        reviewRequired = directClaimableAt == 0 || block.timestamp < directClaimableAt;
    }

    function seedEarlyWithdrawClaimInitialApyBps(
        uint256 claimId,
        uint256 apyBps
    ) external {
        vaultConfig.onlyVaultOwner(msg.sender);
        earlyWithdrawClaimInitialApyBps[claimId] = apyBps;
    }

    function _ensureNoPendingEarlyWithdraw(uint256 positionId) internal {
        if (address(earlyWithdrawReview) == address(0)) return;
        uint256 pendingReqId = store.pendingEarlyWithdrawRequestIdByPosition(
            positionId
        );
        if (pendingReqId == 0) return;
        EarlyWithdrawReview.RequestStatus status = earlyWithdrawReview
            .getEffectiveStatus(address(this), pendingReqId);
        if (status != EarlyWithdrawReview.RequestStatus.Pending) {
            store.clearPendingEarlyWithdrawRequestIdByPosition(positionId);
            _recordUserPosition(positionId);
            return;
        }
        revert Errors.InvalidPendingEarlyWithdrawRequest();
    }

    function _ensureNoActiveMaturityClaim(uint256 positionId) internal {
        uint256 requestId = store.activeMaturityClaimRequestIdByPosition(
            positionId
        );
        if (requestId == 0) return;
        EarlyWithdrawReview.RequestStatus status = _maturityRequestStatus(
            requestId
        );
        if (status == EarlyWithdrawReview.RequestStatus.Rejected) {
            store.clearActiveMaturityClaimRequestIdByPosition(positionId);
            return;
        }
        revert Errors.InvalidRequestStatus();
    }

    function _maturityRequestStatus(
        uint256 requestId
    ) internal view returns (EarlyWithdrawReview.RequestStatus status) {
        if (address(earlyWithdrawReview) == address(0)) {
            revert Errors.InvalidRequestStatus();
        }
        try
            earlyWithdrawReview.getMaturityClaimEffectiveStatus(
                address(this),
                requestId
            )
        returns (EarlyWithdrawReview.RequestStatus effectiveStatus) {
            status = effectiveStatus;
        } catch {
            revert Errors.InvalidRequestStatus();
        }
    }

    function _maturityDirectEnabled(
        uint256 epochId
    ) internal view returns (bool enabled, uint256 claimableAt) {
        claimableAt = maturityClaimDirectClaimableAtByEpoch[epochId];
        enabled = claimableAt != 0;
    }

    function _approvedMaturityRequestIdOrClear(
        uint256 positionId
    ) internal returns (uint256 requestId) {
        requestId = store.activeMaturityClaimRequestIdByPosition(positionId);
        if (requestId == 0) return 0;
        EarlyWithdrawReview.RequestStatus status = _maturityRequestStatus(
            requestId
        );
        if (status == EarlyWithdrawReview.RequestStatus.Approved) {
            return requestId;
        }
        if (status == EarlyWithdrawReview.RequestStatus.Rejected) {
            store.clearActiveMaturityClaimRequestIdByPosition(positionId);
            _recordUserPosition(positionId);
            return 0;
        }
        revert Errors.InvalidRequestStatus();
    }

    function _quoteMaturityPayout(
        uint256 positionId,
        VaultStore.Position memory p
    ) internal view returns (MaturityPayoutQuote memory q) {
        (
            ,
            ,
            ,
            uint256 epochEndAt,
            ,
            uint256 epochApyBps,
            uint256 badDebtBps,
            bool settled
        ) = _getEpoch(p.epochId);
        if (block.timestamp < epochEndAt) revert Errors.RedeemTooEarly();
        if (!settled) revert Errors.EpochNotSettled();

        (
            uint256 snapshotStartAt,
            uint256 snapshotEndAt,
            uint256 snapshotInterestEndAt
        ) = _positionSnapshotTimes(positionId, p);
        if (badDebtBps > BPS_DENOMINATOR) badDebtBps = BPS_DENOMINATOR;
        q.principalPart = p.principalAmount;
        uint256 principalAfterBadDebt = Math.mulDiv(
            p.principalAmount,
            BPS_DENOMINATOR - badDebtBps,
            BPS_DENOMINATOR,
            Math.Rounding.Floor
        );
        uint256 grossYield =
            p.accumulatedYield +
            _accruedYieldByEpochApy(
                p.principalAmount,
                epochApyBps,
                snapshotStartAt,
                snapshotEndAt,
                snapshotInterestEndAt
            );
        q.protocolFee = _previewProtocolFee(grossYield);
        q.protocolFeeReceiver = vaultConfig.dowConfig().protocol_fee_receiver();
        q.fundAmount = principalAfterBadDebt + grossYield;
        q.userPayout = q.fundAmount - q.protocolFee;
    }

    function ensureNoPendingEarlyWithdraw(
        uint256 positionId
    ) external onlyVault {
        _ensureNoPendingEarlyWithdraw(positionId);
    }

    function _beforeRollPositionEpochSwitch(
        VaultStore.Position memory p,
        uint256 newEpochId
    ) internal override {
        IVaultDrtSyncRef(vault).syncRolledPositionDrt(
            p.owner,
            p.epochId,
            newEpochId,
            p.shares
        );
    }

    function _emitPositionAutoRolled(
        uint256 positionId,
        address owner,
        uint256 newEpochId
    ) internal override {
        emit PositionAutoRolled(positionId, owner, newEpochId);
    }

    function _collectProtocolFee(
        IERC20 feeAsset,
        uint256 interestAmount
    ) internal returns (uint256 fee) {
        fee = _previewProtocolFee(interestAmount);
        _transferProtocolFee(feeAsset, fee);
    }

    function _previewProtocolFee(
        uint256 interestAmount
    ) internal view returns (uint256 fee) {
        DowConfig dc = vaultConfig.dowConfig();
        uint256 feeBps = dc.protocol_fee_bps();
        if (feeBps == 0 || dc.protocol_fee_receiver() == address(0)) return 0;
        fee = Math.mulDiv(
            interestAmount,
            feeBps,
            BPS_DENOMINATOR,
            Math.Rounding.Floor
        );
    }

    function _transferProtocolFee(IERC20 feeAsset, uint256 fee) internal {
        if (fee == 0) return;
        address receiver = vaultConfig.dowConfig().protocol_fee_receiver();
        _sendProtocolFee(feeAsset, receiver, fee);
    }

    function _recordUserPosition(uint256 positionId) internal override {
        if (address(_activityLoggerRef()) == address(0)) return;
        VaultStore.Position memory p = _loadPosition(positionId);
        if (p.owner == address(0)) return;
        (
            uint256 displayAmt,
            bool displayIsEarlyWithdrawn
        ) = _loggerDisplayByPosition(positionId, p.principalAmount);
        (
            bool isEarlyWithdrawRequested,
            uint8 earlyWithdrawReviewStatus
        ) = _positionEarlyWithdrawStatus(positionId);
        uint256 apy = _currentApyBps() > 0
            ? _currentApyBps()
            : vaultConfig.baseApyBps();
        _activityLoggerRef().recordUserPosition(
            p.owner,
            vault,
            store.vaultName(),
            positionId,
            p.epochId,
            p.lockupEndTime,
            p.underlyingAsset,
            displayAmt,
            apy,
            displayIsEarlyWithdrawn,
            isEarlyWithdrawRequested,
            earlyWithdrawReviewStatus,
            p.autoRoll
        );
    }

    function _applyBadDebtTvlLoss(
        address /*vault_*/,
        address asset,
        uint256 principalBefore,
        uint256 principalAfter
    ) internal override {
        if (principalAfter >= principalBefore) return;
        _decreaseTvlOrRevert(
            vault,
            IERC20(asset),
            principalBefore - principalAfter
        );
    }

    function _ensurePayoutLiquidity(address asset, uint256 amount) internal {
        IERC20 ua = IERC20(asset);
        uint256 balance = ua.balanceOf(address(this));
        if (balance < amount) {
            IVaultFundingRef(vault).fundRedeemVault(asset, amount - balance);
            balance = ua.balanceOf(address(this));
        }
        if (balance < amount) revert Errors.InsufficientLiquidity();
    }

    function requestMaturityClaim(
        uint256 positionId
    ) external nonReentrant returns (uint256 requestId) {
        vaultConfig.onlyProtocolAndVaultOn();
        VaultStore.Position memory p = _loadPosition(positionId);
        if (p.owner == address(0)) revert Errors.VaultRecordNotFound();
        if (p.owner != msg.sender) revert Errors.NotPositionOwner();
        if (p.status != VaultStore.PositionStatus.Active || p.shares == 0)
            revert Errors.PositionClosed();
        _ensureNoActiveMaturityClaim(positionId);
        _ensureNoPendingEarlyWithdraw(positionId);
        p = _rollPositionIfNeeded(vault, positionId, p);
        if (p.autoRoll) revert Errors.PositionAutoRolled();
        (bool directEnabled, uint256 directClaimableAt) = _maturityDirectEnabled(p.epochId);
        if (directEnabled && block.timestamp >= directClaimableAt)
            revert Errors.InvalidRequestStatus();

        MaturityPayoutQuote memory q = _quoteMaturityPayout(positionId, p);

        if (address(earlyWithdrawReview) == address(0))
            revert Errors.InvalidZeroAddress();
        requestId = store.consumeNextEarlyWithdrawRequestId();
        uint256 reviewWindow = maturityClaimReviewWindowByEpoch[p.epochId];
        if (reviewWindow == 0) reviewWindow = DEFAULT_MATURITY_CLAIM_REVIEW_WINDOW;
        uint256 reviewDeadline = block.timestamp + reviewWindow;
        if (directEnabled && reviewDeadline >= directClaimableAt) {
            reviewDeadline = directClaimableAt - 1;
        }
        earlyWithdrawReview.createMaturityClaimRequest(
            requestId,
            positionId,
            msg.sender,
            p.underlyingAsset,
            p.epochId,
            q.fundAmount,
            q.protocolFee,
            q.protocolFeeReceiver,
            block.timestamp,
            reviewDeadline
        );
        store.setActiveMaturityClaimRequestIdByPosition(positionId, requestId);
    }

    function _loggerDisplayByPosition(
        uint256 positionId,
        uint256 principalAmount
    ) internal view returns (uint256 displayAmt, bool displayIsEarlyWithdrawn) {
        displayAmt = principalAmount;
        displayIsEarlyWithdrawn = store.positionEarlyWithdrawn(positionId);
        if (!displayIsEarlyWithdrawn)
            return (displayAmt, displayIsEarlyWithdrawn);
        uint256 claimId = store.approvedEarlyWithdrawClaimIdByPosition(
            positionId
        );
        if (claimId == 0) return (displayAmt, displayIsEarlyWithdrawn);
        VaultStore.EarlyWithdrawClaim memory claim = _loadEarlyWithdrawClaim(claimId);
        if (!claim.immediateClaimed) {
            displayAmt = claim.immediatePrincipal;
            displayIsEarlyWithdrawn = false;
        }
    }

    function earlyWithdraw(
        uint256 positionId
    ) external nonReentrant returns (uint256 requestId) {
        vaultConfig.onlyProtocolAndVaultOn();
        VaultStore.Position memory p = _loadPosition(positionId);
        if (p.owner != msg.sender) revert Errors.NotPositionOwner();
        if (p.status != VaultStore.PositionStatus.Active || p.shares == 0)
            revert Errors.PositionClosed();
        _ensureNoPendingEarlyWithdraw(positionId);
        if (store.activeMaturityClaimRequestIdByPosition(positionId) != 0)
            revert Errors.InvalidRequestStatus();
        p = _rollPositionIfNeeded(vault, positionId, p);
        (
            uint256 epochStartAt,
            ,
            ,
            uint256 epochEndAt,
            ,
            uint256 epochApyBps,
            ,

        ) = _getEpoch(p.epochId);
        if (block.timestamp < epochStartAt) revert Errors.RedeemTooEarly();
        if (block.timestamp >= epochEndAt) revert Errors.LockupEnded();
        if (p.autoRoll) {
            p.autoRoll = false;
            _savePosition(p);
        }
        (
            uint256 snapshotStartAt,
            uint256 snapshotEndAt,
            uint256 snapshotInterestEndAt
        ) = _positionSnapshotTimes(positionId, p);

        (
            uint256 immediatePrincipal,
            uint256 retainedPrincipal,
            uint256 sellerYieldAfterPenalty,
            uint256 forfeitedYieldGross
        ) = _calcEarlyWithdrawTerms(
                p.principalAmount,
                epochApyBps,
                snapshotStartAt,
                snapshotEndAt,
                snapshotInterestEndAt
            );

        if (address(earlyWithdrawReview) == address(0))
            revert Errors.InvalidZeroAddress();
        requestId = store.consumeNextEarlyWithdrawRequestId();
        uint256 reviewDeadline = block.timestamp + 14 days;
        if (reviewDeadline > epochEndAt) {
            reviewDeadline = epochEndAt;
        }
        earlyWithdrawReview.createRequest(
            requestId,
            positionId,
            msg.sender,
            p.underlyingAsset,
            p.epochId,
            epochEndAt,
            immediatePrincipal,
            retainedPrincipal,
            sellerYieldAfterPenalty,
            forfeitedYieldGross,
            block.timestamp,
            reviewDeadline
        );
        store.setPendingEarlyWithdrawRequestIdByPosition(positionId, requestId);
        earlyWithdrawRequestApyBps[requestId] = epochApyBps;
        if (address(_activityLoggerRef()) != address(0)) {
            _activityLoggerRef().recordAction(
                msg.sender,
                VaultActivityLogger.UserActionType.EarlyWithdrawRequest,
                immediatePrincipal,
                p.underlyingAsset,
                address(_drtTokenRefByEpoch(p.epochId)),
                p.shares
            );
        }
        _recordUserPosition(positionId);
        emit EarlyWithdrawRequested(
            requestId,
            positionId,
            msg.sender,
            reviewDeadline
        );
    }

    function claimEarlyWithdrawImmediate(
        uint256 positionId
    ) external nonReentrant {
        uint256 claimId = store.approvedEarlyWithdrawClaimIdByPosition(
            positionId
        );
        if (claimId == 0) revert Errors.VaultRecordNotFound();
        _claimEarlyWithdrawImmediate(claimId);
    }

    function _claimEarlyWithdrawImmediate(uint256 claimId) internal {
        VaultStore.EarlyWithdrawClaim memory t = _loadEarlyWithdrawClaim(
            claimId
        );
        if (t.id == 0) revert Errors.VaultRecordNotFound();
        _requireApprovedEarlyWithdrawPosition(t, claimId);
        if (t.seller != msg.sender) revert Errors.NotOwner();
        if (t.immediateClaimed) revert Errors.RedeemDone();
        if (block.timestamp < t.immediateClaimableAfter)
            revert Errors.RedeemTooEarly();
        IERC20 ua = IERC20(t.underlyingAsset);
        _ensurePayoutLiquidity(t.underlyingAsset, t.immediatePrincipal);
        store.setEarlyWithdrawClaimImmediateClaimed(claimId, true);
        ua.safeTransfer(msg.sender, t.immediatePrincipal);
        _burnDrtForPrincipal(t.seller, t.epochId, ua, t.immediatePrincipal);
        _decreaseTvlOrRevert(vault, ua, t.immediatePrincipal);
        _decreaseUserStakedAmountOrRevert(
            vault,
            t.seller,
            ua,
            t.immediatePrincipal
        );
        if (address(_activityLoggerRef()) != address(0)) {
            _activityLoggerRef().claimClaimableReward(
                SOURCE_EARLY,
                claimId,
                REWARD_EARLY_IMMEDIATE
            );
            _recordUserPosition(t.positionId);
        }
        emit EarlyWithdrawImmediateClaimed(
            claimId,
            msg.sender,
            t.immediatePrincipal
        );
    }

    function claimYield(uint256 positionId) external nonReentrant {
        vaultConfig.onlyProtocolAndVaultOn();
        VaultStore.Position memory p = _loadPosition(positionId);
        if (p.id == 0) revert Errors.VaultRecordNotFound();
        if (p.owner != msg.sender) revert Errors.NotPositionOwner();
        if (p.status == VaultStore.PositionStatus.Active)
            revert Errors.InvalidPositionStatus();

        uint256 yieldAmount = p.accumulatedYield;
        if (yieldAmount == 0) revert Errors.NothingToClaim();

        IERC20 ua = IERC20(p.underlyingAsset);
        _ensurePayoutLiquidity(p.underlyingAsset, yieldAmount);

        uint256 fee = _collectProtocolFee(ua, yieldAmount);
        uint256 netYield = yieldAmount - fee;

        p.accumulatedYield = 0;
        _savePosition(p);
        _recordUserPosition(positionId);

        ua.safeTransfer(msg.sender, netYield);

        emit YieldClaimed(positionId, msg.sender, netYield, fee);
    }

    function transferReviewFundOut(
        address asset,
        address to,
        uint256 amount
    ) external onlyReviewContract {
        _ensurePayoutLiquidity(asset, amount);
        IERC20(asset).safeTransfer(to, amount);
    }

    function sweepToVault(address asset, uint256 amount) external {
        if (!vaultConfig.strategyManager(msg.sender))
            revert Errors.NotStrategyManager();
        if (amount == 0) revert Errors.InvalidZeroAmount();
        IERC20(asset).safeTransfer(vault, amount);
    }

    function onEarlyWithdrawApproved(
        uint256 requestId,
        address reviewer,
        uint256 positionId,
        address requester,
        address underlyingAsset_,
        uint256 epochId,
        uint256 maturity,
        uint256 requestedAt,
        uint256 immediatePrincipal,
        uint256 retainedPrincipal,
        uint256 sellerYieldAfterPenalty,
        uint256 forfeitedYield
    ) external onlyReviewContract returns (uint256 claimId) {
        claimId = _approveEarlyWithdrawRequest(
            requestId,
            reviewer,
            positionId,
            requester,
            underlyingAsset_,
            epochId,
            maturity,
            requestedAt,
            immediatePrincipal,
            retainedPrincipal,
            sellerYieldAfterPenalty,
            forfeitedYield
        );
    }

    function onEarlyWithdrawRejected(
        uint256 requestId,
        uint256 positionId
    ) external onlyReviewContract {
        uint256 pending = store.pendingEarlyWithdrawRequestIdByPosition(
            positionId
        );
        if (pending != requestId)
            revert Errors.InvalidPendingEarlyWithdrawRequest();
        store.clearPendingEarlyWithdrawRequestIdByPosition(positionId);
        _recordUserPosition(positionId);
    }

    function onMaturityClaimRejected(
        uint256 requestId,
        uint256 positionId
    ) external onlyReviewContract {
        if (
            store.activeMaturityClaimRequestIdByPosition(positionId) !=
            requestId
        ) revert Errors.InvalidRequestId();
        store.clearActiveMaturityClaimRequestIdByPosition(positionId);
    }

    function takeEarlyWithdrawClaim(
        uint256 claimId,
        address buyer
    ) external nonReentrant {
        if (!vaultConfig.strategyManager(msg.sender))
            revert Errors.NotStrategyManager();
        if (buyer == address(0)) revert Errors.InvalidZeroAddress();
        VaultStore.EarlyWithdrawClaim memory t = _loadEarlyWithdrawClaim(
            claimId
        );
        if (t.id == 0) revert Errors.VaultRecordNotFound();
        _requireApprovedEarlyWithdrawPosition(t, claimId);
        if (t.buyer != address(0)) revert Errors.InvalidBuyer();

        IERC20 ua = IERC20(t.underlyingAsset);
        ua.safeTransferFrom(msg.sender, vault, t.immediatePrincipal);
        _increaseTvl(vault, ua, t.immediatePrincipal);
        store.setEarlyWithdrawClaimBuyer(claimId, buyer);

        if (address(_activityLoggerRef()) != address(0)) {
            _activityLoggerRef().requestClaimableReward(
                buyer,
                SOURCE_EARLY,
                claimId,
                REWARD_EARLY_YIELD,
                0,
                t.forfeitedYield,
                t.maturity
            );
            _recordUserPosition(t.positionId);
        }
        emit EarlyWithdrawTaken(claimId, t.positionId, t.seller, buyer);
    }

    function claimEarlyWithdrawBuyer(uint256 claimId) external nonReentrant {
        vaultConfig.onlyProtocolAndVaultOn();
        VaultStore.EarlyWithdrawClaim memory t = _loadEarlyWithdrawClaim(
            claimId
        );
        if (t.id == 0) revert Errors.VaultRecordNotFound();
        _requireApprovedEarlyWithdrawPosition(t, claimId);
        if (t.buyer != msg.sender) revert Errors.NotOwner();
        if (t.buyerClaimed) revert Errors.RedeemDone();
        if (block.timestamp < _latestEpochEndAt(t.epochId))
            revert Errors.RedeemTooEarly();

        uint256 fullPrincipal = t.immediatePrincipal + t.retainedPrincipal;
        uint256 fullAfterBadDebt = _principalAfterEpochBadDebt(
            t.epochId,
            fullPrincipal,
            true
        );
        uint256 totalBadDebt = fullPrincipal - fullAfterBadDebt;
        uint256 buyerBadDebt = totalBadDebt > t.retainedPrincipal
            ? totalBadDebt - t.retainedPrincipal
            : 0;
        uint256 scaledForfeitedYield = _scaleYieldBySettledApy(
            t.forfeitedYield,
            claimId,
            t.epochId
        );
        uint256 scaledForfeitedYieldFee = _scaleYieldBySettledApy(
            t.forfeitedYieldFee,
            claimId,
            t.epochId
        );
        uint256 amount = (t.immediatePrincipal - buyerBadDebt) +
            scaledForfeitedYield;
        uint256 totalPayout = amount + scaledForfeitedYieldFee;

        IERC20 ua = IERC20(t.underlyingAsset);
        _ensurePayoutLiquidity(t.underlyingAsset, totalPayout);

        store.setEarlyWithdrawClaimBuyerClaimed(claimId, true);
        _transferProtocolFee(ua, scaledForfeitedYieldFee);
        ua.safeTransfer(msg.sender, amount);
        _decreaseTvlOrRevert(vault, ua, t.immediatePrincipal);

        if (address(_activityLoggerRef()) != address(0)) {
            _activityLoggerRef().claimClaimableReward(
                SOURCE_EARLY,
                claimId,
                REWARD_EARLY_YIELD
            );
        }

        emit EarlyWithdrawBuyerClaimed(claimId, msg.sender, amount);
    }

    function fulfillClaim(uint256 positionId) external nonReentrant {
        _fulfillMatureClaimByPosition(positionId, false);
    }

    function cleanupEarlyWithdrawSeller(uint256 claimId) external nonReentrant {
        if (!vaultConfig.strategyManager(msg.sender))
            revert Errors.NotStrategyManager();
        _claimEarlyWithdrawSellerByClaim(claimId, false);
    }

    function emergencyFulfillClaim(
        uint256 positionId
    ) external nonReentrant onlyEmergencyRedeemReviewer {
        _fulfillMatureClaimByPosition(positionId, true);
    }

    function _closeMaturityPosition(
        uint256 requestId,
        uint256 positionId,
        VaultStore.Position memory p,
        MaturityPayoutQuote memory q
    ) internal {
        uint256 sharesToBurn = p.shares;
        IERC20 ua = IERC20(p.underlyingAsset);
        _ensurePayoutLiquidity(p.underlyingAsset, q.fundAmount);

        p.shares = 0;
        p.principalAmount = 0;
        p.accumulatedYield = 0;
        p.status = VaultStore.PositionStatus.Redeemed;
        _savePosition(p);
        store.clearActiveMaturityClaimRequestIdByPosition(positionId);
        _recordUserPosition(positionId);

        if (sharesToBurn > 0) {
            IVaultDRTRef(address(_drtTokenRefByEpoch(p.epochId))).burn(
                p.owner,
                sharesToBurn
            );
        }
        _decreaseTvlOrRevert(vault, ua, q.principalPart);
        _decreaseUserStakedAmountOrRevert(vault, p.owner, ua, q.principalPart);
        _transferProtocolFeeTo(ua, q.protocolFeeReceiver, q.protocolFee);
        ua.safeTransfer(p.owner, q.userPayout);

        if (address(_activityLoggerRef()) != address(0)) {
            _activityLoggerRef().recordAction(
                p.owner,
                VaultActivityLogger.UserActionType.FulfillRedeem,
                q.userPayout,
                p.underlyingAsset,
                address(_drtTokenRefByEpoch(p.epochId)),
                0
            );
        }
        emit MaturityClaimFulfilled(requestId, positionId, p.owner, q.userPayout);
    }

    function _fulfillMatureClaimByPosition(
        uint256 positionId,
        bool emergencyMode
    ) internal {
        if (!emergencyMode) {
            vaultConfig.onlyProtocolAndVaultOn();
        }
        VaultStore.Position memory p = _loadPosition(positionId);
        if (p.owner == address(0)) revert Errors.VaultRecordNotFound();
        if (!emergencyMode && p.owner != msg.sender)
            revert Errors.NotPositionOwner();
        if (store.positionEarlyWithdrawn(positionId)) {
            _claimEarlyWithdrawSellerByPosition(positionId, emergencyMode);
            return;
        }
        uint256 requestId = _approvedMaturityRequestIdOrClear(positionId);
        if (requestId != 0) {
            EarlyWithdrawReview.MaturityRequest memory r = earlyWithdrawReview
                .getMaturityClaimRequest(address(this), requestId);
            if (
                r.positionId != positionId ||
                r.status != EarlyWithdrawReview.RequestStatus.Approved
            ) revert Errors.InvalidRequestStatus();
            if (p.status != VaultStore.PositionStatus.Active || p.shares == 0) {
                revert Errors.PositionClosed();
            }

            MaturityPayoutQuote memory q = MaturityPayoutQuote({
                principalPart: p.principalAmount,
                protocolFee: r.protocolFee,
                protocolFeeReceiver: r.protocolFeeReceiver,
                fundAmount: r.fundAmount,
                userPayout: r.fundAmount - r.protocolFee
            });
            _closeMaturityPosition(requestId, positionId, p, q);
            return;
        }

        (bool directEnabled, uint256 directClaimableAt) = _maturityDirectEnabled(
            p.epochId
        );
        if (!directEnabled) revert Errors.InvalidRequestStatus();
        if (block.timestamp < directClaimableAt) revert Errors.RedeemTooEarly();

        _ensureNoPendingEarlyWithdraw(positionId);
        p = _rollPositionIfNeeded(vault, positionId, p);
        if (p.autoRoll) revert Errors.PositionAutoRolled();
        if (p.status != VaultStore.PositionStatus.Active || p.shares == 0) {
            revert Errors.PositionClosed();
        }

        MaturityPayoutQuote memory directQuote = _quoteMaturityPayout(
            positionId,
            p
        );
        _closeMaturityPosition(0, positionId, p, directQuote);
    }

    function _claimEarlyWithdrawSellerByPosition(
        uint256 positionId,
        bool emergencyMode
    ) internal {
        uint256 claimId = store.approvedEarlyWithdrawClaimIdByPosition(
            positionId
        );
        if (claimId == 0) revert Errors.VaultRecordNotFound();
        _claimEarlyWithdrawSellerByClaim(claimId, emergencyMode);
    }

    function _claimEarlyWithdrawSellerByClaim(
        uint256 claimId,
        bool emergencyMode
    ) internal {
        VaultStore.EarlyWithdrawClaim memory t = _loadEarlyWithdrawClaim(
            claimId
        );
        if (t.id == 0) revert Errors.VaultRecordNotFound();
        _requireApprovedEarlyWithdrawPosition(t, claimId);
        if (t.sellerClaimed) revert Errors.RedeemDone();
        if (block.timestamp < _latestEpochEndAt(t.epochId))
            revert Errors.RedeemTooEarly();

        uint256 fullAfterBadDebt = _principalAfterEpochBadDebt(
            t.epochId,
            t.immediatePrincipal + t.retainedPrincipal,
            true
        );
        uint256 retainedAfterBadDebt = fullAfterBadDebt > t.immediatePrincipal
            ? fullAfterBadDebt - t.immediatePrincipal
            : 0;
        uint256 scaledSellerYield = _scaleYieldBySettledApy(
            t.sellerYieldAfterPenalty,
            claimId,
            t.epochId
        );
        uint256 amount = retainedAfterBadDebt + scaledSellerYield;

        if (!emergencyMode && amount > 0 && t.seller != msg.sender)
            revert Errors.NotOwner();

        IERC20 ua = IERC20(t.underlyingAsset);
        store.setEarlyWithdrawClaimSellerClaimed(claimId, true);
        if (amount > 0) {
            _ensurePayoutLiquidity(t.underlyingAsset, amount);
            ua.safeTransfer(t.seller, amount);
        }
        VaultStore.Position memory p = _loadPosition(t.positionId);
        uint256 immediateDrt = _assetToDrtAmount(ua, t.immediatePrincipal);
        uint256 remainingShares = p.shares > immediateDrt
            ? p.shares - immediateDrt
            : 0;
        if (remainingShares > 0) {
            IVaultDRTRef(address(_drtTokenRefByEpoch(t.epochId))).burn(
                t.seller,
                remainingShares
            );
        }
        _decreaseTvlOrRevert(vault, ua, t.retainedPrincipal);
        _decreaseUserStakedAmountOrRevert(
            vault,
            t.seller,
            ua,
            t.retainedPrincipal
        );

        p.shares = 0;
        p.principalAmount = 0;
        p.status = VaultStore.PositionStatus.Redeemed;
        _savePosition(p);
        _recordUserPosition(t.positionId);

        if (address(_activityLoggerRef()) != address(0)) {
            _activityLoggerRef().claimClaimableReward(
                SOURCE_EARLY,
                claimId,
                REWARD_EARLY_RETAINED
            );
        }

        emit EarlyWithdrawSellerClaimed(claimId, t.seller, amount);
    }

    function _calcEarlyWithdrawTerms(
        uint256 principalPart,
        uint256 epochApyBps,
        uint256 epochStartAt,
        uint256 endAt,
        uint256 interestEndAt
    )
        internal
        view
        returns (
            uint256 immediatePrincipal,
            uint256 retainedPrincipal,
            uint256 sellerYieldAfterPenalty,
            uint256 forfeitedYieldGross
        )
    {
        uint256 stakedDays = block.timestamp > epochStartAt
            ? (block.timestamp - epochStartAt) / 1 days
            : 0;

        immediatePrincipal = Math.mulDiv(
            principalPart,
            vaultConfig.earlyExitImmediatePrincipalBpsByStakedDays(stakedDays),
            BPS_DENOMINATOR,
            Math.Rounding.Floor
        );
        retainedPrincipal = principalPart - immediatePrincipal;

        uint256 cappedAt = block.timestamp < interestEndAt
            ? block.timestamp
            : interestEndAt;
        uint256 stakedSeconds = cappedAt > epochStartAt
            ? cappedAt - epochStartAt
            : 0;
        uint256 annualYield = Math.mulDiv(
            principalPart,
            epochApyBps,
            BPS_DENOMINATOR,
            Math.Rounding.Floor
        );
        uint256 currentYield = Math.mulDiv(
            annualYield,
            stakedSeconds,
            365 days,
            Math.Rounding.Floor
        );
        uint256 coefficientBps = vaultConfig
            .earlyExitYieldCoefficientBpsByStakedDays(stakedDays);
        sellerYieldAfterPenalty = Math.mulDiv(
            currentYield,
            coefficientBps,
            BPS_DENOMINATOR,
            Math.Rounding.Floor
        );

        // Keep seller/buyer/protocol allocations inside one shared yield pool.
        uint256 yieldEndAt = interestEndAt < endAt ? interestEndAt : endAt;
        uint256 yieldTotalDays = yieldEndAt > epochStartAt
            ? (yieldEndAt - epochStartAt) / 1 days
            : 0;
        uint256 cappedDays = stakedDays > yieldTotalDays
            ? yieldTotalDays
            : stakedDays;
        uint256 effectiveDays = cappedDays +
            Math.mulDiv(
                yieldTotalDays - cappedDays,
                BPS_DENOMINATOR - coefficientBps,
                BPS_DENOMINATOR,
                Math.Rounding.Floor
            );
        uint256 annualYieldOnPrincipal = Math.mulDiv(
            principalPart,
            epochApyBps,
            BPS_DENOMINATOR,
            Math.Rounding.Floor
        );
        uint256 totalEarlyExitYieldPool = Math.mulDiv(
            annualYieldOnPrincipal,
            effectiveDays,
            365,
            Math.Rounding.Floor
        );
        if (sellerYieldAfterPenalty > totalEarlyExitYieldPool) {
            sellerYieldAfterPenalty = totalEarlyExitYieldPool;
        }
        forfeitedYieldGross = totalEarlyExitYieldPool - sellerYieldAfterPenalty;
    }

    function _approveEarlyWithdrawRequest(
        uint256 requestId,
        address /*reviewer*/,
        uint256 positionId,
        address requester,
        address underlyingAsset_,
        uint256 epochId,
        uint256 maturity,
        uint256 /*requestedAt*/,
        uint256 immediatePrincipal,
        uint256 retainedPrincipal,
        uint256 sellerYieldAfterPenalty,
        uint256 forfeitedYield
    ) internal returns (uint256 claimId) {
        VaultStore.Position memory p = _loadPosition(positionId);
        if (p.owner != requester) revert Errors.NotPositionOwner();
        if (p.status != VaultStore.PositionStatus.Active || p.shares == 0)
            revert Errors.PositionClosed();
        if (
            store.pendingEarlyWithdrawRequestIdByPosition(positionId) !=
            requestId
        ) revert Errors.InvalidPendingEarlyWithdrawRequest();
        if (block.timestamp >= _latestEpochEndAt(epochId)) {
            revert Errors.LockupEnded();
        }

        uint256 forfeitFee = _previewProtocolFee(forfeitedYield);
        uint256 forfeitedYieldNet = forfeitedYield - forfeitFee;

        store.setPositionEarlyWithdrawn(positionId, true);
        p.status = VaultStore.PositionStatus.EarlyWithdrawApproved;
        _savePosition(p);
        _recordUserPosition(positionId);

        claimId = store.consumeNextEarlyWithdrawClaimId();
        earlyWithdrawClaimInitialApyBps[claimId] = earlyWithdrawRequestApyBps[
            requestId
        ];
        VaultStore.EarlyWithdrawClaim memory t = VaultStore.EarlyWithdrawClaim({
            id: claimId,
            positionId: positionId,
            seller: requester,
            underlyingAsset: underlyingAsset_,
            epochId: epochId,
            immediatePrincipal: immediatePrincipal,
            immediateClaimableAfter: block.timestamp +
                vaultConfig.earlyExitImmediateClaimDelay(),
            retainedPrincipal: retainedPrincipal,
            sellerYieldAfterPenalty: sellerYieldAfterPenalty,
            forfeitedYield: forfeitedYieldNet,
            forfeitedYieldFee: forfeitFee,
            maturity: maturity,
            buyer: address(0),
            immediateClaimed: false,
            sellerClaimed: false,
            buyerClaimed: false
        });
        store.upsertEarlyWithdrawClaim(
            t.id,
            t.positionId,
            t.seller,
            t.underlyingAsset,
            t.epochId,
            t.immediatePrincipal,
            t.immediateClaimableAfter,
            t.retainedPrincipal,
            t.sellerYieldAfterPenalty,
            t.forfeitedYield,
            t.forfeitedYieldFee,
            t.maturity,
            t.buyer,
            t.immediateClaimed,
            t.sellerClaimed,
            t.buyerClaimed
        );

        if (address(_activityLoggerRef()) != address(0)) {
            _activityLoggerRef().recordEarlyWithdrawClaimables(
                requester,
                claimId,
                t.immediatePrincipal,
                t.immediateClaimableAfter,
                t.retainedPrincipal,
                t.maturity
            );
        }

        store.setApprovedEarlyWithdrawClaimIdByPosition(positionId, claimId);
        store.clearPendingEarlyWithdrawRequestIdByPosition(positionId);
        emit EarlyWithdrawOpened(
            claimId,
            positionId,
            requester,
            t.immediatePrincipal,
            t.retainedPrincipal,
            t.forfeitedYield
        );
    }

    function _positionEarlyWithdrawStatus(
        uint256 positionId
    ) internal view returns (bool isRequested, uint8 reviewStatus) {
        uint256 requestId = store.pendingEarlyWithdrawRequestIdByPosition(
            positionId
        );
        if (requestId == 0 || address(earlyWithdrawReview) == address(0)) {
            return (false, 0);
        }
        isRequested = true;
        EarlyWithdrawReview.RequestStatus status = earlyWithdrawReview
            .getEffectiveStatus(address(this), requestId);
        if (status == EarlyWithdrawReview.RequestStatus.Pending) {
            reviewStatus = 1;
        } else if (status == EarlyWithdrawReview.RequestStatus.Approved) {
            reviewStatus = 2;
        } else {
            reviewStatus = 3;
        }
    }
}
