// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Errors} from "./Errors.sol";

contract EpochManagerStore {
    struct Epoch {
        uint256 id;
        uint256 startAt;
        uint256 subscriptionStartAt;
        uint256 interestEndAt;
        uint256 endAt;
        uint256 claimEndAt;
        uint256 apyBps;
        uint256 badDebtBps;
        bool settled;
    }

    address public owner;
    address public logic;

    mapping(address => bool) public authorizedVaults;
    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => uint256) public epochIdByStartAt;
    mapping(uint256 => bool) public epochOpened;
    uint256 public nextEpochId;
    uint256 public subscriptionEpochId;

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

    function setAuthorizedVault(address vault, bool authorized) external onlyLogic {
        authorizedVaults[vault] = authorized;
    }

    function incrementNextEpochId() external onlyLogic returns (uint256) {
        nextEpochId += 1;
        return nextEpochId;
    }

    function setEpochIdByStart(uint256 startAt, uint256 epochId) external onlyLogic {
        epochIdByStartAt[startAt] = epochId;
    }

    function createEpoch(
        uint256 epochId,
        uint256 startAt,
        uint256 subscriptionStartAt,
        uint256 interestEndAt,
        uint256 endAt,
        uint256 claimEndAt,
        uint256 apyBps,
        uint256 badDebtBps,
        bool settled
    ) external onlyLogic {
        epochs[epochId] = Epoch({
            id: epochId,
            startAt: startAt,
            subscriptionStartAt: subscriptionStartAt,
            interestEndAt: interestEndAt,
            endAt: endAt,
            claimEndAt: claimEndAt,
            apyBps: apyBps,
            badDebtBps: badDebtBps,
            settled: settled
        });
    }

    function setEpochTimes(
        uint256 epochId,
        uint256 subscriptionStartAt,
        uint256 startAt,
        uint256 interestEndAt,
        uint256 endAt,
        uint256 claimEndAt
    ) external onlyLogic {
        Epoch storage epoch = epochs[epochId];
        epoch.subscriptionStartAt = subscriptionStartAt;
        epoch.startAt = startAt;
        epoch.interestEndAt = interestEndAt;
        epoch.endAt = endAt;
        epoch.claimEndAt = claimEndAt;
    }

    function setEpochOpened(uint256 epochId, bool opened) external onlyLogic {
        epochOpened[epochId] = opened;
    }

    function setSubscriptionEpochId(uint256 epochId) external onlyLogic {
        subscriptionEpochId = epochId;
    }

    function setEpochApyBps(uint256 epochId, uint256 apyBps) external onlyLogic {
        epochs[epochId].apyBps = apyBps;
    }

    function setEpochBadDebt(
        uint256 epochId,
        uint256 badDebtBps
    ) external onlyLogic {
        epochs[epochId].badDebtBps = badDebtBps;
    }

    function setEpochSettled(uint256 epochId, bool settled) external onlyLogic {
        epochs[epochId].settled = settled;
    }
}
