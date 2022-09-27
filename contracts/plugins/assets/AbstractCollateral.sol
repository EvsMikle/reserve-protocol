// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "contracts/interfaces/IAsset.sol";
import "./Asset.sol";
import "./OracleLib.sol";

/**
 * @title Collateral
 * Parent class for all collateral
 * @dev By default, expects all units to be equal: tok == ref == target == UoA
 * @dev But no user is likely to want that, and that's why this contract is abstract
 */
abstract contract Collateral is ICollateral, Asset {
    using OracleLib for AggregatorV3Interface;

    // Default Status:
    // whenDefault == NEVER: no risk of default (initial value)
    // whenDefault > block.timestamp: delayed default may occur as soon as block.timestamp.
    //                In this case, the asset may recover, reachiving whenDefault == NEVER.
    // whenDefault <= block.timestamp: default has already happened (permanently)
    uint256 internal constant NEVER = type(uint256).max;
    uint256 public whenDefault = NEVER;

    uint256 public immutable delayUntilDefault; // {s} e.g 86400

    // targetName: The canonical name of this collateral's target unit.
    bytes32 public immutable targetName;

    /// @param chainlinkFeed_ Feed units: {UoA/ref}
    /// @param maxTradeVolume_ {UoA} The max trade volume, in UoA
    /// @param oracleTimeout_ {s} The number of seconds until a oracle value becomes invalid
    /// @param delayUntilDefault_ {s} The number of seconds an oracle can mulfunction
    constructor(
        uint192 fallbackPrice_,
        AggregatorV3Interface chainlinkFeed_,
        IERC20Metadata erc20_,
        IERC20Metadata rewardERC20_,
        uint192 maxTradeVolume_,
        uint48 oracleTimeout_,
        bytes32 targetName_,
        uint256 delayUntilDefault_
    ) Asset(fallbackPrice_, chainlinkFeed_, erc20_, rewardERC20_, maxTradeVolume_, oracleTimeout_) {
        require(targetName_ != bytes32(0), "targetName missing");
        require(delayUntilDefault_ > 0, "delayUntilDefault zero");
        targetName = targetName_;
        delayUntilDefault = delayUntilDefault_;
    }

    // solhint-disable-next-line no-empty-blocks
    function refresh() external virtual {
        CollateralStatus oldStatus = status();
        try this.price() returns (uint192) {
            whenDefault = NEVER;
        } catch {
            whenDefault = Math.min(block.timestamp + delayUntilDefault, whenDefault);
        }

        CollateralStatus newStatus = status();
        if (oldStatus != newStatus) {
            emit DefaultStatusChanged(oldStatus, newStatus);
        }
    }

    /// @return The collateral's status
    function status() public view virtual override returns (CollateralStatus) {
        if (whenDefault == NEVER) {
            return CollateralStatus.SOUND;
        } else if (whenDefault > block.timestamp) {
            return CollateralStatus.IFFY;
        } else {
            return CollateralStatus.DISABLED;
        }
    }

    /// @return If the asset is an instance of ICollateral or not
    function isCollateral() external pure virtual override(Asset, IAsset) returns (bool) {
        return true;
    }

    /// @return {ref/tok} Quantity of whole reference units per whole collateral tokens
    function refPerTok() public view virtual returns (uint192) {
        return FIX_ONE;
    }

    /// @return {target/ref} Quantity of whole target units per whole reference unit in the peg
    function targetPerRef() public view virtual returns (uint192) {
        return FIX_ONE;
    }

    /// @return {UoA/target} The price of a target unit in UoA
    function pricePerTarget() public view virtual returns (uint192) {
        return FIX_ONE;
    }
}
