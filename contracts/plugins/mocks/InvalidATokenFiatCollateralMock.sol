// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "contracts/plugins/assets/ATokenFiatCollateral.sol";

contract InvalidATokenFiatCollateralMock is ATokenFiatCollateral {
    constructor(CollateralConfig memory config) ATokenFiatCollateral(config) {}

    /// Reverting claimRewards function
    function claimRewards() external pure override {
        revert("claimRewards() error");
    }
}
