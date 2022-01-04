// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "contracts/p0/Deployer.sol";
import "contracts/p0/interfaces/IAsset.sol";
import "contracts/p0/interfaces/IMarket.sol";
import "contracts/p0/interfaces/IMain.sol";
import "contracts/p0/interfaces/IRToken.sol";
import "contracts/p0/interfaces/IStRSR.sol";
import "contracts/test/Mixins.sol";
import "./FurnaceExtension.sol";
import "./MainExtension.sol";
import "./RTokenExtension.sol";
import "./StRSRExtension.sol";

/// Inject wrapper contracts into Deployer
contract DeployerExtension is DeployerP0, IExtension {
    address internal _admin;
    IMain internal _main;

    constructor(
        address rsrAddr_,
        address compAddr_,
        address aaveAddr_,
        IMarket market_
    ) DeployerP0(rsrAddr_, compAddr_, aaveAddr_, market_) {
        _admin = msg.sender;
    }

    function assertInvariants() external override {
        INVARIANT_currentDeploymentRegistered();
    }

    function _deployMain(ConstructorArgs memory args) internal override returns (IMain) {
        _main = new MainExtension(_admin);
        _main.init(args);
        return _main;
    }

    function _deployRevenueFurnace(IRToken rToken, uint256 batchDuration)
        internal
        override
        returns (IFurnace)
    {
        return new FurnaceExtension(_admin, rToken, batchDuration);
    }

    function _deployRToken(string memory name, string memory symbol)
        internal
        override
        returns (IRToken)
    {
        return new RTokenExtension(_admin, name, symbol);
    }

    function _deployStRSR(
        IMain main,
        string memory name,
        string memory symbol
    ) internal override returns (IStRSR) {
        return new StRSRExtension(_admin, main, name, symbol);
    }

    function INVARIANT_currentDeploymentRegistered() internal view {
        bool found = false;
        for (uint256 i = 0; i < deployments.length; i++) {
            if (_main == deployments[i]) {
                found = true;
            }
        }
        assert(found);
    }
}
