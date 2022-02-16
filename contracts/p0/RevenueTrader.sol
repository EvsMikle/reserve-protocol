// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "contracts/p0/interfaces/IERC20Receiver.sol";
import "contracts/p0/interfaces/IMain.sol";
import "contracts/p0/Trader.sol";

/// The RevenueTrader converts all asset balances at its address to a single target asset
/// and sends this asset to the RevenueDistributor at Main.
contract RevenueTraderP0 is TraderP0, IRewardClaimerEvents {
    using SafeERC20 for IERC20Metadata;

    IAsset public immutable assetToBuy;

    constructor(address main_, IAsset assetToBuy_) TraderP0() {
        initTrader(main_);
        assetToBuy = assetToBuy_;
    }

    /// Close any open auctions and start new ones, for all assets
    function doAuctions() external {
        IAsset[] memory assets = main.activeAssets(); // includes RToken/RSR/COMP/AAVE
        for (uint256 i = 0; i < assets.length; i++) {
            processAsset(assets[i]);
        }
    }

    /// - If we have any of `assetToBuy` (RSR or RToken), distribute it.
    /// - If we have any of any other asset, start an auction to sell it for `assetToBuy`
    function processAsset(IAsset asset) public {
        closeDueAuctions();

        IERC20Metadata erc20 = asset.erc20();
        uint256 bal = erc20.balanceOf(address(this));
        if (bal == 0) return;

        if (asset == assetToBuy) {
            erc20.safeApprove(address(main), bal);
            main.distribute(erc20, address(this), bal);
            return;
        }

        // Don't open a second auction if there's already one running.
        for (uint256 i = 0; i < auctions.length; i++) {
            if (auctions[i].sell == asset && auctions[i].status != AuctionStatus.DONE) return;
        }

        // If not dust, trade the non-target asset for the target asset
        // {tok} =  {qTok} / {qTok/tok}
        Fix sellAmount = toFixWithShift(bal, -int8(erc20.decimals()));
        (bool launch, Auction memory auction) = prepareAuctionSell(asset, assetToBuy, sellAmount);
        if (launch) launchAuction(auction);
    }

    /// Claims and sweeps all rewards
    function claimAndSweepRewardsToMain() external {
        (address[] memory erc20s, uint256[] memory amts) = RewardsLib.claimRewards(address(main));
        for (uint256 i = 0; i < erc20s.length; i++) {
            if (amts[i] > 0) {
                IERC20Metadata(erc20s[i]).safeTransfer(address(main), amts[i]);
            }
            emit RewardsClaimed(erc20s[i], amts[i]);
        }
    }
}
