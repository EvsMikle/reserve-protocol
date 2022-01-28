// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "contracts/p0/interfaces/IERC20Receiver.sol";
import "contracts/libraries/Fixed.sol";

/**
 * @title IFurnace
 * @notice A helper contract to burn RTokens slowly and permisionlessly.
 */
interface IFurnace is IERC20Receiver {
    /// @param amount {qRTok} The amount burnt
    event Burnt(uint256 indexed amount);

    /// @param amount {qRTok} The total amount to be burnt over the period
    /// @param timePeriod {sec} The number of seconds the burn occurs over
    /// @param who The account that created the distribution
    event DistributionCreated(uint256 indexed amount, uint256 indexed timePeriod, address who);

    //

    /// Performs any RToken burning that has vested since last call. Idempotent
    function doBurn() external;

    function setBatchDuration(uint256 batchDuration) external;

    function batchDuration() external view returns (uint256);
}
