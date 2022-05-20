// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "contracts/interfaces/IAsset.sol";
import "contracts/interfaces/IAssetRegistry.sol";
import "contracts/interfaces/IMain.sol";
import "contracts/interfaces/ITrading.sol";
import "contracts/libraries/Fixed.sol";

// Gnosis: uint96 ~= 7e28
uint256 constant GNOSIS_MAX_TOKENS = 7e28;

/**
 * @title TradingLibP0
 * @notice An informal extension of the Trading mixin that provides trade preparation views
 * @dev The caller must implement the ITrading interface!
 */
library TradingLibP0 {
    using FixLib for uint192;

    /// Prepare an trade to sell `sellAmount` that guarantees a reasonable closing price,
    /// without explicitly aiming at a particular quantity to purchase.
    /// @param sellAmount {sellTok}
    /// @return notDust True when the trade is larger than the dust amount
    /// @return trade The prepared trade
    function prepareTradeSell(
        IAsset sell,
        IAsset buy,
        uint192 sellAmount
    ) public view returns (bool notDust, TradeRequest memory trade) {
        assert(sell.price().neq(FIX_ZERO) && buy.price().neq(FIX_ZERO));
        trade.sell = sell;
        trade.buy = buy;

        // Don't sell dust.
        if (sellAmount.lt(dustThreshold(sell))) return (false, trade);

        // {sellTok}
        uint192 s = fixMin(sellAmount, sell.maxTradeVolume().div(sell.price(), FLOOR));
        trade.sellAmount = s.shiftl_toUint(int8(sell.erc20().decimals()), FLOOR);

        // Do not consider 1 qTok a viable sell amount
        if (trade.sellAmount <= 1) return (false, trade);

        // Do not overflow auction mechanism - sell side
        if (trade.sellAmount > GNOSIS_MAX_TOKENS) {
            trade.sellAmount = GNOSIS_MAX_TOKENS;
            s = shiftl_toFix(trade.sellAmount, -int8(sell.erc20().decimals()));
        }

        // {buyTok} = {sellTok} * {UoA/sellTok} / {UoA/buyTok}
        uint192 b = s.mul(FIX_ONE.minus(maxTradeSlippage())).mulDiv(
            sell.price(),
            buy.price(),
            CEIL
        );
        trade.minBuyAmount = b.shiftl_toUint(int8(buy.erc20().decimals()), CEIL);

        // Do not overflow auction mechanism - buy side
        if (trade.minBuyAmount > GNOSIS_MAX_TOKENS) {
            uint192 over = FIX_ONE.muluDivu(trade.minBuyAmount, GNOSIS_MAX_TOKENS);
            trade.sellAmount = divFix(trade.sellAmount, over).toUint(FLOOR);
            trade.minBuyAmount = divFix(trade.minBuyAmount, over).toUint(CEIL);
        }
        return (true, trade);
    }

    /// Assuming we have `maxSellAmount` sell tokens avaialable, prepare an trade to
    /// cover as much of our deficit as possible, given expected trade slippage.
    /// @param maxSellAmount {sellTok}
    /// @param deficitAmount {buyTok}
    /// @return notDust Whether the prepared trade is large enough to be worth trading
    /// @return trade The prepared trade
    function prepareTradeToCoverDeficit(
        IAsset sell,
        IAsset buy,
        uint192 maxSellAmount,
        uint192 deficitAmount
    ) public view returns (bool notDust, TradeRequest memory trade) {
        // Don't sell dust.
        if (maxSellAmount.lt(dustThreshold(sell))) return (false, trade);

        // Don't buy dust.
        deficitAmount = fixMax(deficitAmount, dustThreshold(buy));

        // {sellTok} = {buyTok} * {UoA/buyTok} / {UoA/sellTok}
        uint192 exactSellAmount = deficitAmount.mulDiv(buy.price(), sell.price(), CEIL);
        // exactSellAmount: Amount to sell to buy `deficitAmount` if there's no slippage

        // slippedSellAmount: Amount needed to sell to buy `deficitAmount`, counting slippage
        uint192 slippedSellAmount = exactSellAmount.div(FIX_ONE.minus(maxTradeSlippage()), CEIL);

        uint192 sellAmount = fixMin(slippedSellAmount, maxSellAmount);
        return prepareTradeSell(sell, buy, sellAmount);
    }

    // Compute max surpluse relative to basketTop and max deficit relative to basketBottom
    /// @param useFallenTarget If true, trade towards a reduced BU target
    /// @return surplus Surplus asset OR address(0)
    /// @return deficit Deficit collateral OR address(0)
    /// @return sellAmount {sellTok} Surplus amount (whole tokens)
    /// @return buyAmount {buyTok} Deficit amount (whole tokens)
    function largestSurplusAndDeficit(bool useFallenTarget)
        external
        view
        returns (
            IAsset surplus,
            ICollateral deficit,
            uint192 sellAmount,
            uint192 buyAmount
        )
    {
        IERC20[] memory erc20s = assetRegistry().erc20s();

        // Compute basketTop and basketBottom
        // basketTop is the lowest number of BUs to which we'll try to sell surplus assets
        // basketBottom is the greatest number of BUs to which we'll try to buy deficit assets
        uint192 basketTop = rToken().basketsNeeded(); // {BU}
        uint192 basketBottom = basketTop; // {BU}

        if (useFallenTarget) {
            uint192 tradeVolume; // {UoA}
            uint192 totalValue; // {UoA}
            for (uint256 i = 0; i < erc20s.length; i++) {
                IAsset asset = assetRegistry().toAsset(erc20s[i]);

                // Ignore dust amounts for assets not in the basket
                uint192 bal = asset.bal(address(this)); // {tok}
                if (basket().quantity(erc20s[i]).gt(FIX_ZERO) || bal.gt(dustThreshold(asset))) {
                    // {UoA} = {UoA} + {UoA/tok} * {tok}
                    totalValue = totalValue.plus(asset.price().mul(bal, FLOOR));
                }
            }
            basketTop = totalValue.div(basket().price(), CEIL);

            for (uint256 i = 0; i < erc20s.length; i++) {
                IAsset asset = assetRegistry().toAsset(erc20s[i]);
                if (!asset.isCollateral()) continue;
                uint192 needed = basketTop.mul(basket().quantity(erc20s[i]), CEIL); // {tok}
                uint192 held = asset.bal(address(this)); // {tok}

                if (held.lt(needed)) {
                    // {UoA} = {UoA} + ({tok} - {tok}) * {UoA/tok}
                    tradeVolume = tradeVolume.plus(needed.minus(held).mul(asset.price(), FLOOR));
                }
            }

            // bBot {BU} = (totalValue - mTS * tradeVolume) / basket.price
            basketBottom = totalValue.minus(maxTradeSlippage().mul(tradeVolume)).div(
                basket().price(),
                CEIL
            );
        }

        return surplusDeficitHelper(erc20s, basketTop, basketBottom);
    }

    /// @param basketTop {BU} The lowest number of BUs at which we would be willing to sell
    /// @param basketBottom {BU} The greatest number of BUs at which we would be willing to buy
    function surplusDeficitHelper(
        IERC20[] memory erc20s,
        uint192 basketTop,
        uint192 basketBottom
    )
        private
        view
        returns (
            IAsset surplus,
            ICollateral deficit,
            uint192 sellAmount,
            uint192 buyAmount
        )
    {
        uint192 maxSurplus;
        uint192 maxDeficit;
        for (uint256 i = 0; i < erc20s.length; i++) {
            if (erc20s[i] == rsr()) continue; // do not consider RSR

            IAsset asset = assetRegistry().toAsset(erc20s[i]);
            uint192 bal = asset.bal(address(this));

            // Token Threshold - top
            uint192 tokenThreshold = basketTop.mul(basket().quantity(erc20s[i]), CEIL); // {tok};
            if (bal.gt(tokenThreshold)) {
                // {UoA} = ({tok} - {tok}) * {UoA/tok}
                uint192 deltaTop = bal.minus(tokenThreshold).mul(asset.price(), FLOOR);
                if (deltaTop.gt(maxSurplus)) {
                    surplus = asset;
                    maxSurplus = deltaTop;

                    // {tok} = {UoA} / {UoA/tok}
                    sellAmount = fixMin(bal, maxSurplus.div(surplus.price()));
                }
            } else {
                // Token Threshold - bottom
                tokenThreshold = basketBottom.mul(basket().quantity(erc20s[i]), CEIL); // {tok}
                if (bal.lt(tokenThreshold)) {
                    // {UoA} = ({tok} - {tok}) * {UoA/tok}
                    uint192 deltaBottom = tokenThreshold.minus(bal).mul(asset.price(), CEIL);
                    if (deltaBottom.gt(maxDeficit)) {
                        deficit = ICollateral(address(asset));
                        maxDeficit = deltaBottom;

                        // {tok} = {UoA} / {UoA/tok}
                        buyAmount = maxDeficit.div(deficit.price(), CEIL);
                    }
                }
            }
        }
    }

    // === Getters ===

    /// @return {%}
    function maxTradeSlippage() private view returns (uint192) {
        return ITrading(address(this)).maxTradeSlippage();
    }

    /// @return {tok} The least amount of whole tokens ever worth trying to sell
    function dustThreshold(IAsset asset) private view returns (uint192) {
        // {tok} = {UoA} / {UoA/tok}
        return ITrading(address(this)).dustAmount().div(asset.price());
    }

    /// @return The AssetRegistry
    function assetRegistry() private view returns (IAssetRegistry) {
        return ITrading(address(this)).main().assetRegistry();
    }

    /// @return The BasketHandler
    function basket() private view returns (IBasketHandler) {
        return ITrading(address(this)).main().basketHandler();
    }

    /// @return The RToken
    function rToken() private view returns (IRToken) {
        return ITrading(address(this)).main().rToken();
    }

    /// @return The RSR associated with this RToken
    function rsr() private view returns (IERC20) {
        return ITrading(address(this)).main().rsr();
    }
}
