// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


contract Errors{
    error InvalidZeroAddress();
    error NotPauser();
    error NotVaultOwner();
    error NotStrategyManager();
    error InvalidUnderlyingAsset();
    error EmptyEpochDepositAssetAllowlist();
    error VaultRecordNotFound();
    error NotAdmin();
    error ProtocolPaused();
    error VaultClosed();
    error InvalidZeroAmount();
    error InvalidUnderlyingDecimals();
    error NotTransferableToken();
    error NotPositionOwner();
    error PositionClosed();
    error InsufficientLiquidity();
    error LockupEnded();
    error InvalidAPY();
    error ExceedMaxCapacity();
    error InvalidZeroShare();
    error NotOwner();
    error RedeemDone();
    error RedeemTooEarly();
    error NotAuthorized();
    error CooldownEnded();
    error InvalidDuration();
    error InvalidFee();
    error NothingToClaim();
    error SubscriptionWindowClosed();
    error CancellationWindowClosed();
    error TooManyEpochRolls();
    error InvalidEpochProgression();
    error InvalidEpochStartTime();
    error InvalidVaultStatus();
    error EpochNotFound();
    error EpochSettled();
    error InsufficientTvl();
    error InvalidPositionStatus();
    error InvalidRequestId();
    error InvalidRequestStatus();
    error ReviewFundAlreadyDeposited();
    error NoReviewFundDeposited();
    error EpochNotOpened();
    error EpochNotSettled();
    error InvalidPendingEarlyWithdrawRequest();
    error InvalidBuyer();
    error PositionAutoRolled();
    error VaultAlreadyInitialized();
    error InvalidClaimId();
    error PositionNotEarlyWithdrawn();
    error InvalidEpochId();
    error InvalidRepayAmount();

    // Simple-vault migration related
    error MigrationFinalized();
    error MigrationEpochNotSet();
    error AlreadyMigrated();
    error NotEligibleForMigration();
    error ArrayLengthMismatch();
    error AmountMismatch();
    error NotMigrator();
    error EmptyBatch();
    error EpochAlreadySet();
    error AssetNotSupportedBySource();
    error InsufficientSBTBalance();
    error ZeroEpochId();
    error NotAContract();
    error EpochDrtMismatch();
}
