// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "contracts/interfaces/IMain.sol";
import "contracts/interfaces/IRToken.sol";
import "contracts/libraries/Fixed.sol";
import "contracts/p0/Rewardable.sol";

/**
 * @title RToken
 * @notice An ERC20 with an elastic supply and governable exchange rate to basket units.
 */
contract RToken is RewardableP0, ERC20Permit, IRToken {
    using EnumerableSet for EnumerableSet.AddressSet;
    using FixLib for Fix;
    using SafeERC20 for IERC20;

    Fix public constant MIN_ISS_RATE = Fix.wrap(1e40); // {qRTok/block} 10k whole RTok

    // Enforce a fixed issuanceRate throughout the entire block by caching it.
    Fix public lastIssRate; // {qRTok/block}
    uint256 public lastIssRateBlock; // {block number}

    // When the all pending issuances will have vested.
    // This is fractional so that we can represent partial progress through a block.
    Fix public allVestAt; // {fractional block number}

    // IssueItem: One edge of an issuance
    struct IssueItem {
        uint256 when; // {block number}
        uint256 amtRToken; // {qRTok} Total amount of RTokens that have vested by `when`
        Fix amtBaskets; // {BU} Total amount of baskets that should back those RTokens
        uint256[] deposits; // {qTok}, Total amounts of basket collateral deposited for vesting
    }

    struct IssueQueue {
        uint256 basketNonce; // The nonce of the basket this queue models deposits against
        address[] tokens; // Addresses of the erc20 tokens modelled by deposits in this queue
        uint256 left; // [left, right) is the span of currently-valid items
        uint256 right; //
        IssueItem[] items; // The actual items (The issuance "fenceposts")
    }
    /* An initialized IssueQueue should start with a zero-value item. // TODO FIXME
     * If we want to clean up state, it's safe to delete items[x] iff x < left.
     * For an initialized IssueQueue queue:
     *     queue.items.right >= left
     *     queue.items.right == left  iff  there are no more pending issuances here
     *
     * The short way to describe this is that IssueQueue stores _cumulative_ issuances, not raw
     * issuances, and so any particular issuance is actually the _difference_ between two adjaacent
     * TotalIssue items in an IssueQueue.
     *
     * The way to keep an IssueQueue striaght in your head is to think of each TotalIssue item as a
     * "fencpost" in the queue of actual issuances. The true issuances are the spans between the
     * TotalIssue items. For example, if:
     *    queue.items[queue.left].amtRToken == 1000 , and
     *    queue.items[queue.right].amtRToken == 6000,
     * then the issuance "between" them is 5000 RTokens. If we waited long enough and then called
     * vest() on that account, we'd vest 5000 RTokens *to* that account.
     */

    mapping(address => IssueQueue) public issueQueues;

    Fix public basketsNeeded; // {BU}

    Fix public issuanceRate; // {%} of RToken supply to issue per block

    // solhint-disable no-empty-blocks
    constructor(string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {}

    // solhint-enable no-empty-blocks

    function init(ConstructorArgs calldata args) internal override {
        issuanceRate = args.params.issuanceRate;
        emit IssuanceRateSet(FIX_ZERO, issuanceRate);
    }

    function setIssuanceRate(Fix val) external onlyOwner {
        emit IssuanceRateSet(issuanceRate, val);
        issuanceRate = val;
    }

    /// Begin a time-delayed issuance of RToken for basket collateral
    /// User Action
    /// @param amtRToken {qTok} The quantity of RToken to issue
    /// @return deposits {qTok} The quantities of collateral tokens transferred in
    function issue(uint256 amtRToken) external notPaused returns (uint256[] memory deposits) {
        // ==== Basic Setup ====
        // Call collective state keepers.
        main.poke(); // TODO: only call what you really need, there should be no en-masse poke()!
        IBasketHandler basketHandler = main.basketHandler();
        require(basketHandler.status() == CollateralStatus.SOUND, "collateral not sound");
        (uint256 basketNonce, ) = main.basketHandler().lastSet();

        // Refund issuances against previous baskets
        address issuer = _msgSender();
        refundOldBasketIssues(issuer);

        // ==== Compute and accept collateral ====
        Fix amtBaskets = (totalSupply() > 0) // {BU}
            ? basketsNeeded.mulu(amtRToken).divuRound(totalSupply()) // {BU * qRTok / qRTok}
            : toFixWithShift(amtRToken, -int8(decimals())); // {qRTok / qRTok}

        address[] memory erc20s;
        (erc20s, deposits) = basketHandler.quote(amtBaskets, RoundingApproach.CEIL);

        // Accept collateral
        for (uint256 i = 0; i < erc20s.length; i++) {
            IERC20(erc20s[i]).safeTransferFrom(issuer, address(this), deposits[i]);
        }

        // ==== Enqueue the issuance ====
        IssueQueue storage queue = issueQueues[issuer];
        assert(queue.left == queue.right || queue.basketNonce == basketNonce);

        // Add amtRToken's worth of issuance delay to allVestAt
        Fix vestingEnd = whenFinished(amtRToken);

        // Push issuance onto queue
        IssueItem storage prev = queue.items[queue.right - 1];
        IssueItem storage curr = (
            queue.items.length == queue.right ? queue.items.push() : queue.items[queue.right]
        );

        curr.when = vestingEnd.floor();
        curr.amtRToken = prev.amtRToken + amtRToken;
        curr.amtBaskets = prev.amtBaskets.plus(amtBaskets);
        for (uint256 i = 0; i < deposits.length; i++) {
            curr.deposits[i] = prev.deposits[i] + deposits[i];
        }
        queue.right++;

        emit IssuanceStarted(
            issuer,
            queue.right,
            amtRToken,
            amtBaskets,
            erc20s,
            deposits,
            vestingEnd
        );

        // Vest immediately if the vesting fits into this block.
        if (curr.when <= block.number) vestUpTo(issuer, queue.right);
    }

    /// Add amtRToken's worth of issuance delay to allVestAt, and return the resulting finish time.
    /// @return finished the new value of allVestAt
    function whenFinished(uint256 amtRToken) private returns (Fix finished) {
        // Calculate the issuance rate (if this is the first issuance in the block)
        if (lastIssRateBlock < block.number) {
            lastIssRateBlock = block.number;
            lastIssRate = fixMax(MIN_ISS_RATE, issuanceRate.mulu(totalSupply()));
        }

        // Add amtRToken's worth of issuance delay to allVestAt
        finished = fixMin(allVestAt, toFix(block.number - 1)).plus(divFix(amtRToken, lastIssRate));
        allVestAt = finished;
    }

    /// Vest all available issuance for the account
    /// Callable by anyone!
    /// @param account The address of the account to vest issuances for
    /// @return vested {qRTok} The total amtRToken of RToken quanta vested
    function vest(address account, uint256 endId) external notPaused returns (uint256 vested) {
        require(main.basketHandler().status() == CollateralStatus.SOUND, "collateral default");

        main.poke();
        refundOldBasketIssues(account);
        return vestUpTo(account, endId);
    }

    function endIdForVest(address account) external view returns (uint256) {
        IssueQueue storage queue = issueQueues[account];

        // Handle common edge cases in O(1)
        if (queue.left == queue.right) return queue.left;
        if (block.timestamp < queue.items[queue.left].when) return queue.left;
        if (queue.items[queue.right].when <= block.timestamp) return queue.right;

        // find left and right (using binary search where always left <= right) such that:
        //     left == right - 1
        //     queue[left].when <= block.timestamp
        //     right == queue.right  or  block.timestamp < queue[right].when
        uint256 left = queue.left;
        uint256 right = queue.right;
        while (left < right - 1) {
            uint256 test = (left + right) / 2;
            if (queue.items[test].when <= block.timestamp) left = test;
            else right = test;
        }
        return right;
    }

    /// Cancel some vesting issuance(s)
    /// If earliest == true, cancel id if id < endId
    /// If earliest == false, cancel id if endId <= id
    /// @param endId The issuance index to cancel through
    /// @param earliest If true, cancel earliest issuances; else, cancel latest issuances
    function cancel(uint256 endId, bool earliest) external returns (uint256[] memory deposits) {
        address account = _msgSender();
        IssueQueue storage queue = issueQueues[account];

        require(queue.left <= endId && endId < queue.right, "'endId' is out of range");

        if (earliest) {
            deposits = refundSpan(account, queue.left, endId);
            queue.left = endId;
        } else {
            deposits = refundSpan(account, endId, queue.right);
            queue.right = endId;
        }
    }

    /// Redeem RToken for basket collateral
    /// User Action
    /// @param amount {qTok} The quantity {qRToken} of RToken to redeem
    /// @return withdrawals {qTok} The quantities of collateral tokens transferred out
    function redeem(uint256 amount) external returns (uint256[] memory withdrawals) {
        require(amount > 0, "Cannot redeem zero");
        // Call collective state keepers
        main.poke();
        IBasketHandler basketHandler = main.basketHandler();

        require(balanceOf(_msgSender()) >= amount, "not enough RToken");

        // {BU} = {BU} * {qRTok} / {qRTok}
        Fix baskets = basketsNeeded.mulu(amount).divuRound(totalSupply());
        assert(baskets.lte(basketsNeeded));

        address[] memory erc20s;
        (erc20s, withdrawals) = basketHandler.quote(baskets, RoundingApproach.FLOOR);

        // {1} = {qRTok} / {qRTok}
        Fix prorate = toFix(amount).divu(totalSupply());

        // Accept and burn RToken
        _burn(_msgSender(), amount);

        emit BasketsNeededChanged(basketsNeeded, basketsNeeded.minus(baskets));
        basketsNeeded = basketsNeeded.minus(baskets);

        // ==== Send back collateral tokens ====
        IBackingManager backingMgr = main.backingManager();
        backingMgr.grantAllowances();

        for (uint256 i = 0; i < erc20s.length; i++) {
            // Bound each withdrawal by the prorata share, in case we're currently under-capitalized
            uint256 bal = IERC20(erc20s[i]).balanceOf(address(backingMgr));
            // {qTok} = {1} * {qTok}
            uint256 prorata = prorate.mulu(bal).floor();
            withdrawals[i] = Math.min(withdrawals[i], prorata);
            // Send withdrawal
            IERC20(erc20s[i]).safeTransferFrom(address(backingMgr), _msgSender(), withdrawals[i]);
        }

        emit Redemption(_msgSender(), amount, baskets);
    }

    /// Mint a quantity of RToken to the `recipient`, decreasing the basket rate
    /// @param recipient The recipient of the newly minted RToken
    /// @param amtRToken {qRTok} The amtRToken to be minted
    function mint(address recipient, uint256 amtRToken) external onlyComponent {
        _mint(recipient, amtRToken);
    }

    /// Melt a quantity of RToken from the caller's account, increasing the basket rate
    /// @param amtRToken {qRTok} The amtRToken to be melted
    function melt(uint256 amtRToken) external {
        _burn(_msgSender(), amtRToken);
        emit Melted(amtRToken);
    }

    /// An affordance of last resort for Main in order to ensure re-capitalization
    function setBasketsNeeded(Fix basketsNeeded_) external onlyComponent {
        emit BasketsNeededChanged(basketsNeeded, basketsNeeded_);
        basketsNeeded = basketsNeeded_;
    }

    function setMain(IMain main_) external onlyOwner {
        emit MainSet(main, main_);
        main = main_;
    }

    /// @return {qRTok} How much RToken `account` can issue given current holdings
    function maxIssuable(address account) external view returns (uint256) {
        // {BU}
        Fix held = main.basketHandler().basketsHeldBy(account);

        // return {qRTok} = {BU} * {(1 RToken) qRTok/BU)}
        if (basketsNeeded.eq(FIX_ZERO)) return held.shiftLeft(int8(decimals())).floor();

        // {qRTok} = {BU} * {qRTok} / {BU}
        return held.mulu(totalSupply()).div(basketsNeeded).floor();
    }

    /// @return p {UoA/rTok} The protocol's best guess of the RToken price on markets
    function price() external view returns (Fix p) {
        if (totalSupply() == 0) return main.basketHandler().price();

        Fix supply = toFixWithShift(totalSupply(), -int8(decimals()));
        // {UoA/rTok} = {UoA/BU} * {BU} / {rTok}
        return main.basketHandler().price().mul(basketsNeeded).div(supply);
    }

    // ==== private ====
    /// Refund all deposits in the span [left, right)
    /// This does *not* fixup queue.left and queue.right!
    function refundSpan(
        address account,
        uint256 left,
        uint256 right
    ) private returns (uint256[] memory deposits) {
        IssueQueue storage queue = issueQueues[account];
        if (left >= right) return deposits;

        // compute total deposits
        IssueItem storage rightItem = queue.items[right - 1];
        if (queue.left == 0) {
            for (uint256 i = 0; i < queue.tokens.length; i++) {
                deposits[i] = rightItem.deposits[i];
            }
        } else {
            IssueItem storage leftItem = queue.items[queue.left - 1];
            for (uint256 i = 0; i < queue.tokens.length; i++) {
                deposits[i] = rightItem.deposits[i] - leftItem.deposits[i];
            }
        }

        // transfer deposits
        for (uint256 i = 0; i < queue.tokens.length; i++) {
            IERC20(queue.tokens[i]).safeTransfer(address(main), deposits[i]);
        }

        // emit issuancesCanceled
        emit IssuancesCanceled(account, left, right);
    }

    /// Vest all RToken issuance in queue = queues[account], from queue.left through index `through`
    /// This *does* fixup queue.left and queue.right!
    function vestUpTo(address account, uint256 endId) private returns (uint256 amtRToken) {
        IssueQueue storage queue = issueQueues[account];
        if (queue.left == endId) return 0;
        assert(queue.left < endId && endId <= queue.right); // out- of-bounds error

        // Vest the span up to `endId`.
        uint256 amtRTokenToMint;
        Fix newBasketsNeeded;
        IssueItem storage rightItem = queue.items[endId];

        if (queue.left == 0) {
            for (uint256 i = 0; i < queue.tokens.length; i++) {
                uint256 amtDeposit = rightItem.deposits[i];
                IERC20(queue.tokens[i]).safeTransfer(address(main), amtDeposit);
            }
            amtRTokenToMint = rightItem.amtRToken;
            newBasketsNeeded = basketsNeeded.plus(rightItem.amtBaskets);
        } else {
            IssueItem storage leftItem = queue.items[queue.left - 1];
            for (uint256 i = 0; i < queue.tokens.length; i++) {
                uint256 amtDeposit = rightItem.deposits[i] - leftItem.deposits[i];
                IERC20(queue.tokens[i]).safeTransfer(address(main), amtDeposit);
            }
            amtRTokenToMint = rightItem.amtRToken - leftItem.amtRToken;
            newBasketsNeeded = basketsNeeded.plus(rightItem.amtBaskets).minus(leftItem.amtBaskets);
        }

        _mint(account, amtRTokenToMint);
        basketsNeeded = newBasketsNeeded;
        emit BasketsNeededChanged(basketsNeeded, newBasketsNeeded);

        emit IssuancesCompleted(account, queue.left, endId);
        queue.left = endId;
    }

    /// If account's queue models an old basket, refund those issuances.
    function refundOldBasketIssues(address account) private {
        IssueQueue storage queue = issueQueues[account];
        (uint256 basketNonce, ) = main.basketHandler().lastSet();
        // ensure that the queue models issuances against the current basket, not previous baskets
        if (queue.basketNonce != basketNonce) {
            refundSpan(account, queue.left, queue.right);
            queue.left = 0;
            queue.right = 0;
        }
    }
}
