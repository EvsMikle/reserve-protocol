// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.4;

import "../Ownable.sol"; // temporary
// import "@openzeppelin/contracts/access/Ownable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./interfaces/IStakingPool.sol";
import "./interfaces/IRToken.sol";

/*
 * @title StakingPool
 * @dev The StakingPool is where people can stake their RSR in order to provide insurance and
 * benefit from the supply expansion of an RToken. System-0 version.
 *
 * There's an important assymetry in the StakingPool. When RSR is added, it must be split only
 * across non-withdrawing balances, while when RSR is seized, it must be seized from both
 * balances that are in the process of being withdrawn and those that are not.
 */
contract StakingPoolP0 is IStakingPool, IERC20, Ownable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    IRToken public rToken;
    IERC20 public override rsr;

    // Staking Token Name and Symbol
    string private _name;
    string private _symbol;

    // Amount of RSR staked per account
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // List of accounts
    EnumerableSet.AddressSet internal _accounts;

    // Total staked
    uint256 internal _totalSupply;

    // Delayed Withdrawals
    struct Withdrawal {
        address account;
        uint256 amount;
        uint256 availableAt;
    }

    Withdrawal[] public withdrawals;
    uint256 public withdrawalIndex;

    // Configuration
    uint256 public stakingWithdrawalDelay;

    constructor(
        string memory name_,
        string memory symbol_,
        address owner_,
        address rToken_,
        address rsr_,
        uint256 stakingWithdrawalDelay_
    ) {
        _name = name_;
        _symbol = symbol_;
        _transferOwnership(owner_);
        rToken = IRToken(rToken_);
        rsr = IERC20(rsr_);
        stakingWithdrawalDelay = stakingWithdrawalDelay_;
        rsr.safeApprove(rToken_, type(uint256).max);
    }

    // Stake RSR
    function stake(uint256 amount) external override {
        // Process pending withdrawals
        processWithdrawals();

        require(amount > 0, "Cannot stake zero");

        rsr.safeTransferFrom(_msgSender(), address(this), amount);
        _accounts.add(_msgSender());
        _balances[_msgSender()] += amount;
        _totalSupply += amount;
    }

    function unstake(uint256 amount) external override {
        // Process pending withdrawals
        processWithdrawals();

        require(amount > 0, "Cannot withdraw zero");
        require(_balances[_msgSender()] >= amount, "Not enough balance");

        // Take it out up front
        _balances[_msgSender()] -= amount;
        _totalSupply -= amount;

        // Submit delayed withdrawal
        withdrawals.push(Withdrawal(_msgSender(), amount, block.timestamp + stakingWithdrawalDelay));
    }

    function balanceOf(address account) external view override returns (uint256) {
        // Option A - ignore funds sent directly to contract
        return _balances[account];
    }

    function processWithdrawals() public {
        // Process all pending withdrawals
        for (uint256 index = withdrawalIndex; index < withdrawals.length; index++) {
            if (block.timestamp > withdrawals[withdrawalIndex].availableAt) {
                Withdrawal storage withdrawal = withdrawals[withdrawalIndex];

                if (withdrawal.amount > 0) {
                    rsr.safeTransfer(withdrawal.account, withdrawal.amount);
                }

                delete withdrawals[withdrawalIndex];
                withdrawalIndex += 1;
            } else {
                break;
            }
        }
    }

    // Adding RSR adds RSR only to current stakers (not withdrawers)
    function addRSR(uint256 amount) external override {
        require(amount > 0, "Amount cannot be zero");

        // Process pending withdrawals
        processWithdrawals();

        rsr.safeTransferFrom(address(rToken), address(this), amount);

        uint256 snapshotTotalStaked = _totalSupply;
        _totalSupply += amount;

        // Redistribute RSR to stakers, but not to withdrawers
        if (snapshotTotalStaked > 0) {
            for (uint256 index = 0; index < _accounts.length(); index++) {
                uint256 amtToAdd = (amount * _balances[_accounts.at(index)]) / snapshotTotalStaked;
                _balances[_accounts.at(index)] += amtToAdd;
            }
        }
    }

    // Seizing RSR pulls RSR from all current stakers + withdrawers
    function seizeRSR(uint256 amount) external override {
        require(_msgSender() == address(rToken), "Caller is not RToken");
        require(amount > 0, "Amount cannot be zero");

        // Process pending withdrawals
        processWithdrawals();

        uint256 snapshotTotalStakedPlus = _totalSupply + _amountBeingWithdrawn();
        _totalSupply -= amount;

        // Remove RSR for stakers and from withdrawals too
        if (snapshotTotalStakedPlus > 0) {
            for (uint256 index = 0; index < _accounts.length(); index++) {
                uint256 amtToRemove = (amount * _balances[_accounts.at(index)]) / snapshotTotalStakedPlus;
                _balances[_accounts.at(index)] -= amtToRemove;
            }

            for (uint256 index = withdrawalIndex; index < withdrawals.length; index++) {
                uint256 amtToRemove = (amount * withdrawals[index].amount) / snapshotTotalStakedPlus;
                withdrawals[index].amount -= amtToRemove;
            }
        }
        // Transfer RSR to RToken
        rsr.safeTransfer(address(rToken), amount);
    }

    function setStakingWithdrawalDelay(uint256 stakingWithdrawalDelay_) external onlyOwner {
        stakingWithdrawalDelay = stakingWithdrawalDelay_;
    }

    // ERC20 Interface
    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public pure returns (uint8) {
        return 18;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) private {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        // Process pending withdrawals
        processWithdrawals();

        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");
        _balances[sender] = senderBalance - amount;
        _balances[recipient] += amount;
        _accounts.add(recipient);
    }

    function allowance(address owner_, address spender) public view override returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][_msgSender()];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _approve(sender, _msgSender(), currentAllowance - amount);
        return true;
    }

    function _approve(
        address owner_,
        address spender,
        uint256 amount
    ) private {
        require(owner_ != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner_][spender] = amount;
    }

    function _amountBeingWithdrawn() internal view returns (uint256 total) {
        for (uint256 index = withdrawalIndex; index < withdrawals.length; index++) {
            total += withdrawals[index].amount;
        }
    }
}
