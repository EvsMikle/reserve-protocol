// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "contracts/p0/libraries/Basket.sol";
import "./IAsset.sol";
import "./IClaimAdapter.sol";
import "./IFurnace.sol";
import "./IMarket.sol";
import "./IRToken.sol";
import "./IStRSR.sol";
import "./ITrader.sol";

/// Configuration of the system
struct Config {
    // Time (seconds)
    uint256 rewardStart; // the timestamp of the very first weekly reward handout
    uint256 rewardPeriod; // the duration of time between reward events
    uint256 auctionPeriod; // the length of an auction
    uint256 stRSRWithdrawalDelay; // the "thawing time" of staked RSR before withdrawal
    uint256 defaultDelay; // how long to wait until switching vaults after detecting default
    // Ratios
    Fix maxTradeSlippage; // max slippage acceptable in a trade
    Fix dustAmount; // value below which we don't bother handling some tokens {UoA}
    Fix maxAuctionSize; // max size of an auction / (RToken supply)
    Fix issuanceRate; // number of RToken to issue per block / (RToken supply)
    Fix defaultThreshold; // multiplier beyond which a token is marked as in-default

    // Sample values
    //
    // rewardStart = timestamp of first weekly handout
    // rewardPeriod = 604800 (1 week)
    // auctionPeriod = 1800 (30 minutes)
    // stRSRWithdrawalDelay = 1209600 (2 weeks)
    // defaultDelay = 86400 (24 hours)

    // maxTradeSlippage = 0.01 (1%)
    // dustAmount = 1 (1 USD)
    // auctionClearingTolerance = 0.1 (10%)
    // maxAuctionSize = 0.01 (1%)
    // issuanceRate = 0.00025 (0.025% per block, or ~0.1% per minute)
    // defaultThreshold = 0.05 (5% deviation, either above or below)
}

struct RevenueShare {
    uint16 rTokenDist;
    uint16 rsrDist;
}

struct ConstructorArgs {
    Config config;
    RevenueShare dist;
    IFurnace furnace;
    IMarket market;
    IClaimAdapter[] claimAdapters;
}

enum AuctionStatus {
    NOT_YET_OPEN,
    OPEN,
    DONE
}

struct Auction {
    IAsset sell;
    IAsset buy;
    uint256 sellAmount; // {qSellTok}
    uint256 minBuyAmount; // {qBuyTok}
    uint256 startTime; // {sec}
    uint256 endTime; // {sec}
    uint256 clearingSellAmount; // only defined if status == DONE
    uint256 clearingBuyAmount; // only defined if status == DONE
    uint256 externalAuctionId; // only defined if status > NOT_YET_OPEN
    AuctionStatus status;
}

interface IMixin {
    event Initialized();
    event Poked();

    function init(ConstructorArgs calldata args) external;

    function poke() external;
}

interface IPausable {
    /// Emitted when the paused status is set
    /// @param oldPaused The old value of the paused state
    /// @param newPaused The new value of the paused state
    event PausedSet(bool oldPaused, bool newPaused);

    /// Emitted when the pauser address is set
    /// @param oldPauser The address of the old pauser
    /// @param newPauser The address of the new pauser
    event PauserSet(address oldPauser, address newPauser);

    function pause() external;

    function unpause() external;

    function paused() external returns (bool);

    function pauser() external view returns (address);

    function setPauser(address pauser_) external;
}

interface IAssetRegistry {
    /// Emitted when an asset is added to the registry
    /// @param asset The asset contract added to the registry
    event AssetAdded(IAsset indexed asset);

    /// Emitted when an asset is removed from the registry
    /// @param asset The asset contract removed from the registry
    event AssetRemoved(IAsset indexed asset);

    event AssetActivated(IAsset indexed asset);
    event AssetDeactivated(IAsset indexed asset);

    function addAsset(IAsset asset) external returns (bool);

    function removeAsset(IAsset asset) external returns (bool);

    /// Activate `asset`; fails if its erc20 is not in the current basket
    function activateAsset(IAsset asset) external returns (bool);

    /// Deactive `asset`; fails if its erc20 is not in the current basket
    function deactivateAsset(IAsset asset) external returns (bool);

    /// Return an array of all assets
    function allAssets() external view returns (IAsset[] memory);

    /// Return an array of all active assets
    function activeAssets() external view returns (IAsset[] memory);

    /// Return the active asset modelling the erc20 `token`.
    function activeAsset(address token) external view returns (IAsset);
}

interface IRevenueDistributor {
    /// Emitted when a distribution is set
    /// @param dest The address set to receive the distribution
    /// @param rTokenDist The distribution of RToken that should go to `dest`
    /// @param rsrDist The distribution of RSR that should go to `dest`
    event DistributionSet(address dest, uint16 rTokenDist, uint16 rsrDist);

    function setDistribution(address dest, RevenueShare memory share) external;

    function distribute(
        IERC20 erc20,
        address from,
        uint256 amount
    ) external;

    function rsrCut() external view returns (uint256 rsrShares, uint256 totalShares);

    function rTokenCut() external view returns (uint256 rtokenShares, uint256 totalShares);
}

interface ISettingsHandler {
    event RewardStartSet(uint256 indexed oldVal, uint256 indexed newVal);
    event RewardPeriodSet(uint256 indexed oldVal, uint256 indexed newVal);
    event AuctionPeriodSet(uint256 indexed oldVal, uint256 indexed newVal);
    event StRSRWithdrawalDelaySet(uint256 indexed oldVal, uint256 indexed newVal);
    event DefaultDelaySet(uint256 indexed oldVal, uint256 indexed newVal);
    event MaxTradeSlippageSet(Fix indexed oldVal, Fix indexed newVal);
    event DustAmountSet(Fix indexed oldVal, Fix indexed newVal);
    event MaxAuctionSizeSet(Fix indexed oldVal, Fix indexed newVal);
    event IssuanceRateSet(Fix indexed oldVal, Fix indexed newVal);
    event DefaultThresholdSet(Fix indexed oldVal, Fix indexed newVal);
    event StRSRSet(IStRSR indexed oldVal, IStRSR indexed newVal);
    event RevenueFurnaceSet(IFurnace indexed oldVal, IFurnace indexed newVal);
    event RTokenAssetSet(IAsset indexed oldVal, IAsset indexed newVal);
    event RSRAssetSet(IAsset indexed oldVal, IAsset indexed newVal);
    event MarketSet(IMarket indexed oldVal, IMarket indexed newVal);

    function setRewardStart(uint256 rewardStart) external;

    function setRewardPeriod(uint256 rewardPeriod) external;

    function setAuctionPeriod(uint256 auctionPeriod) external;

    function setStRSRWithdrawalDelay(uint256 stRSRWithdrawalDelay) external;

    function setDefaultDelay(uint256 defaultDelay) external;

    function setMaxTradeSlippage(Fix maxTradeSlippage) external;

    function setDustAmount(Fix dustAMount) external;

    function setMaxAuctionSize(Fix maxAuctionSize) external;

    function setIssuanceRate(Fix issuanceRate) external;

    function setDefaultThreshold(Fix defaultThreshold) external;

    function setStRSR(IStRSR stRSR) external;

    function setRevenueFurnace(IFurnace furnace) external;

    function setRTokenAsset(IAsset rTokenAsset) external;

    function setRSRAsset(IAsset rsrAsset) external;

    function setMarket(IMarket market) external;

    //

    function rewardStart() external view returns (uint256);

    function rewardPeriod() external view returns (uint256);

    function auctionPeriod() external view returns (uint256);

    function stRSRWithdrawalDelay() external view returns (uint256);

    function defaultDelay() external view returns (uint256);

    function maxTradeSlippage() external view returns (Fix);

    function dustAmount() external view returns (Fix);

    function maxAuctionSize() external view returns (Fix);

    function issuanceRate() external view returns (Fix);

    function defaultThreshold() external view returns (Fix);

    function stRSR() external view returns (IStRSR);

    function revenueFurnace() external view returns (IFurnace);

    function rTokenAsset() external view returns (IAsset);

    function rsrAsset() external view returns (IAsset);

    function market() external view returns (IMarket);

    /// @return The RToken deployment
    function rToken() external view returns (IRToken);

    /// @return The RSR deployment
    function rsr() external view returns (IERC20Metadata);
}

interface IBasketHandler {
    /// Emitted when the current vault is changed
    /// @param collateral The list of collateral in the prime basket
    /// @param targetAmts {target/BU} The amounts of target per basket unit
    event PrimeBasketSet(ICollateral[] collateral, Fix[] targetAmts);

    /// Emitted when a backup config is set for a target unit
    /// @param targetName The name of the target unit as a bytes32
    /// @param maxCollateral The max number to use from `collateral`
    /// @param collateral The set of permissible collateral to use
    event BackupConfigSet(
        bytes32 indexed targetName,
        uint256 indexed maxCollateral,
        ICollateral[] collateral
    );

    /// Emitted when the current vault is changed
    /// @param collateral The list of collateral in the basket
    /// @param refAmts {ref/BU} The reference amounts of the basket
    event BasketSet(ICollateral[] collateral, Fix[] refAmts);

    /// Set the prime basket in the basket configuration.
    /// @param collateral The collateral for the new prime basket
    /// @param targetAmts The target amounts (in) {target/BU} for the new prime basket
    function setPrimeBasket(ICollateral[] memory collateral, Fix[] memory targetAmts) external;

    /// Set the backup configuration for target unit `targetName`
    /// @param maxCollateral The maximum number of backup tokens to use at once for `targetName`
    /// @param collateral The preference-ordered list of collateral to consider backup tokens
    function setBackupConfig(
        bytes32 targetName,
        uint256 maxCollateral,
        ICollateral[] memory collateral
    ) external;

    function switchBasket() external returns (bool);

    function fullyCapitalized() external view returns (bool);

    function worstCollateralStatus() external view returns (CollateralStatus status);

    function blockBasketLastChanged() external view returns (uint256);

    /// @return p {UoA} An estimate at the total value of all assets held, in the unit of account
    function totalAssetValue() external view returns (Fix p);
}

// solhint-disable-next-line no-empty-blocks
interface IAuctioneer is ITraderEvents {

}

interface IRewardClaimer {
    /// Emitted whenever a claim adapter is added by governance
    event ClaimAdapterAdded(IClaimAdapter indexed adapter);
    /// Emitted whenever a claim adapter is removed by governance
    event ClaimAdapterRemoved(IClaimAdapter indexed adapter);
    /// Emitted whenever rewards are claimed
    event RewardsClaimed(address indexed erc20, uint256 indexed amount);

    function addClaimAdapter(IClaimAdapter claimAdapter) external;

    function removeClaimAdapter(IClaimAdapter claimAdapter) external;

    function isTrustedClaimAdapter(IClaimAdapter claimAdapter_) external view returns (bool);

    function claimAdapters() external view returns (IClaimAdapter[] memory adapters);

    function nextRewards() external view returns (uint256);
}

interface IRTokenIssuer {
    /// Emitted when an issuance of RToken begins
    /// @param issuer The address of the account redeeeming RTokens
    /// @param amount The quantity of RToken being issued
    /// @param baskets The corresponding number of baskets
    event IssuanceStarted(address indexed issuer, uint256 indexed amount, Fix indexed baskets);

    /// Emitted when a redemption of RToken occurs
    /// @param redeemer The address of the account redeeeming RTokens
    /// @param amount The quantity of RToken being redeemed
    /// @param baskets The corresponding number of baskets
    event Redemption(address indexed redeemer, uint256 indexed amount, Fix indexed baskets);

    function issue(uint256 amount) external returns (uint256[] memory deposits);

    function redeem(uint256 amount) external returns (uint256[] memory compensation);

    function basketCollateral() external view returns (ICollateral[] memory);

    function maxIssuable(address account) external view returns (uint256);

    // {UoA/rTok}
    function rTokenPrice() external view returns (Fix p);
}

/**
 * @title IMain
 * @notice The central coordinator for the entire system, as well as the external interface.
 * @dev The p0-specific IMain
 */
interface IMain is
    IPausable,
    IMixin,
    IAssetRegistry,
    ISettingsHandler,
    IRevenueDistributor,
    IBasketHandler,
    IAuctioneer,
    IRewardClaimer,
    IRTokenIssuer
{
    function owner() external view returns (address);
}
