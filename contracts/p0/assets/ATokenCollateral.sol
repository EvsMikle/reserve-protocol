// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "contracts/p0/interfaces/IMain.sol";
import "contracts/libraries/Fixed.sol";
import "contracts/p0/Collateral.sol";

// Interfaces to contracts from: https://git.io/JX7iJ
interface IStaticAToken is IERC20Metadata {
    function claimRewardsToSelf(bool forceUpdate) external;

    // @return RAY{fiatTok/tok}
    function rate() external view returns (uint256);

    // solhint-disable-next-line func-name-mixedcase
    function ATOKEN() external view returns (AToken);

    function getClaimableRewards(address user) external view returns (uint256);
}

interface AToken {
    // solhint-disable-next-line func-name-mixedcase
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}

/// @dev In Aave the number of decimals of the staticAToken is always 18, but the
/// underlying rebasing AToken will have the same number of decimals as its fiatcoin.
contract ATokenCollateralP0 is CollateralP0 {
    using FixLib for Fix;
    using SafeERC20 for IERC20Metadata;

    Fix public prevRateToUnderlying; // previous rate to underlying, in normal 1:1 units

    IERC20Metadata public immutable underlyingERC20; // this should be the underlying fiatcoin

    constructor(
        IERC20Metadata erc20_,
        IMain main_,
        IOracle oracle_,
        bytes32 role_,
        Fix govScore_,
        Fix oldPrice_,
        IERC20Metadata underlyingERC20_
    ) CollateralP0(erc20_, main_, oracle_, role_, govScore_, oldPrice_) {
        underlyingERC20 = underlyingERC20_;
    }

    /// Update default status
    function forceUpdates() public virtual override {
        if (whenDefault <= block.timestamp) {
            return;
        }

        // Check invariants
        Fix rate = rateToUnderlying();
        if (rate.lt(prevRateToUnderlying)) {
            whenDefault = block.timestamp;
        } else {
            // If the underlying is showing signs of depegging, default eventually
            whenDefault = _isUnderlyingDepegged()
                ? Math.min(whenDefault, block.timestamp + main.defaultDelay())
                : NEVER;
        }
        prevRateToUnderlying = rate;
    }

    /// @dev Intended to be used via delegatecall
    function claimAndSweepRewards(ICollateral collateral, IMain main_) external virtual override {
        // TODO: We need to ensure that calling this function directly,
        // without delegatecall, does not allow anyone to extract value.
        // This should already be the case because the Collateral
        // contract itself should never earn rewards.

        IStaticAToken aToken = IStaticAToken(address(collateral.erc20()));
        uint256 amount = aToken.getClaimableRewards(address(this));
        if (amount > 0) {
            aToken.claimRewardsToSelf(true);
            main_.aaveAsset().erc20().safeTransfer(address(main_), amount);
        }
    }

    /// @return {attoUSD/qTok} The price of 1 qToken in attoUSD
    function price() public view virtual override returns (Fix) {
        // {attoUSD/qTok} = {attoUSD/ref} * {ref/tok} / {qTok/tok}
        return oracle.consult(underlyingERC20).mul(rateToUnderlying()).shiftLeft(18);
    }

    /// @return {qRef/qTok} The price of the asset in a (potentially non-USD) reference asset
    function referencePrice() public view virtual override returns (Fix) {
        // {qRef/qTok} = {ref/tok} * {qRef/ref} / {qTok/tok}
        return rateToUnderlying().shiftLeft(int8(underlyingERC20.decimals()) - 18);
    }

    /// @return {underlyingTok/tok} The rate between the token and fiatcoin
    function rateToUnderlying() public view virtual returns (Fix) {
        uint256 rateInRAYs = IStaticAToken(address(erc20)).rate(); // {ray underlyingTok/tok}
        return toFixWithShift(rateInRAYs, -27);
    }

    function _isUnderlyingDepegged() internal view virtual returns (bool) {
        // {attoUSD/qRef} = {USD/ref} * {attoUSD/USD} / {qRef/ref}
        Fix delta = main.defaultThreshold().mul(PEG).shiftLeft(
            18 - int8(underlyingERC20.decimals())
        );

        // {attoUSD/qRef} = {attoUSD/ref} / {qRef/ref}
        Fix p = oracle.consult(underlyingERC20).shiftLeft(-int8(underlyingERC20.decimals()));
        return p.lt(PEG.minus(delta)) || p.gt(PEG.plus(delta));
    }
}
