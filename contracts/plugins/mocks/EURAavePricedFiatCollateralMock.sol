// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "contracts/plugins/assets/abstract/AaveOracleMixin.sol";
import "contracts/plugins/assets/abstract/Collateral.sol";

contract EURAavePricedFiatCollateral is AaveOracleMixin, Collateral {
    constructor(
        IERC20Metadata erc20_,
        uint192 maxTradeVolume_,
        uint192 defaultThreshold_,
        uint256 delayUntilDefault_,
        IComptroller comptroller_,
        IAaveLendingPool aaveLendingPool_
    )
        Collateral(
            erc20_,
            maxTradeVolume_,
            defaultThreshold_,
            delayUntilDefault_,
            erc20_,
            bytes32(bytes("EUR"))
        )
        AaveOracleMixin(comptroller_, aaveLendingPool_)
    {}

    /// @return {UoA/tok} Our best guess at the market price of 1 whole token in UoA
    function price() public view virtual returns (uint192) {
        return consultOracle(address(erc20));
    }
}
