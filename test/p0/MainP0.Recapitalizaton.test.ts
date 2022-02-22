import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers'
import { expect } from 'chai'
import { BigNumber, Wallet } from 'ethers'
import { ethers, waffle } from 'hardhat'

import {
  AuctionStatus,
  BN_SCALE_FACTOR,
  CollateralStatus,
  ZERO_ADDRESS,
} from '../../common/constants'
import { bn, divCeil, fp, near, toBNDecimals } from '../../common/numbers'
import { AaveLendingPoolMockP0 } from '../../typechain/AaveLendingPoolMockP0'
import { AaveOracleMockP0 } from '../../typechain/AaveOracleMockP0'
import { AssetP0 } from '../../typechain/AssetP0'
import { ATokenFiatCollateralP0 } from '../../typechain/ATokenFiatCollateralP0'
import { CollateralP0 } from '../../typechain/CollateralP0'
import { ComptrollerMockP0 } from '../../typechain/ComptrollerMockP0'
import { CTokenFiatCollateralP0 } from '../../typechain/CTokenFiatCollateralP0'
import { CTokenMock } from '../../typechain/CTokenMock'
import { DeployerP0 } from '../../typechain/DeployerP0'
import { ERC20Mock } from '../../typechain/ERC20Mock'
import { ExplorerFacadeP0 } from '../../typechain/ExplorerFacadeP0'
import { FurnaceP0 } from '../../typechain/FurnaceP0'
import { MainP0 } from '../../typechain/MainP0'
import { MarketMock } from '../../typechain/MarketMock'
import { RevenueTraderP0 } from '../../typechain/RevenueTraderP0'
import { RTokenAssetP0 } from '../../typechain/RTokenAssetP0'
import { RTokenP0 } from '../../typechain/RTokenP0'
import { StaticATokenMock } from '../../typechain/StaticATokenMock'
import { StRSRP0 } from '../../typechain/StRSRP0'
import { TraderP0 } from '../../typechain/TraderP0'
import { USDCMock } from '../../typechain/USDCMock'
import { advanceTime, getLatestBlockTimestamp } from '../utils/time'
import { Collateral, defaultFixture, IConfig, IRevenueShare } from './utils/fixtures'

const expectAuctionInfo = async (
  trader: TraderP0,
  index: number,
  auctionInfo: Partial<IAuctionInfo>
) => {
  const {
    sell,
    buy,
    sellAmount,
    minBuyAmount,
    startTime,
    endTime,
    clearingSellAmount,
    clearingBuyAmount,
    externalAuctionId,
    status,
  } = await trader.auctions(index)
  expect(sell).to.equal(auctionInfo.sell)
  expect(buy).to.equal(auctionInfo.buy)
  expect(sellAmount).to.equal(auctionInfo.sellAmount)
  expect(minBuyAmount).to.equal(auctionInfo.minBuyAmount)
  expect(startTime).to.equal(auctionInfo.startTime)
  expect(endTime).to.equal(auctionInfo.endTime)
  expect(clearingSellAmount).to.equal(auctionInfo.clearingSellAmount)
  expect(clearingBuyAmount).to.equal(auctionInfo.clearingBuyAmount)
  expect(externalAuctionId).to.equal(auctionInfo.externalAuctionId)
  expect(status).to.equal(auctionInfo.status)
}

const expectAuctionStatus = async (
  trader: TraderP0,
  index: number,
  expectedStatus: AuctionStatus
) => {
  const { status } = await trader.auctions(index)
  expect(status).to.equal(expectedStatus)
}

interface IAuctionInfo {
  sell: string
  buy: string
  sellAmount: BigNumber
  minBuyAmount: BigNumber
  startTime: number
  endTime: number
  clearingSellAmount: BigNumber
  clearingBuyAmount: BigNumber
  externalAuctionId: BigNumber
  status: AuctionStatus
}

const createFixtureLoader = waffle.createFixtureLoader

describe('MainP0 contract', () => {
  let owner: SignerWithAddress
  let addr1: SignerWithAddress
  let addr2: SignerWithAddress
  let other: SignerWithAddress

  // Deployer contract
  let deployer: DeployerP0

  // Assets
  let collateral: Collateral[]

  // Non-backing assets
  let rsr: ERC20Mock
  let rsrAsset: AssetP0
  let compToken: ERC20Mock
  let compAsset: AssetP0
  let compoundMock: ComptrollerMockP0
  let aaveToken: ERC20Mock
  let aaveAsset: AssetP0
  let aaveMock: AaveLendingPoolMockP0
  let aaveOracleInternal: AaveOracleMockP0

  // Trading
  let market: MarketMock
  let rsrTrader: RevenueTraderP0
  let rTokenTrader: RevenueTraderP0

  // Tokens and Assets
  let initialBal: BigNumber
  let token0: ERC20Mock
  let token1: USDCMock
  let token2: StaticATokenMock
  let token3: CTokenMock
  let collateral0: CollateralP0
  let collateral1: CollateralP0
  let collateral2: ATokenFiatCollateralP0
  let collateral3: CTokenFiatCollateralP0
  let basketsNeededAmts: BigNumber[]

  // Config values
  let config: IConfig
  let dist: IRevenueShare

  // Contracts to retrieve after deploy
  let rToken: RTokenP0
  let rTokenAsset: RTokenAssetP0
  let stRSR: StRSRP0
  let furnace: FurnaceP0
  let main: MainP0
  let facade: ExplorerFacadeP0

  let loadFixture: ReturnType<typeof createFixtureLoader>
  let wallet: Wallet

  before('create fixture loader', async () => {
    ;[wallet] = await (ethers as any).getSigners()
    loadFixture = createFixtureLoader([wallet])
  })

  beforeEach(async () => {
    ;[owner, addr1, addr2, other] = await ethers.getSigners()
    let erc20s: ERC20Mock[]
    let basket: Collateral[]

      // Deploy fixture
    ;({
      rsr,
      rsrAsset,
      compToken,
      aaveToken,
      compAsset,
      aaveAsset,
      compoundMock,
      aaveMock,
      aaveOracleInternal,
      erc20s,
      collateral,
      basket,
      basketsNeededAmts,
      config,
      deployer,
      dist,
      main,
      rToken,
      rTokenAsset,
      furnace,
      stRSR,
      market,
      facade,
    } = await loadFixture(defaultFixture))
    token0 = erc20s[collateral.indexOf(basket[0])]
    token1 = erc20s[collateral.indexOf(basket[1])]
    token2 = <StaticATokenMock>erc20s[collateral.indexOf(basket[2])]
    token3 = <CTokenMock>erc20s[collateral.indexOf(basket[3])]

    // Set Aave revenue token
    await token2.setAaveToken(aaveToken.address)

    collateral0 = basket[0]
    collateral1 = basket[1]
    collateral2 = <ATokenFiatCollateralP0>basket[2]
    collateral3 = <CTokenFiatCollateralP0>basket[3]

    // Mint initial balances
    initialBal = bn('1000000e18')
    await token0.connect(owner).mint(addr1.address, initialBal)
    await token1.connect(owner).mint(addr1.address, initialBal)
    await token2.connect(owner).mint(addr1.address, initialBal)
    await token3.connect(owner).mint(addr1.address, initialBal)

    await token0.connect(owner).mint(addr2.address, initialBal)
    await token1.connect(owner).mint(addr2.address, initialBal)
    await token2.connect(owner).mint(addr2.address, initialBal)
    await token3.connect(owner).mint(addr2.address, initialBal)
  })

  describe('Recapitalization', function () {
    context('With very simple Basket - Single stablecoin', async function () {
      let issueAmount: BigNumber

      beforeEach(async function () {
        // Issue some RTokens to user
        issueAmount = bn('100e18')

        // Setup new basket with single token
        await main.connect(owner).setPrimeBasket([collateral0.address], [fp('1')])
        await main.connect(owner).switchBasket()

        // Provide approvals
        await token0.connect(addr1).approve(main.address, initialBal)

        // Issue rTokens
        await main.connect(addr1).issue(issueAmount)

        // Mint some RSR
        await rsr.connect(owner).mint(addr1.address, initialBal)
      })

      it('Should recapitalize correctly when switching basket - Full amount covered', async () => {
        // Setup prime basket
        await main.connect(owner).setPrimeBasket([collateral1.address], [fp('1')])

        // Set Max auction to 100% to perform it in one single auction
        await main.connect(owner).setMaxAuctionSize(fp('1'))

        // Check initial state
        expect(await main.worstCollateralStatus()).to.equal(CollateralStatus.SOUND)
        expect(await main.fullyCapitalized()).to.equal(true)
        expect(await main.totalAssetValue()).to.equal(issueAmount)
        expect(await token0.balanceOf(main.address)).to.equal(issueAmount)
        expect(await token1.balanceOf(main.address)).to.equal(0)
        expect(await rToken.totalSupply()).to.equal(issueAmount)

        //  Check price in USD of the current RToken
        expect(await main.rTokenPrice()).to.equal(fp('1'))

        // Switch Basket
        await expect(main.connect(owner).switchBasket()).to.emit(main, 'BasketSet')

        // Check state remains SOUND
        expect(await main.worstCollateralStatus()).to.equal(CollateralStatus.SOUND)
        expect(await main.fullyCapitalized()).to.equal(false)
        expect(await main.totalAssetValue()).to.equal(issueAmount)
        expect(await token0.balanceOf(main.address)).to.equal(issueAmount)
        expect(await token1.balanceOf(main.address)).to.equal(0)

        //  Check price in USD of the current RToken
        expect(await main.rTokenPrice()).to.equal(fp('1'))

        // Trigger recapitalization
        let sellAmt: BigNumber = await token0.balanceOf(main.address)
        let minBuyAmt: BigNumber = sellAmt.sub(sellAmt.div(100)) // based on trade slippage 1%

        await expect(facade.runAuctionsForAllTraders())
          .to.emit(main, 'AuctionStarted')
          .withArgs(
            0,
            collateral0.address,
            collateral1.address,
            sellAmt,
            toBNDecimals(minBuyAmt, 6)
          )

        const auctionTimestamp: number = await getLatestBlockTimestamp()

        // Check auction registered
        // Token0 -> Token1 Auction
        await expectAuctionInfo(main, 0, {
          sell: collateral0.address,
          buy: collateral1.address,
          sellAmount: sellAmt,
          minBuyAmount: toBNDecimals(minBuyAmt, 6),
          startTime: auctionTimestamp,
          endTime: auctionTimestamp + Number(config.auctionPeriod),
          clearingSellAmount: bn('0'),
          clearingBuyAmount: bn('0'),
          externalAuctionId: bn('0'),
          status: AuctionStatus.OPEN,
        })

        // Check state
        expect(await main.worstCollateralStatus()).to.equal(CollateralStatus.SOUND)
        expect(await main.fullyCapitalized()).to.equal(false)
        // Asset value is zero, everything was moved to the Market
        expect(await main.totalAssetValue()).to.equal(0)
        expect(await token0.balanceOf(main.address)).to.equal(0)
        expect(await token1.balanceOf(main.address)).to.equal(0)
        expect(await rToken.totalSupply()).to.equal(issueAmount)

        //  Check price in USD of the current RToken
        expect(await main.rTokenPrice()).to.equal(fp('1'))

        // Check Market
        expect(await token0.balanceOf(market.address)).to.equal(issueAmount)

        //  Another call should not create any new auctions if still ongoing
        await expect(facade.runAuctionsForAllTraders()).to.not.emit(main, 'AuctionStarted')

        //  expect(await main.state()).to.equal(State.TRADING)

        // Perform Mock Bids for the new Token (addr1 has balance)
        // Get fair price - all tokens
        await token1.connect(addr1).approve(market.address, toBNDecimals(sellAmt, 6))
        await market.placeBid(0, {
          bidder: addr1.address,
          sellAmount: sellAmt,
          buyAmount: toBNDecimals(sellAmt, 6),
        })

        // Advance time till auction ended
        await advanceTime(config.auctionPeriod.add(100).toString())

        //  End current auction, should  not start any new auctions
        await expect(facade.runAuctionsForAllTraders())
          .to.emit(main, 'AuctionEnded')
          .withArgs(0, collateral0.address, collateral1.address, sellAmt, toBNDecimals(sellAmt, 6))
          .and.to.not.emit(main, 'AuctionStarted')

        // Check previous auction is closed
        expectAuctionStatus(main, 0, AuctionStatus.DONE)

        // Check state - Order restablished
        expect(await main.worstCollateralStatus()).to.equal(CollateralStatus.SOUND)
        expect(await main.fullyCapitalized()).to.equal(true)
        expect(await main.totalAssetValue()).to.equal(issueAmount)
        expect(await token0.balanceOf(main.address)).to.equal(0)
        expect(await token1.balanceOf(main.address)).to.equal(toBNDecimals(issueAmount, 6))
        expect(await rToken.totalSupply()).to.equal(issueAmount)

        //  Check price in USD of the current RToken
        expect(await main.rTokenPrice()).to.equal(fp('1'))
      })

      it('Should recapitalize correctly when switching basket - Taking Haircut - No RSR', async () => {
        // Set prime basket
        await main.connect(owner).setPrimeBasket([collateral1.address], [fp('1')])

        // Set Max auction to 100% to perform it in one single auction
        await main.connect(owner).setMaxAuctionSize(fp('1'))

        // Check initial state
        expect(await main.worstCollateralStatus()).to.equal(CollateralStatus.SOUND)
        expect(await main.fullyCapitalized()).to.equal(true)
        expect(await main.totalAssetValue()).to.equal(issueAmount)
        expect(await token0.balanceOf(main.address)).to.equal(issueAmount)
        expect(await token1.balanceOf(main.address)).to.equal(0)
        expect(await rToken.totalSupply()).to.equal(issueAmount)

        //  Check price in USD of the current RToken
        expect(await main.rTokenPrice()).to.equal(fp('1'))

        // Switch Basket
        await expect(main.connect(owner).switchBasket()).to.emit(main, 'BasketSet')

        // Check state remains SOUND
        expect(await main.worstCollateralStatus()).to.equal(CollateralStatus.SOUND)
        expect(await main.fullyCapitalized()).to.equal(false)
        expect(await main.totalAssetValue()).to.equal(issueAmount)
        expect(await token0.balanceOf(main.address)).to.equal(issueAmount)
        expect(await token1.balanceOf(main.address)).to.equal(0)

        //  Check price in USD of the current RToken
        expect(await main.rTokenPrice()).to.equal(fp('1'))

        // Trigger recapitalization
        let sellAmt: BigNumber = await token0.balanceOf(main.address)
        let minBuyAmt: BigNumber = sellAmt.sub(sellAmt.div(100)) // based on trade slippage 1%

        await expect(facade.runAuctionsForAllTraders())
          .to.emit(main, 'AuctionStarted')
          .withArgs(
            0,
            collateral0.address,
            collateral1.address,
            sellAmt,
            toBNDecimals(minBuyAmt, 6)
          )

        const auctionTimestamp: number = await getLatestBlockTimestamp()

        // Check auction registered
        // Token0 -> Token1 Auction
        await expectAuctionInfo(main, 0, {
          sell: collateral0.address,
          buy: collateral1.address,
          sellAmount: sellAmt,
          minBuyAmount: toBNDecimals(minBuyAmt, 6),
          startTime: auctionTimestamp,
          endTime: auctionTimestamp + Number(config.auctionPeriod),
          clearingSellAmount: bn('0'),
          clearingBuyAmount: bn('0'),
          externalAuctionId: bn('0'),
          status: AuctionStatus.OPEN,
        })

        // Check state
        expect(await main.worstCollateralStatus()).to.equal(CollateralStatus.SOUND)
        expect(await main.fullyCapitalized()).to.equal(false)
        // Asset value is zero, everything was moved to the Market
        expect(await main.totalAssetValue()).to.equal(0)
        expect(await token0.balanceOf(main.address)).to.equal(0)
        expect(await token1.balanceOf(main.address)).to.equal(0)

        //  Check price in USD of the current RToken
        expect(await main.rTokenPrice()).to.equal(fp('1'))

        // Check Market
        expect(await token0.balanceOf(market.address)).to.equal(issueAmount)

        //  Another call should not create any new auctions if still ongoing
        await expect(facade.runAuctionsForAllTraders()).to.not.emit(main, 'AuctionStarted')

        // Perform Mock Bids for the new Token (addr1 has balance)
        // Only cover minBuyAmount - 10% less
        await token1.connect(addr1).approve(market.address, toBNDecimals(sellAmt, 6))
        await market.placeBid(0, {
          bidder: addr1.address,
          sellAmount: sellAmt,
          buyAmount: toBNDecimals(minBuyAmt, 6),
        })

        // Advance time till auction ended
        await advanceTime(config.auctionPeriod.add(100).toString())

        //  End current auction, should  not start any new auctions
        await expect(facade.runAuctionsForAllTraders())
          .to.emit(main, 'AuctionEnded')
          .withArgs(
            0,
            collateral0.address,
            collateral1.address,
            sellAmt,
            toBNDecimals(minBuyAmt, 6)
          )
          .and.to.not.emit(main, 'AuctionStarted')

        // Check previous auction is closed
        expectAuctionStatus(main, 0, AuctionStatus.DONE)

        // Check state - Haircut taken, price of RToken has been reduced
        expect(await main.worstCollateralStatus()).to.equal(CollateralStatus.SOUND)
        expect(await main.fullyCapitalized()).to.equal(true)
        expect(await main.totalAssetValue()).to.equal(minBuyAmt)
        expect(await token0.balanceOf(main.address)).to.equal(0)
        expect(await token1.balanceOf(main.address)).to.equal(toBNDecimals(minBuyAmt, 6))
        expect(await rToken.totalSupply()).to.equal(issueAmount) // Supply remains constant

        //  Check price in USD of the current RToken - Haircut of 10% taken
        expect(await main.rTokenPrice()).to.equal(fp('0.99'))
      })

      it.only('Should recapitalize correctly when switching basket - Using RSR for remainder', async () => {
        // Set prime basket
        await main.connect(owner).setPrimeBasket([collateral1.address], [fp('1')])

        // Set Max auction to 100% to perform it in one single auction
        await main.connect(owner).setMaxAuctionSize(fp('1'))

        // Check initial state
        expect(await main.worstCollateralStatus()).to.equal(CollateralStatus.SOUND)
        expect(await main.fullyCapitalized()).to.equal(true)
        expect(await main.totalAssetValue()).to.equal(issueAmount)
        expect(await token0.balanceOf(main.address)).to.equal(issueAmount)
        expect(await token1.balanceOf(main.address)).to.equal(0)
        expect(await rToken.totalSupply()).to.equal(issueAmount)

        //  Check price in USD of the current RToken
        expect(await main.rTokenPrice()).to.equal(fp('1'))

        // Perform stake
        const stkAmount: BigNumber = bn('100e18')
        await rsr.connect(addr1).approve(stRSR.address, stkAmount)
        await stRSR.connect(addr1).stake(stkAmount)

        // Check stakes
        expect(await rsr.balanceOf(stRSR.address)).to.equal(stkAmount)
        expect(await stRSR.balanceOf(addr1.address)).to.equal(stkAmount)

        // Switch Basket
        await expect(main.connect(owner).switchBasket()).to.emit(main, 'BasketSet')

        // Check state remains SOUND
        expect(await main.worstCollateralStatus()).to.equal(CollateralStatus.SOUND)
        expect(await main.fullyCapitalized()).to.equal(false)
        expect(await main.totalAssetValue()).to.equal(issueAmount)
        expect(await token0.balanceOf(main.address)).to.equal(issueAmount)
        expect(await token1.balanceOf(main.address)).to.equal(0)
        expect(await rToken.totalSupply()).to.equal(issueAmount)

        //  Check price in USD of the current RToken
        expect(await main.rTokenPrice()).to.equal(fp('1'))

        // Trigger recapitalization
        let sellAmt: BigNumber = await token0.balanceOf(main.address)
        let minBuyAmt: BigNumber = sellAmt.sub(sellAmt.div(100)) // based on trade slippage 1%

        await expect(facade.runAuctionsForAllTraders())
          .to.emit(main, 'AuctionStarted')
          .withArgs(
            0,
            collateral0.address,
            collateral1.address,
            sellAmt,
            toBNDecimals(minBuyAmt, 6)
          )

        let auctionTimestamp: number = await getLatestBlockTimestamp()

        // Check auction registered
        // Token0 -> Token1 Auction
        await expectAuctionInfo(main, 0, {
          sell: collateral0.address,
          buy: collateral1.address,
          sellAmount: sellAmt,
          minBuyAmount: toBNDecimals(minBuyAmt, 6),
          startTime: auctionTimestamp,
          endTime: auctionTimestamp + Number(config.auctionPeriod),
          clearingSellAmount: bn('0'),
          clearingBuyAmount: bn('0'),
          externalAuctionId: bn('0'),
          status: AuctionStatus.OPEN,
        })

        // Check state
        expect(await main.worstCollateralStatus()).to.equal(CollateralStatus.SOUND)
        expect(await main.fullyCapitalized()).to.equal(false)
        // Asset value is zero, everything was moved to the Market
        expect(await main.totalAssetValue()).to.equal(0)
        expect(await token0.balanceOf(main.address)).to.equal(0)
        expect(await token1.balanceOf(main.address)).to.equal(0)
        expect(await rToken.totalSupply()).to.equal(issueAmount)

        //  Check price in USD of the current RToken
        expect(await main.rTokenPrice()).to.equal(fp('1'))

        // Check Market
        expect(await token0.balanceOf(market.address)).to.equal(issueAmount)

        //  Another call should not create any new auctions if still ongoing
        await expect(facade.runAuctionsForAllTraders()).to.not.emit(main, 'AuctionStarted')

        // Perform Mock Bids for the new Token (addr1 has balance)
        // Get fair price - minBuyAmt
        await token1.connect(addr1).approve(market.address, toBNDecimals(sellAmt, 6))
        await market.placeBid(0, {
          bidder: addr1.address,
          sellAmount: sellAmt,
          buyAmount: toBNDecimals(minBuyAmt, 6),
        })

        // Advance time till auction ended
        await advanceTime(config.auctionPeriod.add(100).toString())

        // End current auction, should start a new one to sell RSR for collateral
        // Only 1e18 Tokens left to buy - Sets Buy amount as independent value
        let buyAmtBidRSR: BigNumber = sellAmt.sub(minBuyAmt)
        let sellAmtRSR: BigNumber = buyAmtBidRSR.mul(BN_SCALE_FACTOR).div(fp('0.99')) // Due to trade slippage 1% - Calculation to match Solidity

        await expect(facade.runAuctionsForAllTraders())
          .to.emit(main, 'AuctionEnded')
          .withArgs(
            0,
            collateral0.address,
            collateral1.address,
            sellAmt,
            toBNDecimals(minBuyAmt, 6)
          )
          .and.to.emit(main, 'AuctionStarted')
          .withArgs(
            1,
            rsrAsset.address,
            collateral1.address,
            sellAmtRSR,
            toBNDecimals(buyAmtBidRSR, 6)
          )

        // Check previous auction is closed
        expectAuctionStatus(main, 0, AuctionStatus.DONE)

        auctionTimestamp = await getLatestBlockTimestamp()

        // RSR -> Token1 Auction
        await expectAuctionInfo(main, 1, {
          sell: rsrAsset.address,
          buy: collateral1.address,
          sellAmount: sellAmtRSR,
          minBuyAmount: toBNDecimals(buyAmtBidRSR, 6),
          startTime: auctionTimestamp,
          endTime: auctionTimestamp + Number(config.auctionPeriod),
          clearingSellAmount: bn('0'),
          clearingBuyAmount: bn('0'),
          externalAuctionId: bn('1'),
          status: AuctionStatus.OPEN,
        })

        // Check state
        expect(await main.worstCollateralStatus()).to.equal(CollateralStatus.SOUND)
        expect(await main.fullyCapitalized()).to.equal(false)
        expect(await token0.balanceOf(main.address)).to.equal(0)
        expect(await token1.balanceOf(main.address)).to.equal(toBNDecimals(minBuyAmt, 6))
        expect(await rToken.totalSupply()).to.equal(issueAmount)

        //  Check price in USD of the current RToken
        expect(await main.rTokenPrice()).to.equal(fp('1'))

        // Check Market
        expect(await rsr.balanceOf(market.address)).to.equal(sellAmtRSR)

        //  Another call should not create any new auctions if still ongoing
        await expect(facade.runAuctionsForAllTraders()).to.not.emit(main, 'AuctionStarted')

        // Perform Mock Bids for the new Token (addr1 has balance)
        // Cover buyAmtBidRSR which is all the RSR required
        await token1.connect(addr1).approve(market.address, toBNDecimals(sellAmtRSR, 6))
        await market.placeBid(1, {
          bidder: addr1.address,
          sellAmount: sellAmtRSR,
          buyAmount: toBNDecimals(buyAmtBidRSR, 6),
        })

        // Advance time till auction ended
        await advanceTime(config.auctionPeriod.add(100).toString())

        //  End current auction, should  not start any new auctions
        await expect(facade.runAuctionsForAllTraders())
          .to.emit(main, 'AuctionEnded')
          .withArgs(
            1,
            rsrAsset.address,
            collateral1.address,
            sellAmtRSR,
            toBNDecimals(buyAmtBidRSR, 6)
          )
          .and.to.not.emit(main, 'AuctionStarted')

        // Check previous auction is closed
        expectAuctionStatus(main, 1, AuctionStatus.DONE)

        // Check state - Order restablished
        expect(await main.worstCollateralStatus()).to.equal(CollateralStatus.SOUND)
        expect(await main.fullyCapitalized()).to.equal(true)
        expect(await token0.balanceOf(main.address)).to.equal(0)
        expect(await token1.balanceOf(main.address)).to.equal(toBNDecimals(issueAmount, 6))
        expect(await rToken.totalSupply()).to.equal(issueAmount)

        //  Check price in USD of the current RToken
        expect(await main.rTokenPrice()).to.equal(fp('1'))
      })
    })
  })
})
