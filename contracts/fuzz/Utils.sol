// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "contracts/libraries/Fixed.sol";
import "contracts/plugins/mocks/ERC20Mock.sol";
import "contracts/plugins/mocks/GnosisMock.sol";
import "contracts/plugins/mocks/ComptrollerMock.sol";
import "contracts/plugins/mocks/AaveLendingPoolMock.sol";
import "contracts/plugins/mocks/AaveLendingAddrProviderMock.sol";
import "contracts/p0/aux/Deployer.sol";

function defaultParams() external pure returns (DeploymentParams memory params) {
    params = DeploymentParams({
        maxAuctionSize: toFix(1e6),
        dist: RevenueShare({ rTokenDist: 2, rsrDist: 3 }),
        rewardPeriod: 604800, // 1 week
        rewardRatio: FixLib.divu(toFix(22840), (1_000_000)), // approx. half life of 30 pay periods
        unstakingDelay: 1209600, // 2 weeks
        tradingDelay: 0, // (the delay _after_ default has been confirmed)
        auctionLength: 1800, // 30 minutes
        backingBuffer: FixLib.divu(toFix(1), 10000), // 0.01%, 1 BIP
        maxTradeSlippage: FixLib.divu(toFix(1), 100), // 1%
        dustAmount: FixLib.divu(toFix(1), 100), // 0.01 UoA (USD)
        issuanceRate: FixLib.divu(toFix(25), 1_000_000) // 0.025% per block or ~0.1% per minute
    });
}

function defaultCtorArgs(DeploymentParams memory params)
    external
    pure
    returns (ConstructorArgs memory args)
{
    // consider: are these sane defaults?
    // Init to zero values:
    Components memory components;
    IAsset[] memory assets;
    args = ConstructorArgs({
        params: params,
        components: components,
        rsr: IERC20(address(0)),
        gnosis: IGnosis(address(0)),
        assets: assets
    });
}
