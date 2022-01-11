// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "contracts/p0/interfaces/IOracle.sol";
import "contracts/libraries/Fixed.sol";
import "./IMain.sol";

/**
 * @title IAsset
 * @notice Supertype. Any token that interacts with our system must be wrapped in an asset,
 * whether it is used as RToken backing, or not.
 */
interface IAsset {
    /// Unit of Account
    /// @return The Unit of Account for the asset
    function uoa() external view returns (UoA);

    /// @return The oracle that should be used with the asset
    function oracle() external view returns (IOracle);

    /// @return {attoUSD/qTok} The atto price of 1 qToken in the unit of account
    function price() external view returns (Fix);

    /// @return The ERC20 contract of the token with decimals() available
    function erc20() external view returns (IERC20Metadata);

    /// @return If the asset is an instance of ICollateral or not
    function isCollateral() external view returns (bool);
}

enum CollateralStatus {
    SOUND,
    IFFY,
    DISABLED
}

/**
 * @title ICollateral
 * @notice A subtype of Asset that consists of the tokens eligible to back the RToken.
 * There are two types of collateral, derivative and non-derivative.
 *   - Derivative collateral has underlying collateral (like a non-leaf node in a linked list)
 *   - Non-derivative collateral is itself a direct representation of a UoA (Unit of Account)
 * Note: This structure can be used to capture N-levels-nested asset structures.
 */
interface ICollateral is IAsset {
    /// Force any updates such as updating the default status or poking the defi protocol.
    /// Block-idempotent.
    function forceUpdates() external;

    /// Disable the collateral so it cannot be used as backing
    function disable() external;

    /// @return The status of this collateral asset. (Is it defaulting? Might it soon?)
    function status() external view returns (CollateralStatus);

    /// @return {attoUSD/tok} The atto price of 1 whole fiatcoin in its own unit of account
    function fiatcoinPrice() external view returns (Fix);

    /// @return {underlyingTok/tok} The rate between the token and fiatcoin
    function fiatcoinRate() external view returns (Fix);

    /// @return The ERC20 contract of the (maybe underlying) fiatcoin
    function underlyingERC20() external view returns (IERC20Metadata);
}
