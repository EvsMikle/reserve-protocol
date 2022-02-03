// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import "contracts/p0/interfaces/IMain.sol";

/**
 * @title IRToken
 * @notice An ERC20 with an elastic supply.
 * @dev The p0-specific IRToken
 */
interface IRToken is IERC20Metadata, IERC20Permit {
    /// Tracks data for a SlowIssuance
    /// @param blockStartedAt {blockNumber} The block number the issuance was started, non-fractional
    /// @param amount {qTok} The quantity of RToken the issuance is for
    /// @param erc20s The collateral token addresses corresponding to the deposit
    /// @param deposits {qTok} The collateral token quantities that paid for the issuance
    /// @param issuer The account issuing RToken
    /// @param blockAvailableAt {blockNumber} The block number when the issuance completes, fractional
    /// @param processed false when the issuance is still vesting
    struct SlowIssuance {
        uint256 blockStartedAt;
        uint256 amount; // {qRTok}
        address[] erc20s;
        uint256[] deposits; // {qTok}, same index as vault basket assets
        address issuer;
        Fix blockAvailableAt; // {blockNumber} fractional
        bool processed;
    }

    /// Emitted when issuance is started, at the point collateral is taken in
    /// @param issuanceId The index off the issuance, a globally unique identifier
    /// @param issuer The account performing the issuance
    /// @param amount The quantity of RToken being issued
    /// @param tokens The ERC20 contracts of the backing tokens
    /// @param quantities The quantities of tokens paid with
    /// @param blockAvailableAt The (continuous) block at which the issuance vests
    event IssuanceStarted(
        uint256 indexed issuanceId,
        address indexed issuer,
        uint256 indexed amount,
        address[] tokens,
        uint256[] quantities,
        Fix blockAvailableAt
    );

    /// Emitted when an RToken issuance is canceled, such as during a default
    /// @param issuanceId The index of the issuance, a globally unique identifier
    event IssuanceCanceled(uint256 indexed issuanceId);

    /// Emitted when an RToken issuance is completed successfully
    /// @param issuanceId The index of the issuance, a globally unique identifier
    event IssuanceCompleted(uint256 indexed issuanceId);

    /// Emitted when Main is set
    /// @param oldMain The old address of Main
    /// @param newMain The new address of Main
    event MainSet(IMain indexed oldMain, IMain indexed newMain);

    /// Begins the SlowIssuance accounting process
    /// @param issuer The account issuing the RToken
    /// @param amount {qRTok}
    /// @param deposits {qTok}
    function beginSlowIssuance(
        address issuer,
        uint256 amount,
        address[] memory erc20s,
        uint256[] memory deposits
    ) external;

    /// Mints a quantity of RToken to the `recipient`, only callable by AssetManager
    /// @param recipient The recipient of the newly minted RToken
    /// @param amount {qRTok} The amount to be minted
    /// @return true
    function mint(address recipient, uint256 amount) external returns (bool);

    /// Burns a quantity of RToken from the callers account
    /// @param from The account from which RToken should be burned
    /// @param amount {qRTok} The amount to be burned
    /// @return true
    function burn(address from, uint256 amount) external returns (bool);

    function poke() external;

    function setMain(IMain main) external;
}
