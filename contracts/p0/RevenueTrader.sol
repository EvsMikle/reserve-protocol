// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "contracts/interfaces/IMain.sol";
import "contracts/interfaces/IAssetRegistry.sol";
import "contracts/p0/mixins/Trading.sol";

/// Trader Component that converts all asset balances at its address to a
/// single target asset and sends this asset to the Distributor.
contract RevenueTradingP0 is TradingP0, IRevenueTrader {
    using FixLib for int192;

    IERC20 public immutable tokenToBuy;

    constructor(IERC20 tokenToBuy_) {
        tokenToBuy = tokenToBuy_;
    }

    function init(ConstructorArgs calldata args) internal override {
        TradingP0.init(args);
    }

    /// Close any open trades and start new ones, for all assets
    /// Collective Action
    function manageFunds() external {
        // Call state keepers
        main.poke();

        IERC20[] memory erc20s = main.assetRegistry().erc20s();
        for (uint256 i = 0; i < erc20s.length; i++) {
            manageERC20(erc20s[i]);
        }
    }

    /// - If we have any of `tokenToBuy` (RSR or RToken), distribute it.
    /// - If we have any of any other asset, start an trade to sell it for `assetToBuy`
    function manageERC20(IERC20 erc20) internal {
        IAssetRegistry reg = main.assetRegistry();

        assert(reg.isRegistered(erc20));

        uint256 bal = erc20.balanceOf(address(this));
        if (bal == 0) return;

        if (erc20 == tokenToBuy) {
            erc20.approve(address(main.distributor()), bal);
            main.distributor().distribute(erc20, address(this), bal);
            return;
        }

        // Don't open a second trade if there's already one running.
        for (uint256 i = tradesStart; i < trades.length; i++) {
            if (trades[i].sell() == erc20) return;
        }

        // If not dust, trade the non-target asset for the target asset
        (bool launch, TradeRequest memory trade) = prepareTradeSell(
            reg.toAsset(erc20),
            reg.toAsset(tokenToBuy),
            reg.toAsset(erc20).bal(address(this))
        );

        if (launch) tryTradeWithBroker(trade);
    }
}
