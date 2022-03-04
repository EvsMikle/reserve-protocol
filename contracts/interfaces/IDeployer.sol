// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "./IExplorerFacade.sol";
import "./IMain.sol";
import "./IRToken.sol";
import "./IStRSR.sol";
import "./IDistributor.sol";

struct DeploymentParams {
    // === RSR/RToken/AAVE/COMP ===
    Fix maxAuctionSize; // {UoA}
    //
    // === Revenue sharing ===
    RevenueShare dist; // revenue sharing splits between RToken and RSR
    //
    // === Rewards (Furnace + StRSR) ===
    uint256 rewardPeriod; // {s} the atomic unit of rewards, determines # of exponential rounds
    Fix rewardRatio; // the fraction of available revenues that stRSR holders get each PayPeriod
    //
    // === StRSR ===
    uint256 unstakingDelay; // {s} the "thawing time" of staked RSR before withdrawal
    //
    // === BackingManager ===
    uint256 auctionDelay; // {s} how long to wait until starting auctions after switching basket
    uint256 auctionLength; // {s} the length of an auction
    Fix backingBuffer; // {%} how much extra backing collateral to keep
    Fix maxTradeSlippage; // {%} max slippage acceptable in a trade
    Fix dustAmount; // {UoA} value below which we don't bother handling some tokens
    //
    // === RToken ===
    Fix issuanceRate; // {%} number of RToken to issue per block / (RToken value)
}

/**
 * @title IDeployer
 * @notice The deployer for the entire system.
 */
interface IDeployer {
    /// Emitted when a new RToken and accompanying system is deployed
    /// @param main The address of `Main`
    /// @param rToken The address of the RToken ERC20
    /// @param stRSR The address of the StRSR ERC20 staking pool/token
    /// @param facade The address of the view facade
    /// @param owner The owner of the newly deployed system
    event RTokenCreated(
        IMain indexed main,
        IRToken indexed rToken,
        IStRSR stRSR,
        IExplorerFacade facade,
        address indexed owner
    );

    //

    /// Deploys an instance of the entire system
    /// @param name The name of the RToken to deploy
    /// @param symbol The symbol of the RToken to deploy
    /// @param owner The address that should own the entire system, hopefully a governance contract
    /// @param params Deployment params
    /// @return The address of the newly deployed Main instance.
    function deploy(
        string calldata name,
        string calldata symbol,
        address owner,
        DeploymentParams memory params
    ) external returns (address);
}
