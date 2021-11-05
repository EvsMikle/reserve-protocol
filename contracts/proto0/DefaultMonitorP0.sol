// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/utils/Context.sol";
import "contracts/proto0/interfaces/IAsset.sol";
import "contracts/proto0/interfaces/IDefaultMonitor.sol";
import "contracts/proto0/interfaces/IMain.sol";
import "contracts/proto0/MainP0.sol";
import "contracts/libraries/Fixed.sol";

/**
 * @title DefaultMonitorP0
 * @notice The default monitor checks for default states in other systems.
 */
contract DefaultMonitorP0 is Context, IDefaultMonitor {
    using FixLib for Fix;
    mapping(address => Fix) internal _ratesUSD; // {attoUSD/qtok}

    IMain public main;

    constructor(IMain main_) {
        main = main_;
    }

    /// Checks for hard default in a vault by inspecting the redemption rates of collateral tokens
    /// @param vault The vault to inspect
    function checkForHardDefault(IVault vault) external override returns (IAsset[] memory defaulting) {
        require(_msgSender() == address(main), "main only");
        IAsset[] memory vaultAssets = new IAsset[](vault.size());
        uint256 count;
        for (uint256 i = 0; i < vault.size(); i++) {
            IAsset a = vault.assetAt(i);
            if (a.rateUSD().lt(_ratesUSD[address(a)])) {
                vaultAssets[count] = a;
                count++;
            }
            _ratesUSD[address(a)] = a.rateUSD();
        }
        defaulting = new IAsset[](count);
        for (uint256 i = 0; i < count; i++) {
            defaulting[i] = vaultAssets[i];
        }
    }

    /// Checks for soft default in a vault by checking oracle values for all fiatcoins in the vault
    /// @param vault The vault to inspect
    /// @param fiatcoins An array of addresses of fiatcoin assets to use for median USD calculation
    function checkForSoftDefault(IVault vault, IAsset[] memory fiatcoins)
        public
        view
        override
        returns (IAsset[] memory defaulting)
    {
        Fix defaultThreshold = _defaultThreshold(fiatcoins); // {attoUSD/qTok}
        IAsset[] memory vaultAssets = new IAsset[](vault.size());
        uint256 count;
        for (uint256 i = 0; i < vaultAssets.length; i++) {
            IAsset a = vault.assetAt(i);

            if (a.fiatcoinPriceUSD(main).lt(defaultThreshold)) {
                vaultAssets[count] = a;
                count++;
            }
        }
        defaulting = new IAsset[](count);
        for (uint256 i = 0; i < count; i++) {
            defaulting[i] = vaultAssets[i];
        }
    }

    /// Returns a vault from the list of backup vaults that is not defaulting
    /// @param vault The vault that is currently defaulting
    /// @param approvedCollateral An array of addresses of all collateral assets eligible to be in the new vault
    /// @param fiatcoins An array of addresses of fiatcoin assets to use for median USD calculation
    function getNextVault(
        IVault vault,
        address[] memory approvedCollateral,
        address[] memory fiatcoins
    ) external override returns (IVault) {
        IAsset[] memory fiatcoinAssets = new IAsset[](fiatcoins.length);
        for (uint256 i = 0; i < fiatcoins.length; i++) {
            fiatcoinAssets[i] = IAsset(fiatcoins[i]);
        }

        Fix maxRate;
        uint256 indexMax = 0;
        IVault[] memory backups = vault.getBackups();

        // Loop through backups to find the highest value one that doesn't contain defaulting collateral
        for (uint256 i = 0; i < backups.length; i++) {
            if (
                backups[i].containsOnly(approvedCollateral) &&
                checkForSoftDefault(backups[i], fiatcoinAssets).length == 0
            ) {
                Fix rate = backups[i].basketRate(); // {USD}

                // See if it has the highest basket rate
                if (rate.gt(maxRate)) {
                    maxRate = rate;
                    indexMax = i;
                }
            }
        }

        if (maxRate.eq(FIX_ZERO)) {
            return IVault(address(0));
        }
        return backups[indexMax];
    }

    /// @return {attoUSD/qTok} The USD price at which a fiatcoin can be said to be defaulting
    function _defaultThreshold(IAsset[] memory fiatcoins) internal view returns (Fix) {
        // Collect prices
        Fix[] memory prices = new Fix[](fiatcoins.length);
        for (uint256 i = 0; i < fiatcoins.length; i++) {
            prices[i] = fiatcoins[i].fiatcoinPriceUSD(main); // {attoUSD/qTok}
        }

        // Sort
        for (uint256 i = 1; i < prices.length; i++) {
            Fix key = prices[i];
            uint256 j = i - 1;
            while (j >= 0 && prices[j].gt(key)) {
                prices[j + 1] = prices[j];
                j--;
            }
            prices[j + 1] = key;
        }

        // Take the median
        Fix median;
        if (prices.length % 2 == 0) {
            median = prices[prices.length / 2 - 1].plus(prices[prices.length / 2]).divu(2);
        } else {
            median = prices[prices.length / 2];
        }

        // median - (median * defaultThreshold)
        return median.minus(median.mul(main.config().defaultThreshold));
    }
}
