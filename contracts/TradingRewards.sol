pragma solidity ^0.5.16;

import "openzeppelin-solidity-2.3.0/contracts/math/SafeMath.sol";
import "openzeppelin-solidity-2.3.0/contracts/token/ERC20/ERC20Detailed.sol";
import "openzeppelin-solidity-2.3.0/contracts/token/ERC20/SafeERC20.sol";
import "openzeppelin-solidity-2.3.0/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/ITradingRewards.sol";
import "./Pausable.sol";


contract TradingRewards is ITradingRewards, ReentrancyGuard, Pausable {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    uint private _currentPeriodID;
    uint private _availableRewards;
    mapping(uint => Period) private _periods;

    struct Period {
        uint recordedFees;
        uint totalRewards;
        uint availableRewards;
        mapping(address => uint) recordedFeesForAccount;
        mapping(address => uint) claimedRewardsForAccount;
    }

    address private _rewardsDistribution;

    IERC20 private _rewardsToken;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address owner,
        address rewardsToken,
        address rewardsDistribution
    ) public Owned(owner) {
        require(_validateAddress(rewardsToken), "Invalid rewards token");
        require(_validateAddress(rewardsDistribution), "Invalid rewards distribution");

        _rewardsToken = IERC20(rewardsToken);
        _rewardsDistribution = rewardsDistribution;
    }

    function _validateAddress(address addr) internal pure returns (bool) {
        return addr != address(0);
    }

    /* ========== VIEWS ========== */

    function getPeriodIsClaimable(uint periodID) public view returns (bool) {
        return periodID < _currentPeriodID;
    }

    function getPeriodRecordedFees(uint periodID) public view returns (uint) {
        return _periods[periodID].recordedFees;
    }

    function getPeriodTotalRewards(uint periodID) public view returns (uint) {
        return _periods[periodID].totalRewards;
    }

    function getPeriodAvailableRewards(uint periodID) public view returns (uint) {
        return _periods[periodID].availableRewards;
    }

    function getRecordedFeesForAccountForPeriod(address account, uint periodID) public view returns (uint) {
        return _periods[periodID].recordedFeesForAccount[account];
    }

    function getClaimedRewardsForAccountForPeriod(address account, uint periodID) public view returns (uint) {
        return _periods[periodID].claimedRewardsForAccount[account];
    }

    function getAvailableRewardsForAccountForPeriod(address account, uint periodID) external view returns (uint) {
        return _calculateAvailableRewardsForAccountForPeriod(account, periodID);
    }

    function getAvailableRewardsForAccountForPeriods(address account, uint[] calldata periodIDs)
        external
        view
        returns (uint totalRewards)
    {
        for (uint i = 0; i < periodIDs.length; i++) {
            uint periodID = periodIDs[i];

            totalRewards = totalRewards.add(_calculateAvailableRewardsForAccountForPeriod(account, periodID));
        }
    }

    function _calculateAvailableRewardsForAccountForPeriod(address account, uint periodID)
        internal
        view
        returns (uint availableRewards)
    {
        Period storage period = _periods[periodID];

        if (period.availableRewards == 0) {
            return 0;
        }

        // TODO: Consider precision loss
        uint accountFees = period.recordedFeesForAccount[account];
        uint participationRatio = accountFees.div(period.recordedFees);
        uint maxRewards = participationRatio.mul(period.totalRewards);

        uint alreadyClaimed = period.claimedRewardsForAccount[account];
        availableRewards = maxRewards.sub(alreadyClaimed);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function claimRewards(uint periodID) external nonReentrant {
        _claimRewards(msg.sender, periodID);
    }

    function claimRewardsForPeriods(uint[] calldata periodIDs) external nonReentrant {
        for (uint i = 0; i < periodIDs.length; i++) {
            uint periodID = periodIDs[i];

            _claimRewards(msg.sender, periodID);
        }
    }

    function _claimRewards(address account, uint periodID) internal {
        require(periodID < _currentPeriodID, "Cannot claim on active period");

        uint amountToClaim = _calculateAvailableRewardsForAccountForPeriod(account, periodID);

        Period storage period = _periods[periodID];
        period.claimedRewardsForAccount[account] = period.claimedRewardsForAccount[account].add(amountToClaim);
        period.availableRewards = period.availableRewards.sub(amountToClaim);

        _availableRewards = _availableRewards.sub(amountToClaim);

        _rewardsToken.safeTransfer(account, amountToClaim);

        emit RewardsClaimed(amountToClaim, account, _currentPeriodID);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // TODO: Implement onlyX modifier (onlyExchanger?)
    function recordExchangeFeeForAccount(uint amount, address account) external {
        Period storage period = _periods[_currentPeriodID];

        period.recordedFeesForAccount[account] = period.recordedFeesForAccount[account].add(amount);
        period.recordedFees = period.recordedFees.add(amount);

        emit FeeRecorded(amount, account, _currentPeriodID);
    }

    function setRewardsDistribution(address newRewardsDistribution) external onlyOwner {
        require(_validateAddress(newRewardsDistribution), "Invalid rewards distribution");

        _rewardsDistribution = newRewardsDistribution;
    }

    function notifyRewardAmount(uint newRewards) external onlyRewardsDistribution {
        uint currentBalance = _rewardsToken.balanceOf(address(this));
        uint availableForNewRewards = currentBalance.sub(_availableRewards);
        require(availableForNewRewards >= newRewards, "Unsufficient free rewards");

        _currentPeriodID = _currentPeriodID.add(1);
        _availableRewards = _availableRewards.add(newRewards);

        _periods[_currentPeriodID] = Period({totalRewards: newRewards, availableRewards: newRewards, recordedFees: 0});

        emit NewPeriodStarted(_currentPeriodID, newRewards);
    }

    function recoverTokens(address tokenAddress, uint amount) external onlyOwner {
        require(tokenAddress != address(_rewardsToken), "Must use recoverRewardsTokens");

        IERC20(tokenAddress).safeTransfer(msg.sender, amount);

        emit TokensRecovered(tokenAddress, amount);
    }

    function recoverRewardsTokens(uint amount) external onlyOwner {
        Period storage period = _periods[_currentPeriodID];

        require(period.availableRewards >= amount, "Unsufficient balance for amount");

        _availableRewards = _availableRewards.sub(amount);

        period.availableRewards = period.availableRewards.sub(amount);
        period.totalRewards = period.totalRewards.sub(amount);

        _rewardsToken.safeTransfer(msg.sender, amount);

        emit RewardsTokensRecovered(amount);
    }

    /* ========== MODIFIERS ========== */

    modifier onlyRewardsDistribution() {
        require(msg.sender == _rewardsDistribution, "Caller not RewardsDistribution");
        _;
    }

    /* ========== EVENTS ========== */

    event FeeRecorded(uint amount, address account, uint periodID);
    event RewardsClaimed(uint amount, address account, uint periodID);
    event NewPeriodStarted(uint periodID, uint rewards);
    event TokensRecovered(address tokenAddress, uint amount);
    event RewardsTokensRecovered(uint amount);
}
