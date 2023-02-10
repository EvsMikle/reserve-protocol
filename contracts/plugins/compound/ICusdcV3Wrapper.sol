// SPDX-License-Identifier: ISC
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./vendor/CometInterface.sol";

interface ICusdcV3Wrapper is IERC20 {
    function deposit(uint256 amount) external;

    function depositTo(address account, uint256 amount) external;

    function depositFrom(
        address from,
        address dst,
        uint256 amount
    ) external;

    function withdraw(uint256 amount) external;

    function withdrawTo(address to, uint256 amount) external;

    function withdrawFrom(
        address src,
        address to,
        uint256 amount
    ) external;

    function claimTo(address src, address to) external;

    function accrue() external;

    function accrueAccount(address account) external;

    function underlyingBalanceOf(address account) external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function getRewardOwed(address account) external returns (uint256);

    function exchangeRate() external view returns (uint256);

    function convertStaticToDynamic(uint104 amount) external view returns (uint256);

    function convertDynamicToStatic(uint256 amount) external view returns (uint104);

    function baseTrackingAccrued(address account) external view returns (uint64);

    function baseTrackingIndex(address account) external view returns (uint64);

    function underlying() external view returns (address);

    function underlyingComet() external view returns (CometInterface);

    function decimals() external view returns (uint8);
}
