import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers'
import { expect } from 'chai'
import { signERC2612Permit } from 'eth-permit'
import { BigNumber, ContractFactory, Wallet } from 'ethers'
import hre, { ethers, waffle } from 'hardhat'
import { getChainId } from '../../common/blockchain-utils'
import { bn, fp, near } from '../../common/numbers'
import {
  CTokenMock,
  ERC20Mock,
  MainCallerMockP0,
  MainP0,
  StaticATokenMock,
  StRSRP0,
  AssetRegistryP0,
  BackingManagerP0,
  BasketHandlerP0,
  IssuerP0,
  DistributorP0,
} from '../../typechain'
import { advanceTime } from '../utils/time'
import { whileImpersonating } from '../utils/impersonation'
import { Collateral, defaultFixture } from './utils/fixtures'

const createFixtureLoader = waffle.createFixtureLoader

describe('StRSRP0 contract', () => {
  let owner: SignerWithAddress
  let addr1: SignerWithAddress
  let addr2: SignerWithAddress
  let addr3: SignerWithAddress
  let other: SignerWithAddress

  // RSR
  let rsr: ERC20Mock

  // Main and AssetManager mocks
  let main: MainP0
  let assetRegistry: AssetRegistryP0
  let backingManager: BackingManagerP0
  let basketHandler: BasketHandlerP0
  let issuer: IssuerP0
  let distributor: DistributorP0

  // StRSR
  let stRSR: StRSRP0

  // Tokens/Assets
  let token0: ERC20Mock
  let token1: ERC20Mock
  let token2: StaticATokenMock
  let token3: CTokenMock

  let collateral0: Collateral
  let collateral1: Collateral
  let collateral2: Collateral
  let collateral3: Collateral

  // Basket
  let basket: Collateral[]
  let basketsNeededAmts: BigNumber[]

  // Quantities
  let initialBal: BigNumber

  let loadFixture: ReturnType<typeof createFixtureLoader>
  let wallet: Wallet

  before('create fixture loader', async () => {
    ;[wallet] = await (ethers as any).getSigners()
    loadFixture = createFixtureLoader([wallet])
  })

  beforeEach(async () => {
    ;[owner, addr1, addr2, addr3, other] = await ethers.getSigners()

    // Deploy fixture
    ;({
      rsr,
      stRSR,
      basket,
      basketsNeededAmts,
      main,
      assetRegistry,
      backingManager,
      basketHandler,
      issuer,
      distributor,
    } = await loadFixture(defaultFixture))

    // Mint initial amounts of RSR
    initialBal = bn('100e18')
    await rsr.connect(owner).mint(addr1.address, initialBal)
    await rsr.connect(owner).mint(addr2.address, initialBal)
    await rsr.connect(owner).mint(addr3.address, initialBal)
    await rsr.connect(owner).mint(owner.address, initialBal)

    // Get assets and tokens
    ;[collateral0, collateral1, collateral2, collateral3] = basket

    token0 = <ERC20Mock>await ethers.getContractAt('ERC20Mock', await collateral0.erc20())
    token1 = <ERC20Mock>await ethers.getContractAt('ERC20Mock', await collateral1.erc20())
    token2 = <StaticATokenMock>(
      await ethers.getContractAt('StaticATokenMock', await collateral2.erc20())
    )
    token3 = <CTokenMock>await ethers.getContractAt('CTokenMock', await collateral3.erc20())
  })

  describe('Deployment', () => {
    it('Should setup initial addresses and values correctly', async () => {
      expect(await rsr.balanceOf(stRSR.address)).to.equal(0)
      expect(await stRSR.balanceOf(owner.address)).to.equal(0)
      expect(await stRSR.balanceOf(addr1.address)).to.equal(0)
      expect(await stRSR.balanceOf(addr2.address)).to.equal(0)

      // ERC20
      expect(await stRSR.name()).to.equal('stRTKNRSR Token')
      expect(await stRSR.symbol()).to.equal('stRTKNRSR')
      expect(await stRSR.decimals()).to.equal(18)
      expect(await stRSR.totalSupply()).to.equal(0)
    })

    it('Should setup the DomainSeparator for Permit correctly', async () => {
      const chainId = await getChainId(hre)
      const _name = await stRSR.name()
      const version = '1'
      const verifyingContract = stRSR.address
      expect(await stRSR.DOMAIN_SEPARATOR()).to.equal(
        await ethers.utils._TypedDataEncoder.hashDomain({
          name: _name,
          version,
          chainId,
          verifyingContract,
        })
      )
    })
  })

  describe('Deposits/Staking', () => {
    it('Should allow to stake/deposit in RSR', async () => {
      // Perform stake
      const amount: BigNumber = bn('1e18')

      // Approve transfer and stake
      await rsr.connect(addr1).approve(stRSR.address, amount)
      await stRSR.connect(addr1).stake(amount)

      // Check balances and stakes
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount)
      expect(await rsr.balanceOf(stRSR.address)).to.equal(await stRSR.totalSupply())
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      expect(await stRSR.balanceOf(addr1.address)).to.equal(amount)
    })

    it('Should not allow to stake amount = 0', async () => {
      // Perform stake
      const amount: BigNumber = bn('1e18')
      const zero: BigNumber = bn(0)

      // Approve transfer and stake
      await rsr.connect(addr1).approve(stRSR.address, amount)
      await expect(stRSR.connect(addr1).stake(zero)).to.be.revertedWith('Cannot stake zero')

      // Check deposit not registered
      expect(await rsr.balanceOf(stRSR.address)).to.equal(0)
      expect(await rsr.balanceOf(stRSR.address)).to.equal(await stRSR.totalSupply())
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal)
      expect(await stRSR.balanceOf(addr1.address)).to.equal(0)
    })

    it('Should allow multiple stakes/deposits in RSR', async () => {
      // Perform stake
      const amount1: BigNumber = bn('1e18')
      const amount2: BigNumber = bn('2e18')
      const amount3: BigNumber = bn('3e18')

      // Approve transfer and stake twice
      await rsr.connect(addr1).approve(stRSR.address, amount1.add(amount2))
      await stRSR.connect(addr1).stake(amount1)
      await stRSR.connect(addr1).stake(amount2)

      // New stake from different account
      await rsr.connect(addr2).approve(stRSR.address, amount3)
      await stRSR.connect(addr2).stake(amount3)

      // Check balances and stakes
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount1.add(amount2).add(amount3))
      expect(await rsr.balanceOf(stRSR.address)).to.equal(await stRSR.totalSupply())
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount1).sub(amount2))
      expect(await stRSR.balanceOf(addr1.address)).to.equal(amount1.add(amount2))
      expect(await rsr.balanceOf(addr2.address)).to.equal(initialBal.sub(amount3))
      expect(await stRSR.balanceOf(addr2.address)).to.equal(amount3)
    })
  })

  describe('Withdrawals/Unstaking', () => {
    it('Should create Pending withdrawal when unstaking', async () => {
      const amount: BigNumber = bn('1e18')

      // Stake
      await rsr.connect(addr1).approve(stRSR.address, amount)
      await stRSR.connect(addr1).stake(amount)

      // Unstake
      await stRSR.connect(addr1).unstake(amount)

      // Check withdrawal properly registered
      const [unstakeAcc, unstakeAmt] = await stRSR.withdrawals(addr1.address, 0)
      expect(unstakeAcc).to.equal(addr1.address)
      expect(unstakeAmt).to.equal(amount)

      // Check balances and stakes
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount)
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))

      // All staked funds withdrawn upfront
      expect(await stRSR.balanceOf(addr1.address)).to.equal(0)
      expect(await stRSR.totalSupply()).to.equal(0)
    })

    it('Should not allow to unstake amount = 0', async () => {
      const zero: BigNumber = bn(0)

      // Unstake
      await expect(stRSR.connect(addr1).unstake(zero)).to.be.revertedWith('Cannot withdraw zero')
    })

    it('Should not allow to unstake if not enough balance', async () => {
      const amount: BigNumber = bn('1e18')

      // Unstake with no stakes/balance
      await expect(stRSR.connect(addr1).unstake(amount)).to.be.revertedWith('Not enough balance')
    })

    it('Should allow multiple unstakes/withdrawals in RSR', async () => {
      // Perform stake
      const amount1: BigNumber = bn('1e18')
      const amount2: BigNumber = bn('2e18')
      const amount3: BigNumber = bn('3e18')

      // Approve transfers
      await rsr.connect(addr1).approve(stRSR.address, amount1.add(amount2))
      await rsr.connect(addr2).approve(stRSR.address, amount3)

      // Stake
      await stRSR.connect(addr1).stake(amount1)
      await stRSR.connect(addr1).stake(amount2)
      await stRSR.connect(addr2).stake(amount3)

      // Unstake - Create withdrawal
      await stRSR.connect(addr1).unstake(amount1)
      let [unstakeAcc, unstakeAmt] = await stRSR.withdrawals(addr1.address, 0)
      expect(unstakeAcc).to.equal(addr1.address)
      expect(unstakeAmt).to.equal(amount1)

      // All staked funds withdrawn upfront
      expect(await stRSR.balanceOf(addr1.address)).to.equal(amount2)

      // Unstake again
      await stRSR.connect(addr1).unstake(amount2)
      ;[unstakeAcc, unstakeAmt] = await stRSR.withdrawals(addr1.address, 1)
      expect(unstakeAcc).to.equal(addr1.address)
      expect(unstakeAmt).to.equal(amount2)

      // All staked funds withdrawn upfront
      expect(await stRSR.balanceOf(addr1.address)).to.equal(0)

      // Unstake again with different user (will withdraw previous stake)
      await stRSR.connect(addr2).unstake(amount3)
      ;[unstakeAcc, unstakeAmt] = await stRSR.withdrawals(addr2.address, 0)
      expect(unstakeAcc).to.equal(addr2.address)
      expect(unstakeAmt).to.equal(amount3)

      // All staked funds withdrawn upfront
      expect(await stRSR.balanceOf(addr2.address)).to.equal(0)
    })

    context('With deposits and withdrawals', async () => {
      let amount1: BigNumber
      let amount2: BigNumber
      let amount3: BigNumber
      let stkWithdrawalDelay: number

      beforeEach(async () => {
        stkWithdrawalDelay = (await stRSR.unstakingDelay()).toNumber()

        // Perform stake
        amount1 = bn('1e18')
        amount2 = bn('2e18')
        amount3 = bn('3e18')

        // Approve transfers
        await rsr.connect(addr1).approve(stRSR.address, amount1)
        await rsr.connect(addr2).approve(stRSR.address, amount2.add(amount3))

        // Stake
        await stRSR.connect(addr1).stake(amount1)
        await stRSR.connect(addr2).stake(amount2)
        await stRSR.connect(addr2).stake(amount3)

        // Unstake - Create withdrawal
        await stRSR.connect(addr1).unstake(amount1)
      })

      it('Should revert withdraw if Main is paused', async () => {
        // Get current balance for user
        const prevAddr1Balance = await rsr.balanceOf(addr1.address)

        // Move forward past stakingWithdrawalDelay
        await advanceTime(stkWithdrawalDelay + 1)

        // Pause Main
        await main.connect(owner).pause()

        // Withdraw
        await expect(stRSR.connect(addr1).withdraw(1)).to.be.revertedWith('is paused')

        // If unpaused should withdraw OK
        await main.connect(owner).unpause()

        // Withdraw
        await stRSR.connect(addr1).withdraw(1)

        // Withdrawal was completed
        expect(await stRSR.totalSupply()).to.equal(amount2.add(amount3))
        expect(await rsr.balanceOf(stRSR.address)).to.equal(await stRSR.totalSupply())
        expect(await rsr.balanceOf(addr1.address)).to.equal(prevAddr1Balance.add(amount1))
        expect(await stRSR.balanceOf(addr1.address)).to.equal(0)
      })

      it('Should not withdraw if Manager is not fully capitalized', async () => {
        // Need to issue some RTokens to handle fully/not fully capitalized
        await token0.connect(owner).mint(addr1.address, initialBal)
        await token1.connect(owner).mint(addr1.address, initialBal)
        await token2.connect(owner).mint(addr1.address, initialBal)
        await token3.connect(owner).mint(addr1.address, initialBal)

        // Approvals
        await token0.connect(addr1).approve(issuer.address, initialBal)
        await token1.connect(addr1).approve(issuer.address, initialBal)
        await token2.connect(addr1).approve(issuer.address, initialBal)
        await token3.connect(addr1).approve(issuer.address, initialBal)

        // Issue tokens
        const issueAmount: BigNumber = bn('100e18')
        await issuer.connect(addr1).issue(issueAmount)

        // Get current balance for user
        const prevAddr1Balance = await rsr.balanceOf(addr1.address)

        // Move forward past stakingWithdrawalDelay
        await advanceTime(stkWithdrawalDelay + 1)

        // Save backing tokens
        const erc20s = await basketHandler.tokens()

        // Set not fully capitalized by changing basket
        await basketHandler.connect(owner).setPrimeBasket([token0.address], [fp('1e18')])
        await basketHandler.connect(owner).switchBasket()
        expect(await basketHandler.fullyCapitalized()).to.equal(false)

        // Withdraw
        await expect(stRSR.connect(addr1).withdraw(1)).to.be.revertedWith('RToken uncapitalized')

        // If fully capitalized should withdraw OK  - Set back original basket
        await basketHandler.connect(owner).setPrimeBasket(erc20s, basketsNeededAmts)
        await basketHandler.connect(owner).switchBasket()

        expect(await basketHandler.fullyCapitalized()).to.equal(true)

        // Withdraw
        await stRSR.connect(addr1).withdraw(1)

        // Withdrawal completed
        expect(await stRSR.totalSupply()).to.equal(amount2.add(amount3))
        expect(await rsr.balanceOf(stRSR.address)).to.equal(await stRSR.totalSupply())
        expect(await rsr.balanceOf(addr1.address)).to.equal(prevAddr1Balance.add(amount1))
        // All staked funds withdrawn upfront
        expect(await stRSR.balanceOf(addr1.address)).to.equal(0)
      })

      it('Should not withdraw before stakingWithdrawalDelay', async () => {
        // Withdraw
        await expect(stRSR.connect(addr1).withdraw(1)).to.be.revertedWith('withdrawal unavailable')

        // Nothing completed so far
        expect(await stRSR.totalSupply()).to.equal(amount2.add(amount3))
        expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount1))
        expect(await stRSR.balanceOf(addr1.address)).to.equal(0)

        // Withdraw after certain time (still before stakingWithdrawalDelay)
        await advanceTime(stkWithdrawalDelay / 2)

        await expect(stRSR.connect(addr1).withdraw(1)).to.be.revertedWith('withdrawal unavailable')

        // Nothing completed still
        expect(await stRSR.totalSupply()).to.equal(amount2.add(amount3))
        expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount1))
        expect(await stRSR.balanceOf(addr1.address)).to.equal(0)
      })

      it('Should withdrawa after stakingWithdrawalDelay', async () => {
        // Get current balance for user
        const prevAddr1Balance = await rsr.balanceOf(addr1.address)

        // Move forward past stakingWithdrawalDelay
        await advanceTime(stkWithdrawalDelay + 1)

        // Withdraw
        await stRSR.connect(addr1).withdraw(1)

        // Withdrawal was completed
        expect(await stRSR.totalSupply()).to.equal(amount2.add(amount3))
        expect(await rsr.balanceOf(stRSR.address)).to.equal(await stRSR.totalSupply())
        expect(await rsr.balanceOf(addr1.address)).to.equal(prevAddr1Balance.add(amount1))
        // All staked funds withdrawn upfront
        expect(await stRSR.balanceOf(addr1.address)).to.equal(0)
      })

      it('Should store weights and calculate balance correctly', async () => {
        // Get current balances for users
        const prevAddr1Balance = await rsr.balanceOf(addr1.address)
        const prevAddr2Balance = await rsr.balanceOf(addr2.address)

        // Create additional withdrawal - will also withdraw previous one
        await stRSR.connect(addr2).unstake(amount2)

        // Move forward past stakingWithdrawalDelaylay
        await advanceTime(stkWithdrawalDelay + 1)

        // Withdraw
        await stRSR.connect(addr1).withdraw(await stRSR.endIdForWithdraw(addr1.address))
        await stRSR.connect(addr2).withdraw(await stRSR.endIdForWithdraw(addr2.address))

        // Withdrawals completed
        expect(await stRSR.totalSupply()).to.equal(amount3)
        expect(await rsr.balanceOf(stRSR.address)).to.equal(await stRSR.totalSupply())
        expect(await rsr.balanceOf(addr1.address)).to.equal(prevAddr1Balance.add(amount1))
        expect(await stRSR.balanceOf(addr1.address)).to.equal(0)
        expect(await rsr.balanceOf(addr2.address)).to.equal(prevAddr2Balance.add(amount2))
        expect(await stRSR.balanceOf(addr2.address)).to.equal(amount3)

        // Create additional withdrawal
        await stRSR.connect(addr2).unstake(amount3)

        // Move forward past stakingWithdrawalDelay
        await advanceTime(stkWithdrawalDelay + 1)

        // Withdraw
        await stRSR.connect(addr2).withdraw(await stRSR.endIdForWithdraw(addr2.address))

        // Withdrawals completed
        expect(await stRSR.totalSupply()).to.equal(0)
        expect(await rsr.balanceOf(stRSR.address)).to.equal(await stRSR.totalSupply())
        expect(await rsr.balanceOf(addr1.address)).to.equal(prevAddr1Balance.add(amount1))
        expect(await stRSR.balanceOf(addr1.address)).to.equal(0)
        expect(await rsr.balanceOf(addr2.address)).to.equal(
          prevAddr2Balance.add(amount2).add(amount3)
        )
        expect(await stRSR.balanceOf(addr2.address)).to.equal(0)
      })
    })
  })

  describe('Add RSR', () => {
    it('Should not allow to remove RSR if caller is not the Backing Trader', async () => {
      const amount: BigNumber = bn('1e18')
      const prevPoolBalance: BigNumber = await rsr.balanceOf(stRSR.address)

      await expect(stRSR.connect(other).seizeRSR(amount)).to.be.revertedWith('not main')
      expect(await rsr.balanceOf(stRSR.address)).to.equal(prevPoolBalance)
    })

    it('Should allow to add RSR - Single staker', async () => {
      const amount: BigNumber = bn('1e18')
      const amount2: BigNumber = bn('10e18')

      // Stake
      await rsr.connect(addr1).approve(stRSR.address, amount)
      await stRSR.connect(addr1).stake(amount)

      // Check balances and stakes
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount)
      expect(await rsr.balanceOf(stRSR.address)).to.equal(await stRSR.totalSupply())
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      expect(await stRSR.balanceOf(addr1.address)).to.equal(amount)

      // TODO Smoothing tests
      // Add RSR
      // await rsr.connect(owner).transfer(stRSR.address, amount2)
      // await stRSR.connect(owner).notifyOfDeposit(rsr.address)

      // // Check balances and stakes
      // expect(await rsr.balanceOf(stRSR.address)).to.equal(amount.add(amount2))
      // expect(await rsr.balanceOf(stRSR.address)).to.equal(await stRSR.totalSupply())
      // expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      // expect(await stRSR.balanceOf(addr1.address)).to.equal(amount.add(amount2))
    })

    it('Should allow to add RSR - Two stakers - Rounded values', async () => {
      const amount: BigNumber = bn('1e18')
      const amount2: BigNumber = bn('10e18')

      // Stake
      await rsr.connect(addr1).approve(stRSR.address, amount)
      await stRSR.connect(addr1).stake(amount)

      await rsr.connect(addr2).approve(stRSR.address, amount)
      await stRSR.connect(addr2).stake(amount)

      // Check balances and stakes
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount.mul(2))
      expect(await rsr.balanceOf(stRSR.address)).to.equal(await stRSR.totalSupply())
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      expect(await rsr.balanceOf(addr2.address)).to.equal(initialBal.sub(amount))
      expect(await stRSR.balanceOf(addr1.address)).to.equal(amount)
      expect(await stRSR.balanceOf(addr2.address)).to.equal(amount)

      // TODO Smoothing tests
      // Add RSR
      // await rsr.connect(owner).transfer(stRSR.address, amount2)
      // await stRSR.connect(owner).notifyOfDeposit(rsr.address)

      // // Check balances and stakes
      // expect(await rsr.balanceOf(stRSR.address)).to.equal(amount.mul(2).add(amount2))
      // expect(await rsr.balanceOf(stRSR.address)).to.equal(await stRSR.totalSupply())
      // expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      // expect(await rsr.balanceOf(addr2.address)).to.equal(initialBal.sub(amount))
      // expect(await stRSR.balanceOf(addr1.address)).to.equal(amount.add(amount2.div(2)))
      // expect(await stRSR.balanceOf(addr2.address)).to.equal(amount.add(amount2.div(2)))
    })

    it('Should allow to add RSR - Three stakers - Check Precision', async () => {
      const amount: BigNumber = bn('1e18')
      const amount2: BigNumber = bn('10e18')

      // Stake
      await rsr.connect(addr1).approve(stRSR.address, amount)
      await stRSR.connect(addr1).stake(amount)

      await rsr.connect(addr2).approve(stRSR.address, amount)
      await stRSR.connect(addr2).stake(amount)

      await rsr.connect(addr3).approve(stRSR.address, amount)
      await stRSR.connect(addr3).stake(amount)

      // Check balances and stakes
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount.mul(3))
      expect(await rsr.balanceOf(stRSR.address)).to.equal(await stRSR.totalSupply())
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      expect(await rsr.balanceOf(addr2.address)).to.equal(initialBal.sub(amount))
      expect(await rsr.balanceOf(addr3.address)).to.equal(initialBal.sub(amount))
      expect(await stRSR.balanceOf(addr1.address)).to.equal(amount)
      expect(await stRSR.balanceOf(addr2.address)).to.equal(amount)
      expect(await stRSR.balanceOf(addr3.address)).to.equal(amount)

      // TODO Smoothing tests
      // Add RSR
      // await rsr.connect(owner).transfer(stRSR.address, amount2)
      // await stRSR.connect(owner).notifyOfDeposit(rsr.address)

      // // Check balances and stakes
      // expect(await rsr.balanceOf(stRSR.address)).to.equal(amount.mul(3).add(amount2))
      // expect(near(await rsr.balanceOf(stRSR.address), await stRSR.totalSupply(), 1)).to.equal(true)
      // expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      // expect(await rsr.balanceOf(addr2.address)).to.equal(initialBal.sub(amount))
      // expect(await rsr.balanceOf(addr3.address)).to.equal(initialBal.sub(amount))

      // expect(await stRSR.balanceOf(addr1.address)).to.equal(amount.add(amount2.div(3)))
      // expect(await stRSR.balanceOf(addr2.address)).to.equal(amount.add(amount2.div(3)))
      // expect(await stRSR.balanceOf(addr3.address)).to.equal(amount.add(amount2.div(3)))
    })
  })

  describe('Remove RSR', () => {
    it('Should allow to remove RSR - Single staker', async () => {
      const amount: BigNumber = bn('10e18')
      const amount2: BigNumber = bn('1e18')

      // Stake
      await rsr.connect(addr1).approve(stRSR.address, amount)
      await stRSR.connect(addr1).stake(amount)

      // Check balances and stakes
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount)
      expect(await rsr.balanceOf(stRSR.address)).to.equal(await stRSR.totalSupply())
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      expect(await stRSR.balanceOf(addr1.address)).to.equal(amount)

      // Seize RSR
      await whileImpersonating(backingManager.address, async (signer) => {
        await stRSR.connect(signer).seizeRSR(amount2)
      })

      // Check balances and stakes
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount.sub(amount2))
      expect(await stRSR.totalSupply()).to.equal(amount)
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      expect(await stRSR.balanceOf(addr1.address)).to.equal(amount)
    })

    it('Should allow to remove RSR - Two stakers - Rounded values', async () => {
      const amount: BigNumber = bn('10e18')
      const amount2: BigNumber = bn('1e18')

      // Stake
      await rsr.connect(addr1).approve(stRSR.address, amount)
      await stRSR.connect(addr1).stake(amount)

      await rsr.connect(addr2).approve(stRSR.address, amount)
      await stRSR.connect(addr2).stake(amount)

      // Check balances and stakes
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount.mul(2))
      expect(await rsr.balanceOf(stRSR.address)).to.equal(await stRSR.totalSupply())
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      expect(await rsr.balanceOf(addr2.address)).to.equal(initialBal.sub(amount))
      expect(await stRSR.balanceOf(addr1.address)).to.equal(amount)
      expect(await stRSR.balanceOf(addr2.address)).to.equal(amount)

      // Seize RSR
      await whileImpersonating(backingManager.address, async (signer) => {
        await stRSR.connect(signer).seizeRSR(amount2)
      })

      // Check balances and stakes
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount.mul(2).sub(amount2))
      expect(await stRSR.totalSupply()).to.equal(amount.mul(2))
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      expect(await rsr.balanceOf(addr2.address)).to.equal(initialBal.sub(amount))
      expect(await stRSR.balanceOf(addr1.address)).to.equal(amount)
      expect(await stRSR.balanceOf(addr2.address)).to.equal(amount)
    })

    it('Should allow to remove RSR - Three stakers - Check Precision', async () => {
      const amount: BigNumber = bn('10e18')
      const amount2: BigNumber = bn('1e18')

      // Stake
      await rsr.connect(addr1).approve(stRSR.address, amount)
      await stRSR.connect(addr1).stake(amount)

      await rsr.connect(addr2).approve(stRSR.address, amount)
      await stRSR.connect(addr2).stake(amount)

      await rsr.connect(addr3).approve(stRSR.address, amount)
      await stRSR.connect(addr3).stake(amount)

      // Check balances and stakes
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount.mul(3))
      expect(near(await rsr.balanceOf(stRSR.address), await stRSR.totalSupply(), 1)).to.equal(true)
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      expect(await rsr.balanceOf(addr2.address)).to.equal(initialBal.sub(amount))
      expect(await rsr.balanceOf(addr3.address)).to.equal(initialBal.sub(amount))
      expect(await stRSR.balanceOf(addr1.address)).to.equal(amount)
      expect(await stRSR.balanceOf(addr2.address)).to.equal(amount)
      expect(await stRSR.balanceOf(addr3.address)).to.equal(amount)

      // Seize RSR
      await whileImpersonating(backingManager.address, async (signer) => {
        await stRSR.connect(signer).seizeRSR(amount2)
      })

      // Check balances and stakes
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount.mul(3).sub(amount2))
      expect(await stRSR.totalSupply()).to.equal(amount.mul(3))
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      expect(await rsr.balanceOf(addr2.address)).to.equal(initialBal.sub(amount))
      expect(await rsr.balanceOf(addr3.address)).to.equal(initialBal.sub(amount))

      expect(await stRSR.balanceOf(addr1.address)).to.equal(amount)
      expect(await stRSR.balanceOf(addr2.address)).to.equal(amount)
      expect(await stRSR.balanceOf(addr3.address)).to.equal(amount)
    })

    it('Should remove RSR from Withdrawers', async () => {
      const amount: BigNumber = bn('10e18')
      const amount2: BigNumber = bn('1e18')

      // Stake
      await rsr.connect(addr1).approve(stRSR.address, amount)
      await stRSR.connect(addr1).stake(amount)

      // Check balances and stakes
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount)
      expect(near(await rsr.balanceOf(stRSR.address), await stRSR.totalSupply(), 1)).to.equal(true)
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      expect(await stRSR.balanceOf(addr1.address)).to.equal(amount)

      // Unstake
      await stRSR.connect(addr1).unstake(amount)

      // Check withdrawal properly registered
      let [unstakeAcc, unstakeAmt] = await stRSR.withdrawals(addr1.address, 0)
      expect(unstakeAcc).to.equal(addr1.address)
      expect(unstakeAmt).to.equal(amount)

      // Check balances and stakes
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount)
      expect(await stRSR.totalSupply()).to.equal(0)
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      expect(await stRSR.balanceOf(addr1.address)).to.equal(0)

      // Seize RSR
      await whileImpersonating(backingManager.address, async (signer) => {
        await expect(stRSR.connect(signer).seizeRSR(amount2))
          .to.emit(rsr, 'Transfer')
          .withArgs(stRSR.address, backingManager.address, amount2)
      })

      // Check balances, stakes, and withdrawals
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount.sub(amount2))
      expect(await stRSR.totalSupply()).to.equal(0)
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      expect(await stRSR.balanceOf(addr1.address)).to.equal(0)

      // Check impacted withdrawal
      ;[unstakeAcc, unstakeAmt] = await stRSR.withdrawals(addr1.address, 0)
      expect(unstakeAcc).to.equal(addr1.address)
      expect(unstakeAmt).to.equal(amount.sub(amount2))
    })

    it('Should remove RSR proportionally from Stakers and Withdrawers', async () => {
      const amount: BigNumber = bn('10e18')
      const amount2: BigNumber = bn('1e18')

      // Stake
      await rsr.connect(addr1).approve(stRSR.address, amount)
      await stRSR.connect(addr1).stake(amount)

      await rsr.connect(addr2).approve(stRSR.address, amount)
      await stRSR.connect(addr2).stake(amount)

      // Check balances and stakes
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount.mul(2))
      expect(await rsr.balanceOf(stRSR.address)).to.equal(await stRSR.totalSupply())
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      expect(await rsr.balanceOf(addr2.address)).to.equal(initialBal.sub(amount))
      expect(await stRSR.balanceOf(addr1.address)).to.equal(amount)
      expect(await stRSR.balanceOf(addr2.address)).to.equal(amount)

      // Unstake
      await stRSR.connect(addr1).unstake(amount)

      // Check withdrawal properly registered
      let [unstakeAcc, unstakeAmt] = await stRSR.withdrawals(addr1.address, 0)
      expect(unstakeAcc).to.equal(addr1.address)
      expect(unstakeAmt).to.equal(amount)

      // Check balances and stakes
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount.mul(2))
      expect(await stRSR.totalSupply()).to.equal(amount)
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      expect(await rsr.balanceOf(addr2.address)).to.equal(initialBal.sub(amount))
      expect(await stRSR.balanceOf(addr1.address)).to.equal(0)
      expect(await stRSR.balanceOf(addr2.address)).to.equal(amount)

      // Seize RSR
      await whileImpersonating(backingManager.address, async (signer) => {
        await stRSR.connect(signer).seizeRSR(amount2)
      })

      // Check balances, stakes, and withdrawals
      const proportionalAmountToSeize: BigNumber = amount2.div(2)

      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount.mul(2).sub(amount2))
      expect(await stRSR.totalSupply()).to.equal(amount)
      expect(await rsr.balanceOf(addr1.address)).to.equal(initialBal.sub(amount))
      expect(await rsr.balanceOf(addr2.address)).to.equal(initialBal.sub(amount))
      expect(await stRSR.balanceOf(addr1.address)).to.equal(0)
      expect(await stRSR.balanceOf(addr2.address)).to.equal(amount)

      // // Check impacted withdrawal
      ;[unstakeAcc, unstakeAmt] = await stRSR.withdrawals(addr1.address, 0)
      expect(unstakeAcc).to.equal(addr1.address)
      expect(unstakeAmt).to.equal(amount.sub(proportionalAmountToSeize))
    })
  })

  describe('Transfers', () => {
    let amount: BigNumber

    beforeEach(async function () {
      // Stake some RSR
      amount = bn('10e18')

      // Approve transfer and stake
      await rsr.connect(addr1).approve(stRSR.address, amount)

      await stRSR.connect(addr1).stake(amount)
    })

    it('Should transfer stakes between accounts', async function () {
      const addr1BalancePrev = await stRSR.balanceOf(addr1.address)
      const addr2BalancePrev = await stRSR.balanceOf(addr2.address)
      const totalSupplyPrev = await stRSR.totalSupply()

      //  Perform transfer
      await stRSR.connect(addr1).transfer(addr2.address, amount)

      expect(await stRSR.balanceOf(addr1.address)).to.equal(addr1BalancePrev.sub(amount))
      expect(await stRSR.balanceOf(addr2.address)).to.equal(addr2BalancePrev.add(amount))
      expect(await stRSR.totalSupply()).to.equal(totalSupplyPrev)
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount)
    })

    it('Should not transfer stakes if no balance', async function () {
      const addr1BalancePrev = await stRSR.balanceOf(addr1.address)
      const addr2BalancePrev = await stRSR.balanceOf(addr2.address)
      const totalSupplyPrev = await stRSR.totalSupply()

      //  Perform transfer with user with no stake
      await expect(stRSR.connect(addr2).transfer(addr1.address, amount)).to.be.revertedWith(
        'ERC20: transfer amount exceeds balance'
      )

      expect(await stRSR.balanceOf(addr1.address)).to.equal(addr1BalancePrev)
      expect(await stRSR.balanceOf(addr2.address)).to.equal(addr2BalancePrev)
      expect(await stRSR.totalSupply()).to.equal(totalSupplyPrev)
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount)
    })

    it('Should transferFrom stakes between accounts', async function () {
      const addr1BalancePrev = await stRSR.balanceOf(addr1.address)
      const addr2BalancePrev = await stRSR.balanceOf(addr2.address)
      const totalSupplyPrev = await stRSR.totalSupply()

      // Set allowance and transfer
      await stRSR.connect(addr1).approve(addr2.address, amount)

      expect(await stRSR.allowance(addr1.address, addr2.address)).to.equal(amount)

      await stRSR.connect(addr2).transferFrom(addr1.address, other.address, amount)

      expect(await stRSR.allowance(addr1.address, addr2.address)).to.equal(0)
      expect(await stRSR.balanceOf(addr1.address)).to.equal(addr1BalancePrev.sub(amount))
      expect(await stRSR.balanceOf(addr2.address)).to.equal(addr2BalancePrev)
      expect(await stRSR.balanceOf(other.address)).to.equal(amount)
      expect(await stRSR.totalSupply()).to.equal(totalSupplyPrev)
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount)
    })

    it('Should set allowance when using "Permit"', async () => {
      expect(await stRSR.allowance(addr1.address, addr2.address)).to.equal(0)

      const permit = await signERC2612Permit(
        addr1,
        stRSR.address,
        addr1.address,
        addr2.address,
        amount.toString()
      )

      await expect(
        stRSR.permit(
          addr1.address,
          addr2.address,
          amount,
          permit.deadline,
          permit.v,
          permit.r,
          permit.s
        )
      )
        .to.emit(stRSR, 'Approval')
        .withArgs(addr1.address, addr2.address, amount)
      expect(await stRSR.allowance(addr1.address, addr2.address)).to.equal(amount)
    })

    it('Should not transferFrom stakes if no allowance', async function () {
      const addr1BalancePrev = await stRSR.balanceOf(addr1.address)
      const addr2BalancePrev = await stRSR.balanceOf(addr2.address)
      const totalSupplyPrev = await stRSR.totalSupply()

      // Set allowance and transfer
      expect(await stRSR.allowance(addr1.address, addr2.address)).to.equal(0)
      await expect(
        stRSR.connect(addr2).transferFrom(addr1.address, other.address, amount)
      ).to.be.revertedWith('ERC20: transfer amount exceeds allowance')
      expect(await stRSR.balanceOf(addr1.address)).to.equal(addr1BalancePrev)
      expect(await stRSR.balanceOf(addr2.address)).to.equal(addr2BalancePrev)
      expect(await stRSR.balanceOf(other.address)).to.equal(0)
      expect(await stRSR.totalSupply()).to.equal(totalSupplyPrev)
      expect(await rsr.balanceOf(stRSR.address)).to.equal(amount)
    })
  })
})
