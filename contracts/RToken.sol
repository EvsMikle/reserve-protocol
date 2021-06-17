pragma solidity 0.8.4;

import "../zeppelin/token/ERC20/utils/SafeERC20.sol";
import "../zeppelin/token/IERC20.sol";
import "../zeppelin/access/Ownable.sol";
import "../interfaces/IConfiguration.sol";
import "../interfaces/ITXFee.sol";
import "../interfaces/IRToken.sol";
import "../interfaces/IAtomicExchange.sol";
import "../interfaces/IInsurancePool.sol";
import "./SlowMintingERC20.sol";
import "./SimpleOrderbookExchange.sol";
    

/**
 * @title RToken
 * @dev An ERC-20 token with built-in rules for price stabilization centered around a basket. 
 * 
 * RTokens can:
 *    - scale up or down in supply (nearly) completely elastically
 *    - change their backing while maintaining price
 *    - and, recover from collateral defaults through insurance
 * 
 * Only the owner (which should be set to a TimelockController) can change the Configuration.
 */
contract RToken is IRToken, SlowMintingERC20, Ownable {
    using SafeERC20 for IERC20;

    /// Max Fee on transfers, ever. 
    uint256 public constant override MAX_FEE = 5e16; // 5%

    /// ==== Mutable State ====

    IConfiguration public override conf;

    /// since last
    uint128 private override lastTimestamp;
    uint128 private override lastBlock;

    /// Set to 0 address when not frozen
    address public override freezer;

    constructor(
        address calldata owner_,
        string calldata name_, 
        string calldata symbol_, 
        address calldata conf_,
    ) ERC20SlowMint(name_, symbol_, conf_) public {
        _owner = owner_;
    }

    modifier canTrade() {
        require(!tradingFrozen() , "tradingFrozen is frozen, but you can transfer or redeem");
        _;
    }

    modifier doPerBlockUpdates() {
        _perBlockUpdates();
        _;
    }


    /// =========================== Views =================================

    function tradingFrozen() public view returns (bool) {
        return freezer != address(0);
    }

    /// The returned array will be in the same order as the current basket.
    function issueAmounts(uint256 amount) public view returns (uint256[] memory) {
        uint256[] memory parts = new uint256[](conf.basket.length);

        for (uint32 i = 0; i < conf.basket.length; i++) {
            parts[i] = amount * conf.basket.tokens[i].quantity / 10**decimals();
            parts[i] = parts[i] * (conf.SCALE + conf.spread) / conf.SCALE;
        }

        return parts;
    }


    /// The returned array will be in the same order as the current basket.
    function redemptionAmounts(uint256 amount) public view returns (uint256[] memory) {
        uint256[] memory parts = new uint256[](conf.basket.length);

        bool fullyCollateralized = fullyCollateralized();
        for (uint32 i = 0; i < conf.basket.length; i++) {
            uint256 bal = IERC20(conf.basket.tokens[i].address).balanceOf(address(this));
            if (fullyCollateralized) {
                parts[i] = conf.basket.tokens[i].quantity * amount / 10**decimals();
            } else {
                parts[i] = bal * amount / _totalSupply;
            }
        }

        return parts;
    }

    /// Returns index of least collateralized token, or -1 if fully collateralized.
    function leastCollateralized() public pure view returns (int32) {
        uint256 largestDeficitNormed;
        int32 index = -1;

        for (uint32 i = 0; i < conf.basket.length; i++) {
            uint256 bal = IERC20(conf.basket.tokens[i].address).balanceOf(address(this));
            uint256 expected = _totalSupply * conf.basket.tokens[i].quantity / 10**decimals();

            if (bal < expected) {
                uint256 deficitNormed = (expected - bal) / conf.basket.tokens[i].quantity;
                if (deficitNormed > largestDeficit)Normed {
                    largestDeficitNormed = deficitNormed;
                    index = i;
                }
            }
        }
        return index;
    }

    /// Returns the index of the most collateralized token, or -1.
    function mostCollateralized() public pure view returns (int32) {
        uint256 largestSurplusNormed;
        int32 index = -1;

        for (uint32 i = 0; i < conf.basket.length; i++) {
            uint256 bal = IERC20(conf.basket.tokens[i].address).balanceOf(address(this));
            uint256 expected = _totalSupply * conf.basket.tokens[i].quantity / 10**decimals();
            expected += conf.basket.tokens[i].sellRatePerBlock;

            if (bal > expected) {
                uint256 surplusNormed = (bal - expected) / conf.basket.tokens[i].quantity;
                if (surplusNormed > largestSurplusNormed) {
                    largestSurplusNormed = surplusNormed;
                    index = i;
                }
            }
        }
        return index;
    }

    /// Can be used in conjuction with `transfer` methods to account for fees.
    function adjustedAmountForFee(address from, address to, uint256 amount) public pure view returns (uint256) {
        return ITXFee(conf.txFeeAddress).calculateAdjustedAmountToIncludeFee(from, to, amount);
    }

    /// =========================== External =================================


    /// Configuration changes, only callable by Owner.
    function changeConfiguration(address newConf) external override onlyOwner {
        emit ConfigurationChanged(address(conf), newConf);
        conf = IConfiguration(newConf);
    }

    /// Callable by anyone, runs all the perBlockUpdates
    function act() external override doPerBlockUpdates {
        return;
    }

    /// Handles issuance.
    /// Requires approvals to be in place beforehand.
    function issue(uint256 amount) external override doPerBlockUpdates {
        require(amount > 0, "cannot issue zero RToken");
        require(amount < conf.maxSupply, "at max supply");
        require(conf.basket.length > 0, "basket cannot be empty");
        require(!ICircuitBreaker(conf.circuitBreakerAddress).check(), "circuit breaker tripped");

        uint256[] memory amounts = issueAmounts(amount);
        for (uint32 i = 0; i < conf.basket.length; i++) {
            IERC20(conf.basket.tokens[i].address).safeTransferFrom(
                _msgSender(),
                address(this),
                amounts[i]
            );
        }

        _mint(_msgSender(), amount);
        emit Issuance(_msgSender(), amount);
    }

    /// Handles redemption.
    function redeem(uint256 amount) external override doPerBlockUpdates {
        require(amount > 0, "cannot redeem 0 RToken");
        require(conf.basket.length > 0, "basket cannot be empty");

        uint256[] memory amounts = redemptionAmounts(amount);
        _burn(_msgSender(), amount);
        for (uint32 i = 0; i < conf.basket.length; i++) {
            IERC20(conf.basket.tokens[i].address).safeTransfer(
                _msgSender(),
                amounts[i]
            );
        }

        emit Redemption(_msgSender(), amount);
    }

    /// Trading freeze
    function freeze() external override canTrade doPerBlockUpdates {
        IERC20(conf.rsrTokenAddress).safeTransferFrom(
            _msgSender(),
            address(this),
            conf.tradingFreezeCost
        );
        freezer = _msgSender();
        emit TradingFrozen(_msgSender());
    }

    /// Trading unfreeze
    function unfreeze() external override doPerBlockUpdates {
        require(tradingFrozen(), "already unfrozen");
        require(_msgSender() == freezer, "only freezer can unfreeze");
        IERC20(conf.rsrTokenAddress).safeTransfer(
            freezer,
            conf.tradingFreezeCost
        );
        freezer = address(0);
        emit TradingUnfrozen(_msgSender());
    }

    /// =========================== Internal =================================

    /// This (and everything in it) should be idempotent if run twice in the same block.
    function _perBlockUpdates() internal override {
        // update basket quantities based on blocknumber
        conf.basket.doPerBlockUpdates(); 

        // expand RToken supply
        _expandSupply(); 

        // trade out collateral for other collateral or insurance RSR
        _rebalance(); 
    }

    /// Expands the RToken supply and gives the new mintings to the protocol fund and 
    /// the insurance pool.
    function _expandSupply() internal override {
        // 31536000 = seconds in a year
        uint256 toExpand = _totalSupply * conf.supplyExpansionRate * (block.timestamp - lastTimestamp) / 31536000 / conf.SCALE;
        lastTimestamp = block.timestamp;
        if (toExpand == 0) {
            return;
        }

        // Mint to protocol fund
        if (conf.expenditureFactor > 0) {
            uint256 e = toExpand * min(conf.SCALE, expenditureFactor) / conf.SCALE;
            _mint(conf.protocolFundAddress, e);
        }

        // Mint to self
        if (conf.expenditureFactor < conf.SCALE) {
            uint256 p = toExpand * (conf.SCALE - conf.expenditureFactor) / conf.SCALE;
            _mint(address(this), p);
        }

        // Batch transfers from self to InsurancePool
        if (balanceOf(address(this)) > _totalSupply * conf.revenueBatchSizeScaled / conf.SCALE) {
            _approve(conf.insurancePoolAddress, balanceOf(address(this)));
            IInsurancePool(conf.insurancePoolAddress).notifyRevenue(balanceOf(address(this)));
        }
    }

    /// Trades tokens against the IAtomicExchange with per-block rate limiting
    function _rebalance() internal override {
        uint256 numBlocks = block.number - lastBlock;
        lastBlock = block.number;
        if (tradingFrozen() || numBlocks == 0) { 
            return; 
        }

        int32 indexLowest = leastCollateralized();
        int32 indexHighest = mostCollateralized();
        IAtomicExchange exchange = IAtomicExchange(conf.exchangeAddress);

        if (indexLowest >= 0 && indexHighest >= 0) {
            Basket.CollateralToken storage ctLow = conf.basket.tokens[indexLowest];
            Basket.CollateralToken storage ctHigh = conf.basket.tokens[indexHighest];
            uint256 sellAmount = min(numBlocks * ctHigh.sellRatePerBlock, IERC20(ctHigh.address).balanceOf(address(this)) - _totalSupply * ctHigh.quantity / 10**(decimals()));
            exchange.trade(ctHigh.address, ctLow.address, sellAmount);
        } else if (indexLowest >= 0) {
            Basket.CollateralToken storage ctLow = conf.basket.tokens[indexLowest];
            uint256 sellAmount = numBlocks * conf.rsrSellRate;
            uint256 seized = insurancePool.seizeRSR(sellAmount);
            IERC20(conf.rsrTokenAddress).safeApprove(conf.exchangeAddress, seized);
            exchange.trade(conf.rsrTokenAddress, ctLow.address, seized);
        } else if (indexHighest >= 0) {
            Basket.CollateralToken storage ctHigh = conf.basket.tokens[indexHighest];
            uint256 sellAmount = min(numBlocks * ctHigh.sellRatePerBlock, IERC20(ctHigh.address).balanceOf(address(this)) - _totalSupply * ctHigh.quantity / 10**(decimals()));
            IERC20(ctHigh.address).safeApprove(conf.exchangeAddress, sellAmount);
            exchange.trade(ctHigh.address, conf.rsrTokenAddress, sellAmount);
        }

    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be to transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * Implements an optional tx fee on transfers, capped.
     * The fee is _in addition_ to the transfer amount.
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (
            from != address(0) && 
            to != address(0) && 
            address(conf.txFeeAddress) != address(0)
        ) {
            fee = ITXFee(conf.txFeeAddress).calculateFee(sender, recipient, amount);
            fee = min(fee, amount * MAX_FEE / conf.SCALE);

            _balances[from] = _balances[from] - fee;
            _balances[conf.feeRecipient] += fee;
            emit Transfer(from, feeRecipient, fee);
        }
    }
}
