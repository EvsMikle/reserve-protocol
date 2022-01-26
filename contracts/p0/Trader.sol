// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "contracts/p0/interfaces/IMain.sol";
import "contracts/p0/interfaces/IMarket.sol";
import "contracts/p0/libraries/Rewards.sol";
import "contracts/p0/main/BasketHandler.sol";
import "contracts/libraries/Fixed.sol";

abstract contract TraderP0 is Ownable, Mixin, IAuctioneerEvents {
    using FixLib for Fix;
    using SafeERC20 for IERC20Metadata;

    Auction[] public auctions;

    uint256 private countOpenAuctions;

    IMain public main;

    function initTrader(address main_) public virtual {
        main = IMain(main_);
    }

    // solhint-disable no-empty-blocks

    /// The driver of each concrete trader. Implementations should call closeDueAuctions(), decide
    /// what to do with auctioned funds, and decide what auctions to run, though not necessarily in
    /// that order.
    function poke() public virtual override {}

    /// Settle any auctions that are due (past their end time)
    function closeDueAuctions() public {
        // Closeout open auctions or sleep if they are still ongoing.
        for (uint256 i = 0; i < auctions.length; i++) {
            Auction storage auction = auctions[i];
            if (auction.status == AuctionStatus.OPEN) {
                if (block.timestamp >= auction.endTime) {
                    _closeAuction(auction, i);
                }
            }
        }
    }

    /// @return true iff this trader now has open auctions.
    function hasOpenAuctions() public view returns (bool) {
        return countOpenAuctions > 0;
    }

    /// Prepare an auction to sell `sellAmount` that guarantees a reasonable closing price
    /// @param sellAmount {qSellTok}
    /// @return notDust Whether the prepared auction is large enough to be worth trading
    /// @return auction The prepared auction
    function _prepareAuctionSell(
        IAsset sell,
        IAsset buy,
        uint256 sellAmount
    ) internal view returns (bool notDust, Auction memory auction) {
        if (sell.price().eq(FIX_ZERO) || buy.price().eq(FIX_ZERO)) {
            return (false, auction);
        }

        // {attoUSD} = {attoUSD/qRTok} * {qRTok}
        Fix rTokenMarketCapUSD = main.rTokenAsset().price().mulu(main.rToken().totalSupply());
        Fix maxSellUSD = rTokenMarketCapUSD.mul(main.maxAuctionSize()); // {attoUSD}

        if (sellAmount < _dustThreshold(sell)) {
            return (false, auction);
        }

        // TODO: Should this be floor?
        sellAmount = Math.min(sellAmount, maxSellUSD.div(sell.price()).ceil()); // {qSellTok}
        Fix exactBuyAmount = toFix(sellAmount).mul(sell.price()).div(buy.price()); // {qBuyTok}
        Fix minBuyAmount = exactBuyAmount.mul(FIX_ONE.minus(main.maxTradeSlippage())); // {qBuyTok}

        return (
            true,
            Auction({
                sell: sell,
                buy: buy,
                sellAmount: sellAmount,
                minBuyAmount: minBuyAmount.ceil(),
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
    ) internal view returns (bool notDust, Auction memory auction) {
        // Don't sell dust.
        if (maxSellAmount < _dustThreshold(sell)) {
            return (false, auction);
        }
        // Don't buy dust.
        deficitAmount = Math.max(deficitAmount, _dustThreshold(buy));

        // {qSellTok} = {qBuyTok} * {attoUSD/qBuyTok} / {attoUSD/qSellTok}
        Fix exactSellAmount = toFix(deficitAmount).mul(buy.price()).div(sell.price());
        // exactSellAmount: Amount to sell to buy `deficitAmount` if there's no slippage

        // idealSellAmount: Amount needed to sell to buy `deficitAmount`, counting slippage
        uint256 idealSellAmount = exactSellAmount
            .div(FIX_ONE.minus(main.maxTradeSlippage()))
            .ceil();

        uint256 sellAmount = Math.min(idealSellAmount, maxSellAmount);
        return _prepareAuctionSell(sell, buy, sellAmount);
    }

    /// @return {qSellTok} The least amount of tokens worth trying to sell
    function _dustThreshold(IAsset asset) internal view returns (uint256) {
        // {attoUSD} = {attoUSD/qSellTok} * {qSellTok}
        Fix rTokenMarketCapUSD = main.rTokenAsset().price().mulu(main.rToken().totalSupply());

        // {attoUSD}
        Fix minSellUSD = rTokenMarketCapUSD.mul(main.minRevenueAuctionSize());

        // {attoUSD} / {attoUSD/qSellTok}
        return minSellUSD.div(asset.price()).ceil();
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
        countOpenAuctions += 1;

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

        auction.status = AuctionStatus.DONE;

        countOpenAuctions -= 1;

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
        private
        pure
        returns (uint256 amountSold, uint256 amountBought)
    {
        // Note: explicitly converting to a uintN truncates those bits that don't fit
        uint256 value = uint256(encodedOrder);
        amountSold = uint96(value);
        amountBought = uint96(value >> 96);
    }
}
