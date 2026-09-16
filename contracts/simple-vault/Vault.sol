// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
interface IProtocolCfg {
    function isSupportedUnderlyingAsset(IERC20 asset) external view returns (bool);
    function paused() external view returns(bool);
}
interface IVaultFactory {
    function protocolCfg() external view returns (address);
}
contract Vault is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant WITHDRAW_REQUEST_ROLE = keccak256("WITHDRAW_REQUEST_ROLE");
    bytes32 public constant WITHDRAW_REVIEWER_ROLE = keccak256("WITHDRAW_REVIEWER_ROLE");
    uint8 public constant NORMALIZED_DECIMALS = 18;
    IVaultFactory public immutable vaultFactory;
    IERC20 public immutable shareToken;
    uint256 public miniDepositAmount;
    uint256 public maxCapacity;
    uint256 public totalDeposited;
    uint256 public stakingDays;
    uint256 public depositDeadline;
    uint256 public nextWithdrawRequestId;
    mapping(address => mapping(IERC20 => uint256)) public userBalance;
    mapping(IERC20 asset => bool isSupported) public isSupportedUnderlyingAsset;
    mapping(IERC20 asset => uint8 decimals) public assetDecimals;
    mapping(IERC20 asset => uint256 amount) public pendingWithdrawAmounts;
    mapping(uint256 => mapping(address => mapping(IERC20 => uint256))) public withdrawRequests;
    event MiniDepositAmountUpdated(uint256 amount,address _by);
    event UnderlyingAssetAdded(IERC20 indexed asset, address _by);
    event UnderlyingAssetRemoved(IERC20 indexed asset, address _by);
    event MaxCapacityUpdated(uint256 maxCapacity,address _by);
    event DepositDeadlineUpdated(uint256 indexed deadline,address _by);
    event UserDeposited(address indexed user,IERC20 indexed asset,uint256 amount,uint256 stakingDays);
    event RoleWithdrawRequested(uint256 indexed requestId,address indexed withdrawer,IERC20 asset,uint256 amount);
    event RoleWithdrawReviewed(uint256 indexed requestId,address indexed reviewer,IERC20 asset,uint256 amount,address withdrawer,bool approved);
    modifier onlySupportedUnderlyingAsset(IERC20 asset) {
        require(isSupportedUnderlyingAsset[asset], "Asset not supported");
        _;
    }
    modifier notZeroAddress(address addr) {
        require(addr != address(0), "Address cannot be zero");
        _;
    }
    modifier notZeroAmount(uint256 amount) {
        require(amount > 0, "Amount cannot be zero");
        _;
    }
    modifier onlyProtocolOpen(){
        address _protocolCfg = vaultFactory.protocolCfg();
        require(_protocolCfg != address(0), "Protocol cfg not set");
        require(!IProtocolCfg(_protocolCfg).paused(),"Protocol has been paused");
        _;
    }
    constructor(address _defaultAdmin,address _admin,uint256 _miniDepositAmt,uint256 _maxCapacity,uint256 _stakingDays,uint256 _depositDeadline,IERC20[] memory _underlyingAssets,IERC20 _shareToken) {
        vaultFactory = IVaultFactory(msg.sender);
        nextWithdrawRequestId = 1;
        for(uint256 i = 0; i < _underlyingAssets.length; i++) {
            _addUnderlyingAsset(_underlyingAssets[i]);
        }
        require(_miniDepositAmt > 0, "Mini deposit amount must be greater than zero");
        miniDepositAmount = _miniDepositAmt;
        require(_maxCapacity > 0, "Max capacity must be greater than zero");
        require(_stakingDays > 0, "Staking days must be greater than zero");
        maxCapacity = _maxCapacity;
        stakingDays = _stakingDays;
        require(_depositDeadline > block.timestamp, "Deposit deadline must be in the future");
        depositDeadline = _depositDeadline;
        require(_defaultAdmin != address(0) && _admin != address(0) && address(_shareToken) != address(0), "Address cannot be zero");
        uint8 _shareTokenDecimals = IERC20Metadata(address(_shareToken)).decimals();
        require(_shareTokenDecimals == NORMALIZED_DECIMALS,"Invalid share token decimals");
        shareToken = _shareToken;
        _grantRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _grantRole(ADMIN_ROLE, _admin);
    }
    function _addUnderlyingAsset(IERC20 asset) internal {
        address _protocolCfg = vaultFactory.protocolCfg();
        require(_protocolCfg != address(0), "Protocol cfg not set");
        require(IProtocolCfg(_protocolCfg).isSupportedUnderlyingAsset(asset),"Asset not supported");
        require(!isSupportedUnderlyingAsset[asset], "Asset already supported");
        uint8 decimals = IERC20Metadata(address(asset)).decimals();
        require(decimals <= NORMALIZED_DECIMALS, "Asset decimals too large");
        isSupportedUnderlyingAsset[asset] = true;
        assetDecimals[asset] = decimals;
    }
    function addUnderlyingAsset(IERC20 asset) external onlyRole(ADMIN_ROLE) notZeroAddress(address(asset)) onlyProtocolOpen() {
        _addUnderlyingAsset(asset);
        emit UnderlyingAssetAdded(asset, msg.sender);
    }
    function removeUnderlyingAsset(IERC20 asset) external onlyRole(ADMIN_ROLE) {
        require(isSupportedUnderlyingAsset[asset], "Asset not supported");
        isSupportedUnderlyingAsset[asset] = false;
        delete assetDecimals[asset];
        emit UnderlyingAssetRemoved(asset, msg.sender);
    }
    function setDepositDeadline(uint256 deadline) external onlyRole(ADMIN_ROLE) {
        require(deadline > block.timestamp, "Deposit deadline must be in the future");
        depositDeadline = deadline;
        emit DepositDeadlineUpdated(deadline, msg.sender);
    }
    function setMaxCapacity(uint256 _maxCapacity) external onlyRole(ADMIN_ROLE) notZeroAmount(_maxCapacity) {
        require(_maxCapacity >= totalDeposited, "New capacity below total deposited");
        maxCapacity = _maxCapacity;
        emit MaxCapacityUpdated(_maxCapacity, msg.sender);
    }
    function setMiniDepositAmount(uint256 _amt) external onlyRole(ADMIN_ROLE) notZeroAmount(_amt) {
        miniDepositAmount = _amt;
        emit MiniDepositAmountUpdated(_amt, msg.sender);
    }
    function deposit(IERC20 asset,uint256 amount) external nonReentrant onlyProtocolOpen() onlySupportedUnderlyingAsset(asset) notZeroAmount(amount)
    {
        require(block.timestamp < depositDeadline, "Deposits have closed.");
        uint256 cashBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = asset.balanceOf(address(this)) - cashBefore;
        require(received > 0, "No funds received");
        uint8 decimals = assetDecimals[asset];
        uint256 receivedNormalized = decimals == NORMALIZED_DECIMALS ? received : received * (10 ** (NORMALIZED_DECIMALS - decimals));
        require(receivedNormalized >= miniDepositAmount, "Below minimum deposit amount");
        require(totalDeposited + receivedNormalized <= maxCapacity,"Exceeds max capacity");
        uint256 shareTokenBalance = shareToken.balanceOf(address(this));
        require(shareTokenBalance >= receivedNormalized,"Insufficient share token balance in vault contract");
        shareToken.safeTransfer(msg.sender, receivedNormalized);
        userBalance[msg.sender][asset] += received;
        totalDeposited += receivedNormalized;
        emit UserDeposited(msg.sender, asset, received, stakingDays);
    }
    function roleRequestWithdraw(IERC20 asset,uint256 amount) external nonReentrant onlyRole(WITHDRAW_REQUEST_ROLE) notZeroAmount(amount) {
        require(pendingWithdrawAmounts[asset] + amount <= asset.balanceOf(address(this)), "Insufficient balance");
        pendingWithdrawAmounts[asset] += amount;
        withdrawRequests[nextWithdrawRequestId][msg.sender][asset] = amount;
        emit RoleWithdrawRequested(nextWithdrawRequestId, msg.sender, asset, amount);
        nextWithdrawRequestId++;
    }
    function reviewRoleWithdrawRequest(uint256 requestId,address withdrawer,IERC20 asset,bool approved) external nonReentrant onlyRole(WITHDRAW_REVIEWER_ROLE) {
        uint256 amount = withdrawRequests[requestId][withdrawer][asset];
        require(amount > 0, "Withdraw request not found");
        if (approved) asset.safeTransfer(withdrawer, amount);
        pendingWithdrawAmounts[asset] -= amount;
        delete withdrawRequests[requestId][withdrawer][asset];
        emit RoleWithdrawReviewed(requestId, msg.sender, asset, amount, withdrawer, approved);
    }
    function getVaultInfo() external view returns (uint256 _maxCapacity, uint256 _totalDeposited, uint256 _stakingDays) {
        return (maxCapacity, totalDeposited, stakingDays);
    }
    function renounceRole(bytes32,address) public pure override {
        revert("Renouncing roles is disabled");
    }
}
