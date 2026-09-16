// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Errors} from "./Errors.sol";
import {VaultConfig} from "./VaultConfig.sol";
import {VaultActivityLogger} from "./VaultActivityLogger.sol";
import {EpochManager} from "./EpochManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract VaultStore {
    enum VaultStatus {
        Off,
        On,
        Closed
    }

    enum PositionStatus {
        Active,
        EarlyWithdrawApproved,
        Redeemed
    }

    struct Position {
        uint256 id;
        address owner;
        address underlyingAsset;
        uint256 principalAmount;
        uint256 shares;
        uint256 accumulatedYield;
        uint256 depositTime;
        uint256 lockupEndTime;
        uint256 lockupDuration;
        uint256 epochId;
        bool autoRoll;
        PositionStatus status;
    }
    struct EarlyWithdrawClaim {
        uint256 id;
        uint256 positionId;
        address seller;
        address underlyingAsset;
        uint256 epochId;
        uint256 immediatePrincipal;
        uint256 immediateClaimableAfter;
        uint256 retainedPrincipal;
        uint256 sellerYieldAfterPenalty;
        uint256 forfeitedYield;
        uint256 forfeitedYieldFee;
        uint256 maturity;
        address buyer;
        bool immediateClaimed;
        bool sellerClaimed;
        bool buyerClaimed;
    }
    struct EmergencyWithdrawRequest {
        uint256 id;
        address requester;
        address asset;
        address to;
        uint256 amount;
    }

    event TVLUpdated(address indexed vault, uint256 newTvl);
    event AssetTvlUpdated(address indexed vault, address asset, uint256 assetTvl);
    event UserStakedUpdated(
        address indexed vault,
        address user,
        address underlyingAsset,
        uint256 normalizedAmt,
        uint256 assetAmt
    );

    address public owner;
    address public logic;
    mapping(address => bool) public authorizedLogics;

    VaultStatus public vaultStatus;
    VaultConfig public vaultConfig;

    // uint8 public underlyingDecimals;
    string public vaultName;
    mapping(uint256 => IERC20) public drtTokenByEpoch;
    uint256[] public drtEpochIds;
    mapping(uint256 => bool) public knownDrtEpochIds;
    VaultActivityLogger public activityLogger;
    EpochManager public epochManager;

    uint256 public totalValueLocked;
    uint256 public totalUsers;
    uint256 public borrowedAmount;
    uint256 public lastRefreshTime;
    uint256 public currentApyBps;
    mapping(uint256 => uint256) public epochMaxCapacity;
    mapping(uint256 => uint256) public grossDepositedByEpoch;
    uint256 public lifetimeDepositedPrincipal;
    mapping(uint256 => uint256) public nextEpochByEpoch;

    uint256 public nextPositionId;
    uint256 public nextEarlyWithdrawRequestId;
    uint256 public nextEarlyWithdrawClaimId;
    uint256 public nextEmergencyWithdrawRequestId;

    mapping(address => uint256) public totalValueLockedByAsset;
    mapping(address => uint256) public borrowedAmountByAsset;

    mapping(address user => mapping(address asset => uint256 stakedAmt))
        public userStackedAssetAmt;
    mapping(address user => uint256) public userStakedAmt;
    mapping(uint256 => Position) public positions;
    mapping(uint256 => uint256) public positionInterestEndAtSnapshot;
    mapping(address => uint256[]) public userPositions;
    mapping(uint256 => uint256) public pendingEarlyWithdrawRequestIdByPosition;
    mapping(uint256 => uint256) public approvedEarlyWithdrawClaimIdByPosition;
    mapping(uint256 => uint256) public activeMaturityClaimRequestIdByPosition;
    mapping(uint256 => EarlyWithdrawClaim) public earlyWithdrawClaims;
    mapping(uint256 => bool) public positionEarlyWithdrawn;
    mapping(uint256 => EmergencyWithdrawRequest) public emergencyWithdrawRequests;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Errors.NotAdmin();
        _;
    }

    modifier onlyLogic() {
        if (!authorizedLogics[msg.sender]) revert Errors.NotAuthorized();
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
        authorizedLogics[_logic] = true;
    }

    function setAuthorizedLogic(address _logic, bool authorized) external onlyOwner {
        if (_logic == address(0)) revert Errors.InvalidZeroAddress();
        authorizedLogics[_logic] = authorized;
    }

    function setCoreRefs(
        address _vaultConfig,
        string calldata _vaultName
    ) external onlyLogic {
        vaultConfig = VaultConfig(_vaultConfig);
        vaultName = _vaultName;
    }

    function setDrtTokenByEpoch(
        uint256 epochId,
        address _drtToken
    ) external onlyLogic {
        if (epochId == 0) revert Errors.InvalidZeroAmount();
        if (_drtToken == address(0)) revert Errors.InvalidZeroAddress();
        drtTokenByEpoch[epochId] = IERC20(_drtToken);
        if (!knownDrtEpochIds[epochId]) {
            knownDrtEpochIds[epochId] = true;
            drtEpochIds.push(epochId);
        }
    }

    function getDrtEpochIds() external view returns (uint256[] memory) {
        return drtEpochIds;
    }

    function setActivityLogger(address _activityLogger) external onlyLogic {
        activityLogger = VaultActivityLogger(_activityLogger);
    }

    function setEpochManager(address _epochManager) external onlyLogic {
        epochManager = EpochManager(_epochManager);
    }

    function setVaultStatus(VaultStatus status_) external onlyLogic {
        vaultStatus = status_;
    }

    function setCounters(
        uint256 _nextPositionId,
        uint256 _nextEarlyWithdrawRequestId,
        uint256 _nextEarlyWithdrawClaimId
    ) external onlyLogic {
        nextPositionId = _nextPositionId;
        nextEarlyWithdrawRequestId = _nextEarlyWithdrawRequestId;
        nextEarlyWithdrawClaimId = _nextEarlyWithdrawClaimId;
    }

    function setNextEmergencyWithdrawRequestId(uint256 value) external onlyLogic {
        nextEmergencyWithdrawRequestId = value;
    }

    function setCurrentApyBps(uint256 value) external onlyLogic {
        currentApyBps = value;
    }

    function setEpochMaxCapacity(uint256 epochId, uint256 value) external onlyLogic {
        epochMaxCapacity[epochId] = value;
    }

    function increaseEpochGrossDeposit(uint256 epochId, uint256 value) external onlyLogic {
        grossDepositedByEpoch[epochId] += value;
    }

    function increaseLifetimeDepositedPrincipal(uint256 value) external onlyLogic {
        lifetimeDepositedPrincipal += value;
    }

    function setEpochRolloverLink(
        uint256 predecessorEpochId,
        uint256 successorEpochId
    ) external onlyLogic {
        nextEpochByEpoch[predecessorEpochId] = successorEpochId;
    }

    function setLastRefreshTime(uint256 value) external onlyLogic {
        lastRefreshTime = value;
    }

    function setBorrowedAmount(uint256 value) external onlyLogic {
        borrowedAmount = value;
    }

    function setBorrowedAmountByAsset(address asset, uint256 value) external onlyLogic {
        borrowedAmountByAsset[asset] = value;
    }

    function increaseTvl(
        address vault,
        address asset,
        uint256 normalizedValue,
        uint256 assetValue
    ) external onlyLogic {
        totalValueLocked += normalizedValue;
        totalValueLockedByAsset[asset] += assetValue;
        emit TVLUpdated(vault, totalValueLocked);
        emit AssetTvlUpdated(vault, asset, totalValueLockedByAsset[asset]);
    }

    function decreaseTvlOrRevert(
        address vault,
        address asset,
        uint256 normalizedValue,
        uint256 assetValue
    ) external onlyLogic {
        uint256 tvl = totalValueLocked;
        uint256 assetTvl = totalValueLockedByAsset[asset];
        if (tvl < normalizedValue || assetTvl < assetValue) {
            revert Errors.InsufficientTvl();
        }
        unchecked {
            totalValueLocked = tvl - normalizedValue;
            totalValueLockedByAsset[asset] = assetTvl - assetValue;
        }
        emit TVLUpdated(vault, totalValueLocked);
        emit AssetTvlUpdated(vault, asset, totalValueLockedByAsset[asset]);
    }

    function setTotalUsers(uint256 value) external onlyLogic {
        totalUsers = value;
    }

    function increaseUserStaked(
        address vault,
        address user,
        address underlyingAsset,
        uint256 normalizedValue,
        uint256 assetValue
    ) external onlyLogic {
        userStakedAmt[user] += normalizedValue;
        userStackedAssetAmt[user][underlyingAsset] += assetValue;
        emit UserStakedUpdated(
            vault,
            user,
            underlyingAsset,
            userStakedAmt[user],
            userStackedAssetAmt[user][underlyingAsset]
        );
    }

    function decreaseUserStaked(
        address vault,
        address user,
        address underlyingAsset,
        uint256 normalizedValue,
        uint256 assetValue
    ) external onlyLogic {
        uint256 staked = userStakedAmt[user];
        uint256 assetStaked = userStackedAssetAmt[user][underlyingAsset];
        if (staked < normalizedValue || assetStaked < assetValue) {
            revert Errors.InsufficientTvl();
        }
        userStakedAmt[user] = staked - normalizedValue;
        userStackedAssetAmt[user][underlyingAsset] = assetStaked - assetValue;
        emit UserStakedUpdated(
            vault,
            user,
            underlyingAsset,
            userStakedAmt[user],
            userStackedAssetAmt[user][underlyingAsset]
        );
    }

    function consumeNextPositionId() external onlyLogic returns (uint256 id) {
        id = nextPositionId;
        nextPositionId = id + 1;
    }

    function consumeNextEarlyWithdrawRequestId() external onlyLogic returns (uint256 id) {
        id = nextEarlyWithdrawRequestId;
        nextEarlyWithdrawRequestId = id + 1;
    }

    function consumeNextEarlyWithdrawClaimId() external onlyLogic returns (uint256 id) {
        id = nextEarlyWithdrawClaimId;
        nextEarlyWithdrawClaimId = id + 1;
    }

    function consumeNextEmergencyWithdrawRequestId()
        external
        onlyLogic
        returns (uint256 id)
    {
        id = nextEmergencyWithdrawRequestId;
        nextEmergencyWithdrawRequestId = id + 1;
    }

    function getUserPositionCount(address user) external view returns (uint256) {
        return userPositions[user].length;
    }

    function upsertPosition(
        uint256 positionId,
        address owner_,
        address underlyingAsset_,
        uint256 principalAmount,
        uint256 shares,
        uint256 accumulatedYield,
        uint256 depositTime,
        uint256 lockupEndTime,
        uint256 lockupDuration,
        uint256 epochId,
        bool autoRoll,
        uint8 status
    ) external onlyLogic {
        positions[positionId] = Position({
            id: positionId,
            owner: owner_,
            underlyingAsset: underlyingAsset_,
            principalAmount: principalAmount,
            shares: shares,
            accumulatedYield: accumulatedYield,
            depositTime: depositTime,
            lockupEndTime: lockupEndTime,
            lockupDuration: lockupDuration,
            epochId: epochId,
            autoRoll: autoRoll,
            status: PositionStatus(status)
        });
    }

    function pushUserPosition(address user, uint256 positionId) external onlyLogic {
        userPositions[user].push(positionId);
    }

    function setPositionInterestEndAtSnapshot(
        uint256 positionId,
        uint256 interestEndAt
    ) external onlyLogic {
        positionInterestEndAtSnapshot[positionId] = interestEndAt;
    }

    function setPositionEarlyWithdrawn(uint256 positionId, bool value) external onlyLogic {
        positionEarlyWithdrawn[positionId] = value;
    }

    function setPendingEarlyWithdrawRequestIdByPosition(uint256 positionId, uint256 requestId) external onlyLogic {
        pendingEarlyWithdrawRequestIdByPosition[positionId] = requestId;
    }

    function clearPendingEarlyWithdrawRequestIdByPosition(uint256 positionId) external onlyLogic {
        delete pendingEarlyWithdrawRequestIdByPosition[positionId];
    }

    function setApprovedEarlyWithdrawClaimIdByPosition(
        uint256 positionId,
        uint256 claimId
    ) external onlyLogic {
        approvedEarlyWithdrawClaimIdByPosition[positionId] = claimId;
    }

    function setActiveMaturityClaimRequestIdByPosition(
        uint256 positionId,
        uint256 requestId
    ) external onlyLogic {
        activeMaturityClaimRequestIdByPosition[positionId] = requestId;
    }

    function clearActiveMaturityClaimRequestIdByPosition(
        uint256 positionId
    ) external onlyLogic {
        delete activeMaturityClaimRequestIdByPosition[positionId];
    }

    function upsertEmergencyWithdrawRequest(
        uint256 requestId,
        address requester,
        address asset,
        address to,
        uint256 amount
    ) external onlyLogic {
        emergencyWithdrawRequests[requestId] = EmergencyWithdrawRequest({
            id: requestId,
            requester: requester,
            asset: asset,
            to: to,
            amount: amount
        });
    }

    function deleteEmergencyWithdrawRequest(uint256 requestId) external onlyLogic {
        delete emergencyWithdrawRequests[requestId];
    }

    function upsertEarlyWithdrawClaim(
        uint256 claimId,
        uint256 positionId,
        address seller,
        address underlyingAsset_,
        uint256 epochId,
        uint256 immediatePrincipal,
        uint256 immediateClaimableAfter,
        uint256 retainedPrincipal,
        uint256 sellerYieldAfterPenalty,
        uint256 forfeitedYield,
        uint256 forfeitedYieldFee,
        uint256 maturity,
        address buyer,
        bool immediateClaimed,
        bool sellerClaimed,
        bool buyerClaimed
    ) external onlyLogic {
        earlyWithdrawClaims[claimId] = EarlyWithdrawClaim({
            id: claimId,
            positionId: positionId,
            seller: seller,
            underlyingAsset: underlyingAsset_,
            epochId: epochId,
            immediatePrincipal: immediatePrincipal,
            immediateClaimableAfter: immediateClaimableAfter,
            retainedPrincipal: retainedPrincipal,
            sellerYieldAfterPenalty: sellerYieldAfterPenalty,
            forfeitedYield: forfeitedYield,
            forfeitedYieldFee: forfeitedYieldFee,
            maturity: maturity,
            buyer: buyer,
            immediateClaimed: immediateClaimed,
            sellerClaimed: sellerClaimed,
            buyerClaimed: buyerClaimed
        });
    }

    function setEarlyWithdrawClaimBuyer(uint256 claimId, address buyer) external onlyLogic {
        earlyWithdrawClaims[claimId].buyer = buyer;
    }

    function setEarlyWithdrawClaimImmediateClaimed(uint256 claimId, bool value) external onlyLogic {
        earlyWithdrawClaims[claimId].immediateClaimed = value;
    }

    function setEarlyWithdrawClaimSellerClaimed(uint256 claimId, bool value) external onlyLogic {
        earlyWithdrawClaims[claimId].sellerClaimed = value;
    }

    function setEarlyWithdrawClaimBuyerClaimed(uint256 claimId, bool value) external onlyLogic {
        earlyWithdrawClaims[claimId].buyerClaimed = value;
    }
}
