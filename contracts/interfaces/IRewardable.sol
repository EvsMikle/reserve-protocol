// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "./IComponent.sol";
import "./IMain.sol";

/**
 * @title IRewardable
 * @notice A simple component mixin to support claiming + monetization of COMP/AAVE rewards
 */
interface IRewardable is IComponent {
    /// Emitted whenever rewards are claimed
    event RewardsClaimed(address indexed erc20, uint256 indexed amount);

    /// Claim reward tokens from integrated defi protocols such as Compound/Aave
    function claimAndSweepRewards() external;
}
