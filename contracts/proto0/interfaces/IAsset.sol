// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "contracts/proto0/interfaces/IMain.sol";
import "contracts/libraries/Fixed.sol";

/**
 * @title IAsset
 * @notice A handle for all tokens in our system, customized for DeFi USD derivatives.
 */
interface IAsset {
    /// @dev Call `updateRates()` before to ensure the latest rates
    function updateRates() external;

    /// @return {qFiatTok/qTok} Conversion rate between token and its fiatcoin. Incomparable across assets.
    function rateFiatcoin() external view returns (Fix);

    /// @return {USD/tok} Without using oracles, returns the expected USD value of one whole tok.
    function rateUSD() external view returns (Fix);

    /// @return The ERC20 contract of the central token
    function erc20() external view returns (IERC20);

    /// @return The number of decimals in the central token
    function decimals() external view returns (uint8);

    /// @return The number of decimals in the nested fiatcoin contract (or for the erc20 itself if it is a fiatcoin)
    function fiatcoinDecimals() external view returns (uint8);

    /// @return The fiatcoin underlying the ERC20, or the erc20 itself if it is a fiatcoin
    function fiatcoin() external view returns (address);

    /// @return {USD/qTok} The price in USD of the asset as a function of DeFi redemption rates + oracle data
    function priceUSD(IMain main) external view returns (Fix);

    /// @return {USD/qTok} The price in USD of the fiatcoin underlying the ERC20 (or the price of the ERC20 itself)
    function fiatcoinPriceUSD(IMain main) external view returns (Fix);

    /// @return Whether the asset is (directly) a fiatcoin
    function isFiatcoin() external view returns (bool);
}
