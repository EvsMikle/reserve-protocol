// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*
 * @title IStRSR
 * @notice A rebasing token that represents claims on staked RSR and entitles the AssetManager to seize RSR.
 */
interface IStRSR is IERC20 {
    /// @notice Emitted when RSR is staked
    /// @param staker The address of the staker
    /// @param amount The quantity of RSR staked
    event Staked(address indexed staker, uint256 indexed amount);
    /// @notice Emitted when an unstaking is started
    /// @param withdrawalId The id of the withdrawal, globally unique
    /// @param staker The address of the unstaker
    /// @param amount The quantity of RSR being unstaked
    /// @param availableAt The timestamp at which the staking is eligible to be completed
    event UnstakingStarted(
        uint256 indexed withdrawalId,
        address indexed staker,
        uint256 indexed amount,
        uint256 availableAt
    );
    /// @notice Emitted when RSR is unstaked
    /// @param withdrawalId The id of the withdrawal, globally unique
    /// @param staker The address of the unstaker
    /// @param amount The quantity of RSR unstaked
    event UnstakingCompleted(uint256 indexed withdrawalId, address indexed staker, uint256 indexed amount);
    /// @notice Emitted when dividend RSR is added to the pool
    /// @param from The address that sent the dividend RSR
    /// @param amount The quantity of RSR added
    event RSRAdded(address indexed from, uint256 indexed amount);
    /// @notice Emitted when insurance RSR is seized from the pool
    /// @param from The address that seized the staked RSR (should only be the AssetManager)
    /// @param amount The quantity of RSR seized
    event RSRSeized(address indexed from, uint256 indexed amount);

    //

    /// @notice Stakes an RSR `amount` on the corresponding RToken to earn yield and insure the system
    /// @param amount {qRSR}
    function stake(uint256 amount) external;

    /// @notice Begins a delayed unstaking for `amount` stRSR
    /// @param amount {qRSR}
    function unstake(uint256 amount) external;

    /// @param amount {qRSR}
    function addRSR(uint256 amount) external;

    /// @notice AssetManager only
    /// @param amount {qRSR}
    function seizeRSR(uint256 amount) external;
}
