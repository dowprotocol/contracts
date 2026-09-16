// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Errors} from "./Errors.sol";

interface IVaultRef {
    function redeemVault() external view returns (address);
}

contract VaultActivityLogger is Ownable {
    enum UserActionType {
        Deposit,
        RequestRedeem,
        FulfillRedeem,
        EarlyWithdrawRequest
    }
    enum LockupTierType {
        noLockup,
        threeMonths,
        sixMonths
    }

    struct UserAction {
        uint256 id;
        address user;
        address vault;
        UserActionType actionType;
        uint256 underlyingAmount;
        address asset;
        address shareToken;
        uint256 shares;
        uint256 timestamp;
    }

    struct UserPosition {
        uint256 id;
        string vaultName;
        address user;
        address vault;
        uint256 positionId;
        uint256 epochId;
        uint256 lockupTime;
        uint256 claimableAt;
        address token;
        uint256 amt;
        uint256 apy;
        bool isEarlyWithdrawn;
        bool isEarlyWithdrawRequested;
        uint8 earlyWithdrawReviewStatus; // 0=None, 1=Pending, 2=Approved, 3=Rejected
        bool isAutoRoll;
    }

    struct ClaimableReward {
        uint256 id;
        address user;
        address vault;
        uint8 sourceType;
        uint256 sourceId;
        uint256 requestId;
        uint8 rewardType;
        uint256 amount;
        uint256 claimableAt;
        bool claimed;
        bool cancelled;
    }

    mapping(address => bool) public authorizedVaults;

    uint256 public nextUserActionId;
    uint256 public nextUserRecordPositionId;
    mapping(uint256 => UserAction) public userActions;
    mapping(address => uint256[]) public userActionIds; // user => actionId[]
    mapping(address => uint256[]) public vaultActionIds; // vault => actionId[]

    mapping(uint256 => UserPosition) public userPositions;
    mapping(address => uint256[]) public userPositionIds;
    mapping(address => uint256[]) public vaultPositionIds;

    mapping(address => mapping(address => mapping(uint256 => uint256)))
        public userVaultPositionId;

    uint256 public nextClaimableRewardId;
    mapping(uint256 => ClaimableReward) public claimableRewards;
    mapping(address => uint256[]) public userClaimableRewardIds;
    mapping(address => uint256[]) public vaultClaimableRewardIds;
    // vault => sourceType => sourceId => rewardType => rewardId
    mapping(address => mapping(uint8 => mapping(uint256 => mapping(uint8 => uint256))))
        public rewardIdByVaultSourceTypeSourceIdRewardType;

    event ActionRecorded(
        uint256 indexed actionId,
        address indexed vault,
        address indexed user,
        UserActionType actionType,
        uint256 underlyingAmount
    );
    event PositionRecorded(
        uint256 indexed id,
        address indexed vault,
        address indexed user,
        address token,
        uint256 amt
    );

    event VaultAuthorized(address indexed vault, bool authorized);
    event ClaimableRewardUpserted(
        uint256 indexed rewardId,
        address indexed vault,
        address indexed user,
        uint8 sourceType,
        uint256 sourceId,
        uint8 rewardType,
        uint256 amount,
        uint256 claimableAt
    );
    event ClaimableRewardRequested(
        uint256 indexed rewardId,
        uint256 indexed requestId,
        uint256 amount,
        uint256 claimableAt
    );
    event ClaimableRewardClaimed(uint256 indexed rewardId);
    event ClaimableRewardCancelled(uint256 indexed rewardId);

    constructor(address _owner) Ownable(_owner) {}

    modifier onlyAuthorizedVault(address _vault) {
        if (!authorizedVaults[_vault]) revert Errors.NotAuthorized();
        _;
    }

    function authorizeVault(address vault, bool authorized) external {
        require(
            msg.sender == owner() || authorizedFactories[msg.sender],
            "Not authorized"
        );
        authorizedVaults[vault] = authorized;
        emit VaultAuthorized(vault, authorized);
    }

    mapping(address => bool) public authorizedFactories;

    event FactoryAuthorized(address indexed factory, bool authorized);

    function authorizeFactory(
        address factory,
        bool authorized
    ) external onlyOwner {
        authorizedFactories[factory] = authorized;
        emit FactoryAuthorized(factory, authorized);
    }

    function recordAction(
        address user,
        UserActionType actionType,
        uint256 underlyingAmount,
        address underlyingAsset,
        address shareToken,
        uint256 shares
    ) external onlyAuthorizedVault(msg.sender) returns (uint256) {
        uint256 actionId = ++nextUserActionId;
        userActions[actionId] = UserAction({
            id: actionId,
            user: user,
            vault: msg.sender,
            actionType: actionType,
            underlyingAmount: underlyingAmount,
            asset: underlyingAsset,
            shareToken: shareToken,
            shares: shares,
            timestamp: block.timestamp
        });

        userActionIds[user].push(actionId);
        vaultActionIds[msg.sender].push(actionId);

        emit ActionRecorded(
            actionId,
            msg.sender,
            user,
            actionType,
            underlyingAmount
        );

        return actionId;
    }

    function recordUserPosition(
        address user,
        address vault,
        string calldata vaultName,
        uint256 positionId,
        uint256 epochId,
        uint256 claimableAt,
        address token,
        uint256 amt,
        uint256 apy,
        bool isEarlyWithdrawn,
        bool isEarlyWithdrawRequested,
        uint8 earlyWithdrawReviewStatus,
        bool isAutoRoll
    ) external onlyAuthorizedVault(msg.sender) {
        if (vault == address(0)) revert Errors.InvalidZeroAddress();

        // Dynamic pair guard: msg.sender must either BE the named vault, or
        // be the vault's currently registered redeemVault. This prevents a
        // malicious or buggy authorized RedeemVault from pair (A) from
        // writing position records that claim to belong to pair (B). The
        // lookup is dynamic so vault.setDrtRedeemVault rotations stay
        // honored without re-authorization.
        if (msg.sender != vault) {
            address currentRedeem = IVaultRef(vault).redeemVault();
            if (msg.sender != currentRedeem) revert Errors.NotAuthorized();
        }

        uint256 recordPositionId = userVaultPositionId[user][vault][
            positionId
        ];

        if (recordPositionId == 0) {
            if (amt == 0) {
                return;
            }
            recordPositionId = ++nextUserRecordPositionId;
            userVaultPositionId[user][vault][
                positionId
            ] = recordPositionId;
            userPositionIds[user].push(recordPositionId);
            vaultPositionIds[vault].push(recordPositionId);
        }

        userPositions[recordPositionId] = UserPosition({
            id: recordPositionId,
            vaultName: vaultName,
            user: user,
            vault: vault,
            positionId: positionId,
            epochId: epochId,
            lockupTime: block.timestamp,
            claimableAt: claimableAt,
            token: token,
            amt: amt,
            apy: apy,
            isEarlyWithdrawn: isEarlyWithdrawn,
            isEarlyWithdrawRequested: isEarlyWithdrawRequested,
            earlyWithdrawReviewStatus: earlyWithdrawReviewStatus,
            isAutoRoll: isAutoRoll
        });

        emit PositionRecorded(recordPositionId, vault, user, token, amt);
    }

    function _upsertClaimableReward(
        address user,
        uint8 sourceType,
        uint256 sourceId,
        uint8 rewardType,
        uint256 amount,
        uint256 claimableAt
    ) internal returns (uint256 rewardId) {
        rewardId = rewardIdByVaultSourceTypeSourceIdRewardType[msg.sender][
            sourceType
        ][sourceId][rewardType];
        if (rewardId == 0) {
            rewardId = ++nextClaimableRewardId;
            rewardIdByVaultSourceTypeSourceIdRewardType[msg.sender][sourceType][
                sourceId
            ][rewardType] = rewardId;
            userClaimableRewardIds[user].push(rewardId);
            vaultClaimableRewardIds[msg.sender].push(rewardId);
        }

        ClaimableReward storage reward = claimableRewards[rewardId];
        reward.id = rewardId;
        reward.user = user;
        reward.vault = msg.sender;
        reward.sourceType = sourceType;
        reward.sourceId = sourceId;
        reward.rewardType = rewardType;
        reward.amount = amount;
        reward.claimableAt = claimableAt;
        reward.cancelled = false;

        emit ClaimableRewardUpserted(
            rewardId,
            msg.sender,
            user,
            sourceType,
            sourceId,
            rewardType,
            amount,
            claimableAt
        );
    }

    function recordEarlyWithdrawClaimables(
        address user,
        uint256 claimId,
        uint256 immediatePrincipal,
        uint256 immediateClaimableAt,
        uint256 retainedPrincipal,
        uint256 maturityClaimableAt
    ) external onlyAuthorizedVault(msg.sender) {
        _upsertClaimableReward(
            user,
            0,
            claimId,
            0,
            immediatePrincipal,
            immediateClaimableAt
        );
        _upsertClaimableReward(
            user,
            0,
            claimId,
            1,
            retainedPrincipal,
            maturityClaimableAt
        );
    }

    function requestClaimableReward(
        address user,
        uint8 sourceType,
        uint256 sourceId,
        uint8 rewardType,
        uint256 requestId,
        uint256 amount,
        uint256 claimableAt
    ) external onlyAuthorizedVault(msg.sender) {
        uint256 rewardId = _upsertClaimableReward(
            user,
            sourceType,
            sourceId,
            rewardType,
            amount,
            claimableAt
        );

        ClaimableReward storage reward = claimableRewards[rewardId];
        reward.requestId = requestId;
        reward.amount = amount;
        reward.claimableAt = claimableAt;
        reward.cancelled = false;

        emit ClaimableRewardRequested(rewardId, requestId, amount, claimableAt);
    }

    function claimClaimableReward(
        uint8 sourceType,
        uint256 sourceId,
        uint8 rewardType
    ) external onlyAuthorizedVault(msg.sender) {
        uint256 rewardId = rewardIdByVaultSourceTypeSourceIdRewardType[
            msg.sender
        ][sourceType][sourceId][rewardType];
        if (rewardId == 0) return;
        ClaimableReward storage reward = claimableRewards[rewardId];
        reward.claimed = true;
        reward.cancelled = false;
        emit ClaimableRewardClaimed(rewardId);
    }

    function cancelClaimableReward(
        uint8 sourceType,
        uint256 sourceId,
        uint8 rewardType
    ) external onlyAuthorizedVault(msg.sender) {
        uint256 rewardId = rewardIdByVaultSourceTypeSourceIdRewardType[
            msg.sender
        ][sourceType][sourceId][rewardType];
        if (rewardId == 0) return;
        ClaimableReward storage reward = claimableRewards[rewardId];
        reward.cancelled = true;
        emit ClaimableRewardCancelled(rewardId);
    }

    function getUserActions(
        address user
    ) external view returns (UserAction[] memory) {
        uint256[] memory ids = userActionIds[user];
        UserAction[] memory result = new UserAction[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            result[i] = userActions[ids[i]];
        }
        return result;
    }

    function getUserVaultActions(
        address user,
        address vault
    ) external view returns (UserAction[] memory) {
        uint256[] memory ids = userActionIds[user];
        uint256 count = 0;

        for (uint256 i = 0; i < ids.length; i++) {
            if (userActions[ids[i]].vault == vault) {
                count++;
            }
        }

        UserAction[] memory result = new UserAction[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            if (userActions[ids[i]].vault == vault) {
                result[idx] = userActions[ids[i]];
                idx++;
            }
        }
        return result;
    }

    function getVaultActions(
        address vault
    ) external view returns (UserAction[] memory) {
        uint256[] memory ids = vaultActionIds[vault];
        UserAction[] memory result = new UserAction[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            result[i] = userActions[ids[i]];
        }
        return result;
    }

    function getVaultActionsPaged(
        address vault,
        uint256 offset,
        uint256 limit
    ) external view returns (UserAction[] memory) {
        uint256[] memory ids = vaultActionIds[vault];
        uint256 total = ids.length;

        if (total == 0 || offset >= total) {
            return new UserAction[](0);
        }

        uint256 startIdx = total > offset ? total - 1 - offset : 0;
        uint256 endIdx = startIdx >= limit ? startIdx - limit + 1 : 0;

        uint256 count = startIdx - endIdx + 1;
        UserAction[] memory result = new UserAction[](count);

        uint256 idx = 0;
        for (uint256 i = startIdx; i >= endIdx; i--) {
            result[idx] = userActions[ids[i]];
            unchecked {
                idx++;
            }
            if (i == 0) {
                break;
            }
        }

        return result;
    }

    function getUserPositions(
        address user
    ) external view returns (UserPosition[] memory) {
        uint256[] memory ids = userPositionIds[user];
        UserPosition[] memory result = new UserPosition[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            result[i] = userPositions[ids[i]];
        }
        return result;
    }

    function getUserClaimableRewards(
        address user
    ) external view returns (ClaimableReward[] memory) {
        uint256[] memory ids = userClaimableRewardIds[user];
        ClaimableReward[] memory result = new ClaimableReward[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            result[i] = claimableRewards[ids[i]];
        }
        return result;
    }

    function getUserVaultClaimableRewards(
        address user,
        address vault
    ) external view returns (ClaimableReward[] memory) {
        uint256[] memory ids = userClaimableRewardIds[user];
        uint256 count = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            if (claimableRewards[ids[i]].vault == vault) count++;
        }

        ClaimableReward[] memory result = new ClaimableReward[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            if (claimableRewards[ids[i]].vault == vault) {
                result[idx] = claimableRewards[ids[i]];
                idx++;
            }
        }
        return result;
    }

    function getUserPositionsPaged(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (UserPosition[] memory) {
        uint256[] memory ids = userPositionIds[user];
        uint256 total = ids.length;

        if (total == 0 || offset >= total) {
            return new UserPosition[](0);
        }

        uint256 startIdx = total > offset ? total - 1 - offset : 0;
        uint256 endIdx = startIdx >= limit ? startIdx - limit + 1 : 0;

        uint256 count = startIdx - endIdx + 1;
        UserPosition[] memory result = new UserPosition[](count);

        uint256 idx = 0;
        for (uint256 i = startIdx; i >= endIdx; i--) {
            result[idx] = userPositions[ids[i]];
            unchecked {
                idx++;
            }
            if (i == 0) {
                break;
            }
        }

        return result;
    }

    function getUserVaultPositions(
        address user,
        address vault
    ) external view returns (UserPosition[] memory) {
        uint256[] memory ids = userPositionIds[user];
        uint256 count = 0;

        for (uint256 i = 0; i < ids.length; i++) {
            if (userPositions[ids[i]].vault == vault) {
                count++;
            }
        }

        UserPosition[] memory result = new UserPosition[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            if (userPositions[ids[i]].vault == vault) {
                result[idx] = userPositions[ids[i]];
                idx++;
            }
        }
        return result;
    }

    function getVaultPositions(
        address vault
    ) external view returns (UserPosition[] memory) {
        uint256[] memory ids = vaultPositionIds[vault];
        UserPosition[] memory result = new UserPosition[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            result[i] = userPositions[ids[i]];
        }
        return result;
    }

    function getVaultPositionsPaged(
        address vault,
        uint256 offset,
        uint256 limit
    ) external view returns (UserPosition[] memory) {
        uint256[] memory ids = vaultPositionIds[vault];
        uint256 total = ids.length;

        if (total == 0 || offset >= total) {
            return new UserPosition[](0);
        }

        uint256 startIdx = total > offset ? total - 1 - offset : 0;
        uint256 endIdx = startIdx >= limit ? startIdx - limit + 1 : 0;

        uint256 count = startIdx - endIdx + 1;
        UserPosition[] memory result = new UserPosition[](count);

        uint256 idx = 0;
        for (uint256 i = startIdx; i >= endIdx; i--) {
            result[idx] = userPositions[ids[i]];
            unchecked {
                idx++;
            }
            if (i == 0) {
                break;
            }
        }

        return result;
    }

    function getUserPositionCount(
        address user
    ) external view returns (uint256) {
        return userPositionIds[user].length;
    }

    function getVaultPositionCount(
        address vault
    ) external view returns (uint256) {
        return vaultPositionIds[vault].length;
    }

    function getUserActionCount(address user) external view returns (uint256) {
        return userActionIds[user].length;
    }

    function getVaultActionCount(
        address vault
    ) external view returns (uint256) {
        return vaultActionIds[vault].length;
    }
}
