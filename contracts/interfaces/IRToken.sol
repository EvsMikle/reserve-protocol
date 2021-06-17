pragma solidity 0.8.4;

import "../zeppelin/token/ERC20/IERC20.sol";

interface IRToken is IERC20 {

    /// Configuration changes, only callable by Owner.
    function changeConfiguration(address newConf) external;

    /// Adaptation function, callable by anyone
    function act() external;

    /// Handles issuance.
    /// Requires approvals to be in place beforehand.
    function issue(uint256 amount) external;

    /// Handles redemption.
    function redeem(uint256 amount) external;

    /// Global Settlement, callable by anyone
    function kill() external; 

    /// =========================== Views =================================

    /// Returns index of least collateralized token, or -1 if fully collateralized.
    function leastCollateralized() external view returns (int32);

    /// Returns the index of the most collateralized token, or -1.
    function mostCollateralized() external view returns (int32);

    /// Returns the amounts of collateral tokens required to issue `amount` quantity
    function issueAmounts(uint256 amount) external view returns (uint256[] memory);

    /// Returns the amounts of collateral tokens to be paid during a redemption
    function redemptionAmounts(uint256 amount) external view returns (uint256[] memory);


    event ConfigurationChanged(address indexed oldConfiguration, address indexed newConfiguration);
    event TradingFrozen(address indexed account);
    event TradingUnfrozen(address indexed account);

}
