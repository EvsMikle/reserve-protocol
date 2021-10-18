// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.4;

import "./collateral/Collateral.sol";

// contract PriceOracle {
//     mapping(address => uint) prices;

//     function getUnderlyingPrice(CToken cToken) public view returns (uint) {
//         if (compareStrings(cToken.symbol(), "cETH")) {
//             return 1e18;
//         } else {
//             return prices[address(CErc20(address(cToken)).underlying())];
//         }
//     }

//     function setUnderlyingPrice(CToken cToken, uint underlyingPriceMantissa) public {
//         address asset = address(CErc20(address(cToken)).underlying());
//         emit PricePosted(asset, prices[asset], underlyingPriceMantissa, underlyingPriceMantissa);
//         prices[asset] = underlyingPriceMantissa;
//     }

//     function setDirectPrice(address asset, uint price) public {
//         emit PricePosted(asset, prices[asset], price, price);
//         prices[asset] = price;
//     }

//     // v1 price oracle interface for use as backing of proxy
//     function assetPrices(address asset) external view returns (uint) {
//         return prices[asset];
//     }

//     function compareStrings(string memory a, string memory b) internal pure returns (bool) {
//         return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
//     }
// }
