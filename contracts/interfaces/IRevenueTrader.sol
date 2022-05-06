// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "./IComponent.sol";
import "./ITrading.sol";

/**
 * @title IRevenueTrader
 * @notice The RevenueTrader is an extension of the trading mixin that trades all
 *   assets at its address for a single target asset. There are two runtime instances
 *   of the RevenueTrader, 1 for RToken and 1 for RSR.
 */
interface IRevenueTrader is IComponent, ITrading {
    /// Emitted when maxPriceLatency is changed
    /// @param oldVal {s} The old maxPriceLatency
    /// @param newVal {s} The new maxPriceLatency
    event MaxPriceLatencySet(uint32 indexed oldVal, uint32 indexed newVal);

    // Initialization
    function init(
        IMain main_,
        IERC20 tokenToBuy_,
        int192 maxTradeSlippage_,
        int192 dustAmount_,
        uint32 maxPriceLatency_
    ) external;

    /// Processes a single token; unpermissioned
    /// @dev Intended to be used with multicall
    /// @custom:action
    function manageToken(IERC20 sell) external;
}

// solhint-disable-next-line no-empty-blocks
interface TestIRevenueTrader is IRevenueTrader, TestITrading {
    function setMaxPriceLatency(uint32 maxPriceLatency_) external;
}
