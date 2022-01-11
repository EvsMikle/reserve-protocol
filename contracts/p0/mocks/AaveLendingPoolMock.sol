// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "contracts/p0/interfaces/IOracle.sol";

contract AaveLendingPoolMockP0 is IAaveLendingPool {
    ILendingPoolAddressesProvider private _lendingAddressesProvider;

    constructor(address lendingAddressesProvider) {
        _lendingAddressesProvider = ILendingPoolAddressesProvider(lendingAddressesProvider);
    }

    function getAddressesProvider() external view override returns (ILendingPoolAddressesProvider) {
        return _lendingAddressesProvider;
    }
}
