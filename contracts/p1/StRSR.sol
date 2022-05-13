// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "contracts/interfaces/IStRSR.sol";
import "contracts/interfaces/IMain.sol";
import "contracts/libraries/Fixed.sol";
import "contracts/p1/mixins/Component.sol";

/*
 * @title StRSRP1
 * @notice StRSR is an ERC20 token contract that allows people to stake their RSR as insurance
 *   behind an RToken. As compensation stakers receive a share of revenues in the form of RSR.
 *   Balances are generally non-rebasing. As rewards are paid out StRSR becomes redeemable for
 *   increasing quantities of RSR.
 *
 * The one time that StRSR will rebase is if the entirety of insurance RSR is seized. If this
 *   happens, users balances are zereod out and StRSR is re-issued at a 1:1 exchange rate with RSR
 *
 * There's an important assymetry in StRSR: when RSR is added it must be split only
 *   across non-withdrawing stakes, while when RSR is seized it is seized uniformly from both
 *   stakes that are in the process of being withdrawn and those that are not.
 */
// solhint-disable max-states-count
contract StRSRP1 is IStRSR, ERC20VotesUpgradeable, ComponentP1 {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using FixLib for int192;

    // Era. If ever there's a total RSR wipeout, increment the era to zero old balances in one step.
    uint256 internal era;

    // Stakes: usual staking position. These are the token stakes!
    mapping(uint256 => mapping(address => uint256)) private stakes; // Stakes per account {qStRSR}
    uint256 internal totalStakes; // Total of all stakes {qStakes}
    uint256 internal stakeRSR; // Amount of RSR backing all stakes {qRSR}
    int192 public stakeRate; // The exchange rate between stakes and RSR. {stRSR/RSR}

    // ==== Unstaking Gov Param ====
    uint32 public unstakingDelay;

    // Drafts: share of the withdrawing tokens. Not transferrable.
    // Draft queues by account. Handle only through pushDrafts() and withdraw(). Indexed by era.
    mapping(uint256 => mapping(address => CumulativeDraft[])) public draftQueues;
    mapping(uint256 => mapping(address => uint256)) public firstRemainingDraft;
    uint256 internal totalDrafts; // Total of all drafts {qDrafts}
    uint256 internal draftRSR; // Amount of RSR backing all drafts {qRSR}
    int192 public draftRate; // The exchange rate between drafts and RSR. {drafts/RSR}

    // {qRSR} How much reward RSR was held the last time rewards were paid out
    uint256 internal rsrRewardsAtLastPayout;

    // Delayed drafts
    struct CumulativeDraft {
        uint256 drafts; // Total amount of drafts that will become available
        uint256 availableAt; // When the last of the drafts will become available
    }

    // Min exchange rate {qRSR/qStRSR}
    int192 private constant MIN_EXCHANGE_RATE = int192(1e9); // 1e-9

    // {seconds} The last time stRSR paid out rewards to stakers
    uint32 internal payoutLastPaid;

    // ==== Reward Gov Params ====
    uint32 public rewardPeriod;
    int192 public rewardRatio;

    function init(
        IMain main_,
        string calldata name_,
        string calldata symbol_,
        uint32 unstakingDelay_,
        uint32 rewardPeriod_,
        int192 rewardRatio_
    ) external initializer {
        __Component_init(main_);
        __ERC20Permit_init(name_);
        __ERC20_init(name_, symbol_);
        __ERC20Votes_init();
        payoutLastPaid = uint32(block.timestamp);
        rsrRewardsAtLastPayout = main_.rsr().balanceOf(address(this));
        unstakingDelay = unstakingDelay_;
        rewardPeriod = rewardPeriod_;
        rewardRatio = rewardRatio_;
        stakeRate = FIX_ONE;
        draftRate = FIX_ONE;
        require(rewardPeriod * 2 <= unstakingDelay, "unstakingDelay/rewardPeriod incompatible");
    }

    /// Assign reward payouts to the staker pool
    /// @custom:action
    function payoutRewards() external action {
        _payoutRewards();
    }

    /// Assign reward payouts to the staker pool
    /// @custom:subroutine
    // solhint-disable-next-line func-name-mixedcase
    function payoutRewards_sub() external subroutine {
        _payoutRewards();
    }

    /// Stakes an RSR `amount` on the corresponding RToken to earn yield and insure the system
    /// @param rsrAmount {qRSR}
    /// @custom:action
    function stake(uint256 rsrAmount) external action {
        require(rsrAmount > 0, "Cannot stake zero");

        _payoutRewards();

        // Compute stake amount
        // This is not an overflow risk according to our expected ranges:
        //   rsrAmount <= 1e29, totalStaked <= 1e38, 1e29 * 1e38 < 2^256.
        // stakeAmount: how many stRSR the user shall receive.
        // pick stakeAmount as big as we can such that (newTotalStakes <= newStakeRSR * stakeRate)
        uint256 newStakeRSR = stakeRSR + rsrAmount;
        uint256 newTotalStakes = stakeRate.mulu_toUint(newStakeRSR);
        uint256 stakeAmount = newTotalStakes - totalStakes;

        // Add to stakeAmount to stakes
        address account = _msgSender();
        stakes[era][account] += stakeAmount;

        // Update totals
        totalStakes = newTotalStakes;
        stakeRSR = newStakeRSR;

        // Transfer RSR from account to this contract
        emit Staked(account, rsrAmount, stakeAmount);
        IERC20Upgradeable(address(main.rsr())).safeTransferFrom(account, address(this), rsrAmount);
    }

    /// Begins a delayed unstaking for `amount` StRSR
    /// @param stakeAmount {qStRSR}
    /// @custom:action
    function unstake(uint256 stakeAmount) external action {
        address account = _msgSender();
        require(stakeAmount > 0, "Cannot withdraw zero");
        require(stakes[era][account] >= stakeAmount, "Not enough balance");

        _payoutRewards();
        uint256 rsrAmount;
        uint256 draftAmount;

        // ==== Compute changes to balances and totals
        // rsrAmount: how many RSR to move from the stake pool to the draft pool
        // pick rsrAmount as big as we can such that (newTotalStakes <= newStakeRSR * stakeRate)
        totalStakes -= stakeAmount;
        {
            uint256 newStakeRSR = toFix(totalStakes).div(stakeRate).toUint(); // TODO: use less gas
            // equivalently, here: newStakeRSR = totalStakes * 1e18 / uint(stakeRate);
            rsrAmount = stakeRSR - newStakeRSR;
            stakeRSR = newStakeRSR;
        }

        // draftAmount: how many drafts to create and assign to the user
        // pick draftAmount as big as we can such that (newTotalDrafts <= newDraftRSR * draftRate)
        draftRSR += rsrAmount;
        {
            uint256 newTotalDrafts = draftRate.mulu(draftRSR).toUint(); // TODO: use less gas
            // equivalently, here: uint(draftRate) * draftRSR / 1e18
            draftAmount = newTotalDrafts - totalDrafts;
            totalDrafts = newTotalDrafts;
        }

        // ==== Reduce stake balance
        stakes[era][account] -= stakeAmount;

        // Push drafts into account's draft queue
        CumulativeDraft[] storage queue = draftQueues[era][account];
        uint256 index = queue.length;

        uint256 oldDrafts = index > 0 ? queue[index - 1].drafts : 0;
        uint256 lastAvailableAt = index > 0 ? queue[index - 1].availableAt : 0;
        uint256 availableAt = block.timestamp + unstakingDelay;
        if (lastAvailableAt > availableAt) availableAt = lastAvailableAt;

        queue.push(CumulativeDraft(oldDrafts + draftAmount, availableAt));
        emit UnstakingStarted(
            index,
            era,
            account,
            rsrAmount,
            stakeAmount,
            draftQueues[era][account][index].availableAt
        );
    }

    /// Complete delayed unstaking for an account, up to but not including `endId`
    /// @custom:action
    function withdraw(address account, uint256 endId) external action {
        main.assetRegistry().forceUpdates_sub();

        IBasketHandler bh = main.basketHandler();
        require(bh.fullyCapitalized(), "RToken uncapitalized");
        require(bh.status() == CollateralStatus.SOUND, "basket defaulted");

        uint256 firstId = firstRemainingDraft[era][account];
        CumulativeDraft[] storage queue = draftQueues[era][account];
        if (endId == 0 || firstId >= endId) return;

        require(endId <= queue.length, "index out-of-bounds");
        require(queue[endId - 1].availableAt <= block.timestamp, "withdrawal unavailable");

        uint256 oldDrafts = firstId > 0 ? queue[firstId - 1].drafts : 0;
        uint256 draftAmount = queue[endId - 1].drafts - oldDrafts;

        // advance queue past withdrawal
        firstRemainingDraft[era][account] = endId;

        // ==== Compute RSR amount
        uint256 newTotalDrafts = totalDrafts - draftAmount;
        uint256 newDraftRSR = toFix(newTotalDrafts).div(draftRate).toUint(); // TODO: less gassy
        uint256 rsrAmount = draftRSR - newDraftRSR;

        if (rsrAmount == 0) return;

        // ==== Transfer RSR from the draft pool
        totalDrafts = newTotalDrafts;
        draftRSR = newDraftRSR;

        emit UnstakingCompleted(firstId, endId, era, account, rsrAmount);
        IERC20Upgradeable(address(main.rsr())).safeTransfer(account, rsrAmount);
    }

    /// @param rsrAmount {qRSR}
    /// Must always seize exactly `rsrAmount`, or revert
    /// @custom:subroutine
    function seizeRSR(uint256 rsrAmount) external subroutine {
        require(_msgSender() == address(main.backingManager()), "not backing manager");
        require(rsrAmount > 0, "Amount cannot be zero");
        int192 initRate = exchangeRate();

        uint256 rsrBalance = main.rsr().balanceOf(address(this));
        require(rsrAmount <= rsrBalance, "Cannot seize more RSR than we hold");
        if (rsrBalance == 0) return;

        // Calculate dust RSR threshold, the point at which we might as well call it a wipeout
        uint256 dustRSRAmt = MIN_EXCHANGE_RATE.mulu_toUint(totalDrafts + totalStakes); // {qRSR}

        uint256 seizedRSR;
        if (rsrBalance <= rsrAmount + dustRSRAmt) {
            // Total RSR stake wipeout.
            seizedRSR = rsrBalance;

            // Zero all stakes and withdrawals
            stakeRSR = 0;
            draftRSR = 0;
            totalStakes = 0;
            totalDrafts = 0;
            era++;

            stakeRate = FIX_ONE;
            draftRate = FIX_ONE;

            emit AllBalancesReset(era);
        } else {
            uint256 rewards = rsrRewards();

            // Remove RSR evenly from stakeRSR, draftRSR, and the reward pool
            uint256 stakeRSRToTake = (stakeRSR * rsrAmount + (rsrBalance - 1)) / rsrBalance;
            stakeRSR -= stakeRSRToTake;
            seizedRSR = stakeRSRToTake;
            stakeRate = stakeRSR == 0 ? FIX_ONE : divuu(totalStakes, stakeRSR);

            uint256 draftRSRToTake = (draftRSR * rsrAmount + (rsrBalance - 1)) / rsrBalance;
            draftRSR -= draftRSRToTake;
            seizedRSR += draftRSRToTake;
            draftRate = draftRSR == 0 ? FIX_ONE : divuu(totalDrafts, draftRSR);

            // Removing from unpaid rewards is implicit
            seizedRSR += (rewards * rsrAmount + (rsrBalance - 1)) / rsrBalance;
        }

        // Transfer RSR to caller
        emit ExchangeRateSet(initRate, exchangeRate());
        IERC20Upgradeable(address(main.rsr())).safeTransfer(_msgSender(), seizedRSR);
    }

    /// @return {qStRSR/qRSR} The exchange rate between StRSR and RSR
    function exchangeRate() public view returns (int192) {
        return stakeRate;
    }

    /// Return the maximum valid value of endId such that withdraw(endId) should immediately work
    /// This search may be slightly expensive.
    /// TODO: experiment! For what values of queue.length - firstId is this actually cheaper
    ///     than linear search?
    function endIdForWithdraw(address account) external view returns (uint256) {
        uint256 time = block.timestamp;
        CumulativeDraft[] storage queue = draftQueues[era][account];

        // Bounds our search for the current cumulative draft
        (uint256 left, uint256 right) = (firstRemainingDraft[era][account], queue.length);

        // If there are no drafts to be found, return 0 drafts
        if (left >= right) return right;
        if (queue[left].availableAt > time) return left;

        // Otherwise, there *are* drafts with left <= index < right and availableAt <= time.
        // Binary search, keeping true that (queue[left].availableAt <= time) and
        //   (right == queue.length or queue[right].availableAt > time)
        uint256 test;
        while (left < right - 1) {
            test = (left + right) / 2;
            if (queue[test].availableAt <= time) left = test;
            else right = test;
        }
        return right;
    }

    // ==== Internal Functions ====

    /// Assign reward payouts to the staker pool
    /// @dev do this by effecting stakeRSR and payoutLastPaid as appropriate, given the current
    /// value of rsrRewards()
    function _payoutRewards() internal {
        if (block.timestamp < payoutLastPaid + rewardPeriod) return;
        uint32 numPeriods = (uint32(block.timestamp) - payoutLastPaid) / rewardPeriod;

        int192 initRate = exchangeRate();

        // Paying out the ratio r, N times, equals paying out the ratio (1 - (1-r)^N) 1 time.
        // Apply payout to RSR backing
        int192 payoutRatio = FIX_ONE.minus(FIX_ONE.minus(rewardRatio).powu(numPeriods));

        stakeRSR += payoutRatio.mulu_toUint(rsrRewardsAtLastPayout);
        payoutLastPaid += numPeriods * rewardPeriod;
        rsrRewardsAtLastPayout = rsrRewards();

        stakeRate = (stakeRSR == 0 || totalStakes == 0)
            ? FIX_ONE
            : toFix(totalStakes).divu(stakeRSR);

        emit ExchangeRateSet(initRate, exchangeRate());
    }

    /// @return {qRSR} The balance of RSR that this contract owns dedicated to future RSR rewards.
    function rsrRewards() internal view returns (uint256) {
        return main.rsr().balanceOf(address(this)) - stakeRSR - draftRSR;
    }

    // ==== ERC20 Overrides ====

    function totalSupply()
        public
        view
        override(ERC20Upgradeable, IERC20Upgradeable)
        returns (uint256)
    {
        return totalStakes;
    }

    function balanceOf(address account)
        public
        view
        override(ERC20Upgradeable, IERC20Upgradeable)
        returns (uint256)
    {
        return stakes[era][account];
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        uint256 fromBalance = stakes[era][from];

        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");

        unchecked {
            stakes[era][from] = fromBalance - amount;
        }

        stakes[era][to] += amount;
    }

    // ==== endERC20 Overrides ====

    // ==== Gov Param Setters ====

    /// @custom:governance
    function setUnstakingDelay(uint32 val) external governance {
        emit UnstakingDelaySet(unstakingDelay, val);
        unstakingDelay = val;
        require(rewardPeriod * 2 <= unstakingDelay, "unstakingDelay/rewardPeriod incompatible");
    }

    /// @custom:governance
    function setRewardPeriod(uint32 val) external governance {
        emit RewardPeriodSet(rewardPeriod, val);
        rewardPeriod = val;
        require(rewardPeriod * 2 <= unstakingDelay, "unstakingDelay/rewardPeriod incompatible");
    }

    /// @custom:governance
    function setRewardRatio(int192 val) external governance {
        emit RewardRatioSet(rewardRatio, val);
        rewardRatio = val;
    }
}
