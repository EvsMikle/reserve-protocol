// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "contracts/p0/libraries/Rewards.sol";
import "contracts/p0/interfaces/IMain.sol";
import "contracts/p0/interfaces/IMarket.sol";
import "contracts/p0/interfaces/IRewardsClaimer.sol";
import "contracts/libraries/Fixed.sol";
import "contracts/p0/main/VaultHandler.sol";

abstract contract TraderP0 is Ownable, IAuctioneerEvents, IRewardsClaimer {
    using FixLib for Fix;
    using SafeERC20 for IERC20;
    Auction[] public auctions;

    IMain public main;

    constructor(IMain main_) {
        main = main_;
    }

    /// The "driver" of this trader.
    /// Implementations should call closeDueAuctions(), decide what to do with auctioned funds, and decide what auctions to run
    /// (Though not necessarily in that order!)
    /// @return Whether this trader has any open auctions
    function poke() external virtual returns (bool);

    // TODO: poke() should return nothing, and we should add a hasOpenAuctions view to this class.

    /// Settle any auctions that are due (past their end time)
    /// @return Whether the trader has open auctions
    function closeDueAuctions() public virtual returns (bool) {
        // Closeout open auctions or sleep if they are still ongoing.
        for (uint256 i = 0; i < auctions.length; i++) {
            Auction storage auction = auctions[i];
            if (auction.status == AuctionStatus.OPEN) {
                if (block.timestamp <= auction.endTime) {
                    return true;
                }
                _closeAuction(auction, i);
            }
        }
        return false;
    }

    function setMain(IMain main_) external onlyOwner {
        main = main_;
    }

    /// Claims and sweeps all COMP/AAVE rewards
    function claimAndSweepRewards() external override {
        RewardsLib.claimAndSweepRewards(main);
    }


    /// Prepare an auction to sell `sellAmount` that guarantees a reasonable closing price
    /// @param sellAmount {qSellTok}
    /// @return notDust Whether the prepared auction is large enough to be worth trading
    /// @return auction The prepared auction
    function _prepareAuctionSell(
        IAsset sell,
        IAsset buy,
        uint256 sellAmount
    ) internal returns (bool notDust, Auction memory auction) {
        Oracle.Info memory oracle = main.oracle();
        // {attoUSD} = {attoUSD/qSellTok} * {qSellTok}
        Fix rTokenMarketCapUSD = main.rTokenAsset().priceUSD(oracle).mulu(
            main.rToken().totalSupply()
        );
        Fix maxSellUSD = rTokenMarketCapUSD.mul(main.maxAuctionSize()); // {attoUSD}

        if (sellAmount < _dustThreshold(sell)) {
            return (false, auction);
        }

        sellAmount = Math.min(sellAmount, maxSellUSD.div(sell.priceUSD(oracle)).toUint()); // {qSellTok}
        Fix exactBuyAmount = toFix(sellAmount).mul(sell.priceUSD(oracle)).div(buy.priceUSD(oracle)); // {qBuyTok}
        Fix minBuyAmount = exactBuyAmount.minus(exactBuyAmount.mul(main.maxTradeSlippage())); // {qBuyTok}

        return (
            true,
            Auction({
                sell: sell,
                buy: buy,
                sellAmount: sellAmount,
                minBuyAmount: minBuyAmount.toUint(),
                clearingSellAmount: 0,
                clearingBuyAmount: 0,
                externalAuctionId: 0,
                startTime: block.timestamp,
                endTime: block.timestamp + main.auctionPeriod(),
                status: AuctionStatus.NOT_YET_OPEN
            })
        );
    }

    /// Assuming we have `maxSellAmount` sell tokens avaialable, prepare an auction to
    /// cover as much of our deficit as possible, given expected trade slippage.
    /// @param maxSellAmount {qSellTok}
    /// @param deficitAmount {qBuyTok}
    /// @return notDust Whether the prepared auction is large enough to be worth trading
    /// @return auction The prepared auction
    function _prepareAuctionToCoverDeficit(
        IAsset sell,
        IAsset buy,
        uint256 maxSellAmount,
        uint256 deficitAmount
    ) internal returns (bool notDust, Auction memory auction) {
        Oracle.Info memory oracle = main.oracle();
        uint256 sellThreshold = _dustThreshold(sell);
        if (maxSellAmount < sellThreshold) {
            return (false, auction);
        }

        uint256 buyThreshold = _dustThreshold(buy);
        if (deficitAmount < buyThreshold) {
            deficitAmount = buyThreshold;
        }

        // {qSellTok} = {qBuyTok} * {attoUSD/qBuyTok} / {attoUSD/qSellTok}
        Fix exactSellAmount = toFix(deficitAmount).mul(buy.priceUSD(oracle)).div(
            sell.priceUSD(oracle)
        );

        // idealSellAmount = Amount needed to sell to buy `deficitAmount`
        uint256 idealSellAmount = exactSellAmount
        .div(FIX_ONE.minus(main.maxTradeSlippage()))
        .toUint();

        uint256 sellAmount = Math.min(idealSellAmount, maxSellAmount);
        return _prepareAuctionSell(sell, buy, sellAmount);
    }

    /// @return {qSellTok} The least amount of tokens worth trying to sell
    function _dustThreshold(IAsset asset) private view returns (uint256) {
        // {attoUSD} = {attoUSD/qSellTok} * {qSellTok}
        Fix rTokenMarketCapUSD = main.rTokenAsset().priceUSD(main.oracle()).mulu(
            main.rToken().totalSupply()
        );
        Fix minSellUSD = rTokenMarketCapUSD.mul(main.minRevenueAuctionSize()); // {attoUSD}

        // {attoUSD} / {attoUSD/qSellTok}
        return minSellUSD.div(asset.priceUSD(main.oracle())).toUint();
    }

    /// Launch an auction:
    /// - Add the auction to the local auction list
    /// - Create the auction in the external auction protocol
    /// - Emit AuctionStarted event
    /// @dev The struct must already be populated
    function _launchAuction(Auction memory auction_) internal {
        auctions.push(auction_);
        Auction storage auction = auctions[auctions.length - 1];

        auction.sell.erc20().safeApprove(address(main.market()), auction.sellAmount);

        auction.externalAuctionId = main.market().initiateAuction(
            auction.sell.erc20(),
            auction.buy.erc20(),
            block.timestamp + main.auctionPeriod(),
            block.timestamp + main.auctionPeriod(),
            uint96(auction.sellAmount),
            uint96(auction.minBuyAmount),
            0,
            0,
            false,
            address(0),
            new bytes(0)
        );
        auction.status = AuctionStatus.OPEN;

        emit AuctionStarted(
            auctions.length - 1,
            address(auction.sell),
            address(auction.buy),
            auction.sellAmount,
            auction.minBuyAmount
        );
    }

    function _closeAuction(Auction storage auction, uint256 i) private {
        require(auction.status == AuctionStatus.OPEN, "can only close in-progress auctions");
        require(auction.endTime <= block.timestamp, "auction not over");

        bytes32 encodedOrder = main.market().settleAuction(auction.externalAuctionId);
        (auction.clearingSellAmount, auction.clearingBuyAmount) = _decodeOrder(encodedOrder);

        uint256 bal = auction.buy.erc20().balanceOf(address(this)); // {qBuyTok}
        auction.status = AuctionStatus.DONE;

        emit AuctionEnded(
            i,
            address(auction.sell),
            address(auction.buy),
            auction.clearingSellAmount,
            auction.clearingBuyAmount
        );
    }

    /// Decode EasyAuction output into its components.
    function _decodeOrder(bytes32 encodedOrder)
        private pure
        returns (uint256 amountSold, uint256 amountBought)
    {
        // Note: explicitly converting to a uintN truncates those bits that don't fit
        uint256 value = uint256(encodedOrder);
        amountSold = uint96(value);
        amountBought = uint96(value >> 96);
    }
}
