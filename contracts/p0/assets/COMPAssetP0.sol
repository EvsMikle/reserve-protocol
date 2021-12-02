// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "contracts/p0/interfaces/IAsset.sol";
import "contracts/p0/interfaces/IMain.sol";
import "contracts/p0/libraries/Oracle.sol";
import "contracts/libraries/Fixed.sol";

contract COMPAssetP0 is IAsset {
    using FixLib for Fix;
    using Oracle for Oracle.Info;

    address internal immutable _erc20;

    constructor(address erc20_) {
        _erc20 = erc20_;
    }

    // @return {attoUSD/qCOMP}
    function priceUSD(Oracle.Info memory oracle) public view override returns (Fix) {
        return oracle.consult(Oracle.Source.COMPOUND, _erc20);
    }

    /// @return The ERC20 contract of the central token
    function erc20() public view virtual override returns (IERC20) {
        return IERC20(_erc20);
    }

    /// @return The number of decimals in the central token
    function decimals() public view override returns (uint8) {
        return IERC20Metadata(_erc20).decimals();
    }

    /// @return Whether `_erc20` is an AToken (StaticAToken, actually)
    function isAToken() public pure virtual override returns (bool) {
        return false;
    }
}
