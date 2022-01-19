// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "contracts/p0/interfaces/IAsset.sol";
import "contracts/p0/interfaces/IMain.sol";
import "contracts/p0/interfaces/IOracle.sol";
import "contracts/libraries/Fixed.sol";
import "contracts/p0/Asset.sol";

contract RTokenAssetP0 is AssetP0 {
    using FixLib for Fix;

    // solhint-disable no-empty-blocks
    constructor(
        IERC20Metadata erc20_,
        IMain main_,
        IOracle oracle_
    ) AssetP0(erc20_, main_, oracle_) {}

    /// @return {attoUSD/qRTok}
    function price() public view override returns (Fix) {
        // TODO This looks right, but something is probably broken elsewhere because it's not
        // {attoUSD/qRTok} = {attoUSD/BU} * {BU/rTok} / {qRTok/rTok}
        return main.basketPrice().mul(main.baseFactor()).shiftLeft(-int8(erc20.decimals()));
    }
}
