// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors} from "./Errors.sol";

interface IVaultEarlyWithdrawCallback {
    function onEarlyWithdrawApproved(
        uint256 requestId,
        address reviewer,
        uint256 positionId,
        address requester,
        address underlyingAsset,
        uint256 epochId,
        uint256 maturity,
        uint256 requestedAt,
        uint256 immediatePrincipal,
        uint256 retainedPrincipal,
        uint256 sellerYieldAfterPenalty,
        uint256 forfeitedYield
    ) external returns (uint256 claimId);

    function transferReviewFundOut(
        address asset,
        address to,
        uint256 amount
    ) external;

    function onEarlyWithdrawRejected(
        uint256 requestId,
        uint256 positionId
    ) external;

    function onMaturityClaimRejected(
        uint256 requestId,
        uint256 positionId
    ) external;
}

contract EarlyWithdrawReview is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant REVIEWER_MANAGER_ROLE =
        keccak256("REVIEWER_MANAGER_ROLE");
    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");

    enum RequestStatus {
        Pending,
        Approved,
        Rejected
    }

    enum ReviewerActionType {
        Deposit,
        Withdraw,
        Approve,
        Reject
    }

    struct Request {
        uint256 id;
        address vault;
        uint256 positionId;
        address requester;
        address underlyingAsset;
        uint256 epochId;
        uint256 maturity;
        uint256 immediatePrincipal;
        uint256 retainedPrincipal;
        uint256 sellerYieldAfterPenalty;
        uint256 forfeitedYield;
        uint256 requestedAt;
        uint256 reviewDeadline;
        uint256 reviewedAt;
        address reviewer;
        uint256 approvedClaimId;
        RequestStatus status;
    }

    struct MaturityRequest {
        uint256 id;
        address vault;
        uint256 positionId;
        address requester;
        address underlyingAsset;
        uint256 epochId;
        uint256 fundAmount;
        uint256 protocolFee;
        address protocolFeeReceiver;
        uint256 requestedAt;
        uint256 reviewDeadline;
        uint256 reviewedAt;
        address reviewer;
        RequestStatus status;
    }

    struct ReviewerAction {
        uint256 id;
        address vault;
        uint256 requestId;
        uint256 epochId;
        address requester;
        uint256 userPrincipal;
        uint256 approvedWithdrawPrincipal;
        address reviewer;
        ReviewerActionType actionType;
        uint256 amount;
        uint256 timestamp;
    }

    mapping(address => bool) public approvedVaults;
    mapping(address => mapping(address => bool)) public reviewersByVault;

    uint256 public nextActionId;

    mapping(address => mapping(uint256 => Request)) public requests;
    mapping(address => mapping(uint256 => MaturityRequest)) public maturityRequests;
    mapping(address => mapping(address => uint256[])) public userRequestIdsByVault;
    struct RequestRef {
        address vault;
        uint256 requestId;
    }
    RequestRef[] public allRequestRefs;
    RequestRef[] public allMaturityRequestRefs;

    mapping(address => mapping(uint256 => uint256)) public totalReviewFundByRequest;
    mapping(address => mapping(uint256 => mapping(address => uint256)))
        public reviewFundByRequestAndReviewer;
    mapping(address => mapping(uint256 => bool)) public reviewFundSettledByRequest;

    mapping(uint256 => ReviewerAction) public reviewerActions;
    mapping(address => uint256[]) public reviewerActionIds;
    uint256[] public allActionIds;

    event EarlyWithdrawRequested(
        uint256 indexed requestId,
        address indexed vault,
        uint256 indexed positionId,
        address requester,
        uint256 reviewDeadline
    );
    event EarlyWithdrawRequestReviewed(
        uint256 indexed requestId,
        uint256 indexed positionId,
        address indexed reviewer,
        bool approved
    );
    event EarlyWithdrawReviewFundDeposited(
        uint256 indexed requestId,
        address indexed reviewer,
        uint256 amount
    );
    event EarlyWithdrawReviewFundWithdrawn(
        uint256 indexed requestId,
        address indexed reviewer,
        uint256 amount
    );
    event EarlyWithdrawReviewFundSettled(
        uint256 indexed requestId,
        address indexed vault
    );
    event MaturityClaimRequested(
        uint256 indexed requestId,
        address indexed vault,
        uint256 indexed positionId,
        address requester,
        uint256 reviewDeadline
    );
    event MaturityClaimReviewed(
        uint256 indexed requestId,
        address indexed vault,
        address indexed reviewer,
        bool approved
    );
    event VaultApprovalUpdated(address indexed vault, bool approved);
    event VaultReviewerUpdated(
        address indexed vault,
        address indexed reviewer,
        bool enabled
    );

    modifier onlyVault() {
        if (!approvedVaults[msg.sender]) revert Errors.NotAuthorized();
        _;
    }

    constructor(address _vault, address admin, address vaultManager) {
        if (admin == address(0)) {
            revert Errors.InvalidZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REVIEWER_MANAGER_ROLE, admin);
        _grantRole(VAULT_MANAGER_ROLE, admin);
        if (vaultManager != address(0)) {
            _grantRole(VAULT_MANAGER_ROLE, vaultManager);
        }
        if (_vault != address(0)) {
            approvedVaults[_vault] = true;
            emit VaultApprovalUpdated(_vault, true);
        }
    }

    function setVaultApproved(
        address vault,
        bool approved
    ) external onlyRole(VAULT_MANAGER_ROLE) {
        if (vault == address(0)) revert Errors.InvalidZeroAddress();
        approvedVaults[vault] = approved;
        emit VaultApprovalUpdated(vault, approved);
    }

    function setReviewer(
        address vault,
        address reviewer,
        bool enabled
    ) external onlyRole(REVIEWER_MANAGER_ROLE) {
        if (vault == address(0)) revert Errors.InvalidZeroAddress();
        if (reviewer == address(0)) revert Errors.InvalidZeroAddress();
        if (!approvedVaults[vault]) revert Errors.NotAuthorized();
        reviewersByVault[vault][reviewer] = enabled;
        emit VaultReviewerUpdated(vault, reviewer, enabled);
    }

    function createRequest(
        uint256 requestId,
        uint256 positionId,
        address requester,
        address underlyingAsset,
        uint256 epochId,
        uint256 maturity,
        uint256 immediatePrincipal,
        uint256 retainedPrincipal,
        uint256 sellerYieldAfterPenalty,
        uint256 forfeitedYield,
        uint256 requestedAt,
        uint256 reviewDeadline
    ) external onlyVault {
        if (requests[msg.sender][requestId].id != 0)
            revert Errors.InvalidRequestId();
        requests[msg.sender][requestId] = Request({
            id: requestId,
            vault: msg.sender,
            positionId: positionId,
            requester: requester,
            underlyingAsset: underlyingAsset,
            epochId: epochId,
            maturity: maturity,
            immediatePrincipal: immediatePrincipal,
            retainedPrincipal: retainedPrincipal,
            sellerYieldAfterPenalty: sellerYieldAfterPenalty,
            forfeitedYield: forfeitedYield,
            requestedAt: requestedAt,
            reviewDeadline: reviewDeadline,
            reviewedAt: 0,
            reviewer: address(0),
            approvedClaimId: 0,
            status: RequestStatus.Pending
        });
        userRequestIdsByVault[msg.sender][requester].push(requestId);
        allRequestRefs.push(RequestRef({vault: msg.sender, requestId: requestId}));
        emit EarlyWithdrawRequested(
            requestId,
            msg.sender,
            positionId,
            requester,
            reviewDeadline
        );
    }

    function getEffectiveStatus(
        address vault,
        uint256 requestId
    ) public view returns (RequestStatus) {
        Request memory r = requests[vault][requestId];
        if (r.id == 0) revert Errors.VaultRecordNotFound();
        if (r.status == RequestStatus.Pending && block.timestamp > r.reviewDeadline) {
            return RequestStatus.Rejected;
        }
        return r.status;
    }

    function createMaturityClaimRequest(
        uint256 requestId,
        uint256 positionId,
        address requester,
        address underlyingAsset,
        uint256 epochId,
        uint256 fundAmount,
        uint256 protocolFee,
        address protocolFeeReceiver,
        uint256 requestedAt,
        uint256 reviewDeadline
    ) external onlyVault {
        if (maturityRequests[msg.sender][requestId].id != 0) {
            revert Errors.InvalidRequestId();
        }
        maturityRequests[msg.sender][requestId] = MaturityRequest({
            id: requestId,
            vault: msg.sender,
            positionId: positionId,
            requester: requester,
            underlyingAsset: underlyingAsset,
            epochId: epochId,
            fundAmount: fundAmount,
            protocolFee: protocolFee,
            protocolFeeReceiver: protocolFeeReceiver,
            requestedAt: requestedAt,
            reviewDeadline: reviewDeadline,
            reviewedAt: 0,
            reviewer: address(0),
            status: RequestStatus.Pending
        });
        allMaturityRequestRefs.push(
            RequestRef({vault: msg.sender, requestId: requestId})
        );
        emit MaturityClaimRequested(
            requestId,
            msg.sender,
            positionId,
            requester,
            reviewDeadline
        );
    }

    function getMaturityClaimEffectiveStatus(
        address vault,
        uint256 requestId
    ) public view returns (RequestStatus) {
        MaturityRequest memory r = maturityRequests[vault][requestId];
        if (r.id == 0) revert Errors.VaultRecordNotFound();
        if (r.status == RequestStatus.Pending && block.timestamp > r.reviewDeadline) {
            return RequestStatus.Rejected;
        }
        return r.status;
    }

    function getMaturityClaimRequest(
        address vault,
        uint256 requestId
    ) external view returns (MaturityRequest memory) {
        return maturityRequests[vault][requestId];
    }

    function reviewMaturityClaimRequest(
        address vault,
        uint256 requestId,
        bool approved
    ) external {
        _requireReviewerForVault(vault, msg.sender);
        MaturityRequest memory r = maturityRequests[vault][requestId];
        if (r.id == 0) revert Errors.VaultRecordNotFound();
        if (r.status != RequestStatus.Pending) revert Errors.InvalidRequestStatus();

        maturityRequests[vault][requestId].reviewedAt = block.timestamp;
        maturityRequests[vault][requestId].reviewer = msg.sender;
        if (!approved) {
            maturityRequests[vault][requestId].status = RequestStatus.Rejected;
            IVaultEarlyWithdrawCallback(r.vault).onMaturityClaimRejected(
                requestId,
                r.positionId
            );
            emit MaturityClaimReviewed(requestId, vault, msg.sender, false);
            return;
        }
        if (block.timestamp > r.reviewDeadline) {
            revert Errors.InvalidRequestStatus();
        }

        IERC20 ua = IERC20(r.underlyingAsset);
        uint256 beforeBal = ua.balanceOf(r.vault);
        ua.safeTransferFrom(msg.sender, r.vault, r.fundAmount);
        uint256 received = ua.balanceOf(r.vault) - beforeBal;
        if (received != r.fundAmount) revert Errors.InvalidRepayAmount();
        maturityRequests[vault][requestId].status = RequestStatus.Approved;
        emit MaturityClaimReviewed(requestId, vault, msg.sender, true);
    }

    function depositEarlyWithdrawReviewFund(
        address vault,
        uint256 requestId
    ) external {
        _requireReviewerForVault(vault, msg.sender);
        Request memory r = requests[vault][requestId];
        if (r.id == 0) revert Errors.VaultRecordNotFound();
        if (getEffectiveStatus(vault, requestId) != RequestStatus.Pending) {
            revert Errors.InvalidRequestStatus();
        }
        uint256 funded = totalReviewFundByRequest[vault][requestId];
        if (funded != 0) revert Errors.ReviewFundAlreadyDeposited();
        uint256 amount = r.immediatePrincipal;
        IERC20(r.underlyingAsset).safeTransferFrom(msg.sender, r.vault, amount);
        totalReviewFundByRequest[vault][requestId] = amount;
        reviewFundByRequestAndReviewer[vault][requestId][msg.sender] = amount;
        emit EarlyWithdrawReviewFundDeposited(requestId, msg.sender, amount);
    }

    function withdrawEarlyWithdrawReviewFund(
        address vault,
        uint256 requestId
    ) external {
        Request memory r = requests[vault][requestId];
        if (r.id == 0) revert Errors.VaultRecordNotFound();
        if (getEffectiveStatus(vault, requestId) == RequestStatus.Approved) {
            revert Errors.InvalidRequestStatus();
        }
        uint256 reviewerFund = reviewFundByRequestAndReviewer[vault][requestId][msg.sender];
        if (reviewerFund == 0) revert Errors.NoReviewFundDeposited();
        uint256 amount = reviewerFund;
        reviewFundByRequestAndReviewer[vault][requestId][msg.sender] = 0;
        totalReviewFundByRequest[vault][requestId] -= amount;
        IVaultEarlyWithdrawCallback(r.vault).transferReviewFundOut(
            r.underlyingAsset,
            msg.sender,
            amount
        );
        emit EarlyWithdrawReviewFundWithdrawn(requestId, msg.sender, amount);
    }

    function reviewEarlyWithdrawRequest(
        address vault,
        uint256 requestId,
        bool approved
    ) external {
        _requireReviewerForVault(vault, msg.sender);
        Request memory r = requests[vault][requestId];
        if (r.id == 0) revert Errors.VaultRecordNotFound();
        if (getEffectiveStatus(vault, requestId) != RequestStatus.Pending) {
            revert Errors.InvalidRequestStatus();
        }

        if (!approved) {
            requests[vault][requestId].status = RequestStatus.Rejected;
            requests[vault][requestId].reviewedAt = block.timestamp;
            requests[vault][requestId].reviewer = msg.sender;
            IVaultEarlyWithdrawCallback(r.vault).onEarlyWithdrawRejected(
                requestId,
                r.positionId
            );
            _recordReviewerAction(
                vault,
                requestId,
                msg.sender,
                ReviewerActionType.Reject,
                0,
                0
            );
            emit EarlyWithdrawRequestReviewed(
                requestId,
                r.positionId,
                msg.sender,
                false
            );
            return;
        }

        if (totalReviewFundByRequest[vault][requestId] != r.immediatePrincipal) {
            revert Errors.InsufficientLiquidity();
        }

        // Flip status BEFORE the callback so the redeemVault's reentrant read
        // of getEffectiveStatus (e.g. during _recordUserPosition for the
        // activity logger) sees Approved, not the stale Pending. The
        // approvedClaimId is the callback's return value, so it's still set
        // after the callback returns.
        requests[vault][requestId].status = RequestStatus.Approved;
        requests[vault][requestId].reviewedAt = block.timestamp;
        requests[vault][requestId].reviewer = msg.sender;

        uint256 claimId = IVaultEarlyWithdrawCallback(r.vault)
            .onEarlyWithdrawApproved(
                requestId,
                msg.sender,
                r.positionId,
                r.requester,
                r.underlyingAsset,
                r.epochId,
                r.maturity,
                r.requestedAt,
                r.immediatePrincipal,
                r.retainedPrincipal,
                r.sellerYieldAfterPenalty,
                r.forfeitedYield
            );

        requests[vault][requestId].approvedClaimId = claimId;
        reviewFundSettledByRequest[vault][requestId] = true;

        _recordReviewerAction(
            vault,
            requestId,
            msg.sender,
            ReviewerActionType.Approve,
            r.immediatePrincipal,
            r.immediatePrincipal
        );
        emit EarlyWithdrawRequestReviewed(requestId, r.positionId, msg.sender, true);
        emit EarlyWithdrawReviewFundSettled(requestId, vault);
    }

    function _requireReviewerForVault(
        address vault,
        address reviewer
    ) internal view {
        if (!approvedVaults[vault]) revert Errors.NotAuthorized();
        if (!reviewersByVault[vault][reviewer]) {
            revert Errors.NotAuthorized();
        }
    }

    function _recordReviewerAction(
        address vault,
        uint256 requestId,
        address reviewer,
        ReviewerActionType actionType,
        uint256 amount,
        uint256 approvedWithdrawPrincipal
    ) internal {
        Request memory r = requests[vault][requestId];
        uint256 actionId = ++nextActionId;
        reviewerActions[actionId] = ReviewerAction({
            id: actionId,
            vault: vault,
            requestId: requestId,
            epochId: r.epochId,
            requester: r.requester,
            userPrincipal: r.immediatePrincipal + r.retainedPrincipal,
            approvedWithdrawPrincipal: approvedWithdrawPrincipal,
            reviewer: reviewer,
            actionType: actionType,
            amount: amount,
            timestamp: block.timestamp
        });
        reviewerActionIds[reviewer].push(actionId);
        allActionIds.push(actionId);
    }

    function getUserRequestCount(address vault, address user) external view returns (uint256) {
        return userRequestIdsByVault[vault][user].length;
    }

    function getRequest(
        address vault,
        uint256 requestId
    ) external view returns (Request memory) {
        return requests[vault][requestId];
    }

    function getUserRequestId(address vault, address user, uint256 index) external view returns (uint256) {
        return userRequestIdsByVault[vault][user][index];
    }

    function getReviewerActionCount(address reviewer) external view returns (uint256) {
        return reviewerActionIds[reviewer].length;
    }

    function getReviewerActionId(address reviewer, uint256 index) external view returns (uint256) {
        return reviewerActionIds[reviewer][index];
    }

    function getAllReviewerActions() external view returns (ReviewerAction[] memory items) {
        uint256 len = allActionIds.length;
        items = new ReviewerAction[](len);
        for (uint256 i = 0; i < len; i++) {
            items[i] = reviewerActions[allActionIds[i]];
        }
    }

    function getReviewerActionsPaged(
        uint256 offset,
        uint256 limit
    ) external view returns (ReviewerAction[] memory items) {
        uint256 len = allActionIds.length;
        if (offset >= len || limit == 0) return new ReviewerAction[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        items = new ReviewerAction[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            items[i - offset] = reviewerActions[allActionIds[i]];
        }
    }

    function getAllRequests() external view returns (Request[] memory items) {
        uint256 len = allRequestRefs.length;
        items = new Request[](len);
        for (uint256 i = 0; i < len; i++) {
            RequestRef memory ref = allRequestRefs[i];
            items[i] = requests[ref.vault][ref.requestId];
        }
    }

    function getPendingRequestsPaged(
        uint256 offset,
        uint256 limit
    ) external view returns (Request[] memory items) {
        if (limit == 0) return new Request[](0);
        uint256 total = allRequestRefs.length;
        uint256 pendingCount = 0;
        for (uint256 i = 0; i < total; i++) {
            RequestRef memory ref = allRequestRefs[i];
            if (
                getEffectiveStatus(ref.vault, ref.requestId) ==
                RequestStatus.Pending
            ) {
                pendingCount++;
            }
        }
        if (offset >= pendingCount) return new Request[](0);
        uint256 endPending = offset + limit;
        if (endPending > pendingCount) endPending = pendingCount;

        items = new Request[](endPending - offset);
        uint256 seenPending = 0;
        uint256 out = 0;
        for (uint256 i = 0; i < total; i++) {
            RequestRef memory ref = allRequestRefs[i];
            if (
                getEffectiveStatus(ref.vault, ref.requestId) !=
                RequestStatus.Pending
            ) continue;
            if (seenPending >= offset && seenPending < endPending) {
                items[out] = requests[ref.vault][ref.requestId];
                out++;
            }
            seenPending++;
            if (seenPending >= endPending) break;
        }
    }

    function getAllMaturityClaimRequests()
        external
        view
        returns (MaturityRequest[] memory items)
    {
        uint256 len = allMaturityRequestRefs.length;
        items = new MaturityRequest[](len);
        for (uint256 i = 0; i < len; i++) {
            RequestRef memory ref = allMaturityRequestRefs[i];
            items[i] = maturityRequests[ref.vault][ref.requestId];
        }
    }

    function getPendingMaturityClaimRequestsPaged(
        uint256 offset,
        uint256 limit
    ) external view returns (MaturityRequest[] memory items) {
        if (limit == 0) return new MaturityRequest[](0);
        uint256 total = allMaturityRequestRefs.length;
        uint256 pendingCount = 0;
        for (uint256 i = 0; i < total; i++) {
            RequestRef memory ref = allMaturityRequestRefs[i];
            if (
                getMaturityClaimEffectiveStatus(ref.vault, ref.requestId) ==
                RequestStatus.Pending
            ) {
                pendingCount++;
            }
        }
        if (offset >= pendingCount) return new MaturityRequest[](0);
        uint256 endPending = offset + limit;
        if (endPending > pendingCount) endPending = pendingCount;

        items = new MaturityRequest[](endPending - offset);
        uint256 seenPending = 0;
        uint256 out = 0;
        for (uint256 i = 0; i < total; i++) {
            RequestRef memory ref = allMaturityRequestRefs[i];
            if (
                getMaturityClaimEffectiveStatus(ref.vault, ref.requestId) !=
                RequestStatus.Pending
            ) continue;
            if (seenPending >= offset && seenPending < endPending) {
                items[out] = maturityRequests[ref.vault][ref.requestId];
                out++;
            }
            seenPending++;
            if (seenPending >= endPending) break;
        }
    }
}
