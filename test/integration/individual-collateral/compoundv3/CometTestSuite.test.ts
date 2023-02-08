import collateralTests, { CollateralFixtureContext, CollateralOpts, MintCollateralFunc, CollateralStatus } from "../collateralTests";
import { ethers } from 'hardhat'
import { Fixture } from 'ethereum-waffle'
import { ContractFactory, BigNumberish } from 'ethers'
import {
  ERC20Mock,
  CTokenV3Collateral,
  MockV3Aggregator,
  CometInterface,
  CusdcV3Wrapper,
  CusdcV3Wrapper__factory,
  MockV3Aggregator__factory,
  CometMock,
  CometMock__factory,
  ICollateral
} from '../../../../typechain'
import { bn, fp } from '../../../../common/numbers'
import { MAX_UINT48 } from '../../../../common/constants'
import { whileImpersonating } from '../../../utils/impersonation'
import { expect } from 'chai'
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import {
  advanceTime,
  advanceBlocks,
  getLatestBlockTimestamp,
  setNextBlockTimestamp,
} from '../../../utils/time'

/*
  Define constants
*/

// Mainnet Addresses
export const RSR = '0x320623b8e4ff03373931769a31fc52a4e78b5d70'
export const USDC_USD_PRICE_FEED = '0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6'
export const CUSDC_V3 = '0xc3d688B66703497DAA19211EEdff47f25384cdc3'
export const COMP = '0xc00e94Cb662C3520282E6f5717214004A7f26888'
export const REWARDS = '0x1B0e765F6224C21223AeA2af16c1C46E38885a40'
export const USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'
export const USDC_HOLDER = '0x0a59649758aa4d66e25f08dd01271e891fe52199'
export const COMET_CONFIGURATOR = '0x316f9708bB98af7dA9c68C1C3b5e79039cD336E3'
export const COMET_PROXY_ADMIN = '0x1EC63B5883C3481134FD50D5DAebc83Ecd2E8779'

export const ORACLE_TIMEOUT = bn(86400) // 24 hours in seconds
export const ORACLE_ERROR = fp('0.005')
export const DEFAULT_THRESHOLD = bn(5).mul(bn(10).pow(16)) // 0.05
export const DELAY_UNTIL_DEFAULT = bn(86400)
export const MAX_TRADE_VOL = bn(1000000)
export const USDC_DECIMALS = bn(6)

const COLLATERAL_TOKEN_ADDRESS = CUSDC_V3
const oracleError = ORACLE_ERROR



/*
  Define interfaces
*/

interface CometCollateralFixtureContext extends CollateralFixtureContext {
  cusdcV3: CometInterface
  wcusdcV3: CusdcV3Wrapper
  usdc: ERC20Mock
}

interface CometCollateralFixtureContextMockComet extends CollateralFixtureContext {
  cusdcV3: CometMock
  wcusdcV3: CusdcV3Wrapper
  usdc: ERC20Mock
}

interface CometCollateralOpts extends CollateralOpts {
  reservesThresholdIffy?: BigNumberish
  reservesThresholdDisabled?: BigNumberish
}

interface WrappedcUSDCFixture {
  cusdcV3: CometInterface
  wcusdcV3: CusdcV3Wrapper
  usdc: ERC20Mock
}


// interface MintCollateralFunc {
//   <T>(ctx: T extends CollateralFixtureContext, amount: BigNumberish, user: SignerWithAddress): void;
// }

// type MintCollateralFunc<T> = (ctx: T extends CollateralFixtureContext, amount: BigNumberish, user: SignerWithAddress): void;


/*
  Define deployment functions
*/

export const defaultCometCollateralOpts: CometCollateralOpts = {
    erc20: CUSDC_V3,
    targetName: ethers.utils.formatBytes32String('USD'),
    rewardERC20: COMP,
    priceTimeout: ORACLE_TIMEOUT,
    chainlinkFeed: USDC_USD_PRICE_FEED,
    oracleTimeout: ORACLE_TIMEOUT,
    oracleError: ORACLE_ERROR,
    maxTradeVolume: MAX_TRADE_VOL,
    defaultThreshold: DEFAULT_THRESHOLD,
    delayUntilDefault: DELAY_UNTIL_DEFAULT,
    reservesThresholdIffy: bn('10000'),
    reservesThresholdDisabled: bn('5000'),
}

export const deployCollateral = async (opts: CometCollateralOpts = {}): Promise<ICollateral> => {
  opts = { ...defaultCometCollateralOpts, ...opts }

  const CTokenV3CollateralFactory: ContractFactory = await ethers.getContractFactory(
    'CTokenV3Collateral'
  )

  const collateral = <ICollateral>await CTokenV3CollateralFactory.deploy(
    {
      erc20: opts.erc20,
      targetName: opts.targetName,
      priceTimeout: opts.priceTimeout,
      chainlinkFeed: opts.chainlinkFeed,
      oracleError: opts.oracleError,
      oracleTimeout: opts.oracleTimeout,
      maxTradeVolume: opts.maxTradeVolume,
      defaultThreshold: opts.defaultThreshold,
      delayUntilDefault: opts.delayUntilDefault,
    },
    {
      rewardERC20: opts.rewardERC20,
      reservesThresholdIffy: opts.reservesThresholdIffy,
      reservesThresholdDisabled: opts.reservesThresholdDisabled,
    },
    0,
    {gasLimit: 2000000000}
  )
  await collateral.deployed()

  return collateral
}

export const makewCSUDC = async (): Promise<WrappedcUSDCFixture> => {
  const cusdcV3 = <CometInterface>await ethers.getContractAt('CometInterface', CUSDC_V3)
  const CusdcV3WrapperFactory = <CusdcV3Wrapper__factory>(
    await ethers.getContractFactory('CusdcV3Wrapper')
  )
  const wcusdcV3 = <CusdcV3Wrapper>(
    await CusdcV3WrapperFactory.deploy(cusdcV3.address, REWARDS, COMP)
  )
  const usdc = <ERC20Mock>await ethers.getContractAt('ERC20Mock', USDC)

  return { cusdcV3, wcusdcV3, usdc }
}

export const makeCollateralFixtureContext = (alice: SignerWithAddress, opts: CometCollateralOpts = {}): Fixture<CometCollateralFixtureContext> => {
  const collateralOpts = { ...defaultCometCollateralOpts, ...opts }

  const makeCollateralFixtureContext = async () => {
    const MockV3AggregatorFactory = <MockV3Aggregator__factory>(
      await ethers.getContractFactory('MockV3Aggregator')
    )

    const chainlinkFeed = <MockV3Aggregator>await MockV3AggregatorFactory.deploy(6, bn('1e6'))
    collateralOpts.chainlinkFeed = chainlinkFeed.address

    const fix = await makewCSUDC()
    const cusdcV3 = <CometInterface>fix.cusdcV3
    const { wcusdcV3, usdc } = fix

    collateralOpts.erc20 = wcusdcV3.address

    const collateral = await deployCollateral(collateralOpts)
    return { alice, collateral, chainlinkFeed, cusdcV3, wcusdcV3, usdc, tok: wcusdcV3 }
  }

  return makeCollateralFixtureContext
}

export const deployCollateralCometMockContext = async (
  opts: CometCollateralOpts = {}
): Promise<CometCollateralFixtureContextMockComet> => {
  const collateralOpts = { ...defaultCometCollateralOpts, ...opts }

  const MockV3AggregatorFactory = <MockV3Aggregator__factory>(
    await ethers.getContractFactory('MockV3Aggregator')
  )
  const chainlinkFeed = <MockV3Aggregator>await MockV3AggregatorFactory.deploy(6, bn('1e6'))
  collateralOpts.chainlinkFeed = chainlinkFeed.address

  const CometFactory = <CometMock__factory>await ethers.getContractFactory('CometMock')
  const cusdcV3 = <CometMock>await CometFactory.deploy(bn('5e15'), bn('1e15'))

  const CusdcV3WrapperFactory = <CusdcV3Wrapper__factory>(
    await ethers.getContractFactory('CusdcV3Wrapper')
  )
  const wcusdcV3 = <CusdcV3Wrapper>(
    await CusdcV3WrapperFactory.deploy(cusdcV3.address, REWARDS, COMP)
  )
  collateralOpts.erc20 = wcusdcV3.address
  const usdc = <ERC20Mock>await ethers.getContractAt('ERC20Mock', USDC)
  const collateral = await deployCollateral(collateralOpts)
  return { collateral, chainlinkFeed, cusdcV3, wcusdcV3, usdc, tok: wcusdcV3 }
}




/*
  Define helper functions
*/

export const allocateERC20 = async (
    token: ERC20Mock,
    from: string,
    to: string,
    balance: BigNumberish
) => {
    await whileImpersonating(from, async (signer) => {
      await token.connect(signer).transfer(to, balance)
    })
}
  
export const allocateUSDC = async (
    to: string,
    balance: BigNumberish,
    from: string = USDC_HOLDER,
    token: string = USDC
  ) => {
    const usdc = await ethers.getContractAt('ERC20Mock', token)
    await allocateERC20(usdc, from, to, balance)
}

export const mintCollateralTo = async (ctx: CometCollateralFixtureContext, amount: BigNumberish, user: SignerWithAddress) => {
    await allocateUSDC(user.address, amount)
    await ctx.usdc.connect(user).approve(ctx.cusdcV3.address, ethers.constants.MaxUint256)
    await ctx.cusdcV3.connect(user).supply(ctx.usdc.address, amount)
    await ctx.cusdcV3.connect(user).allow(ctx.wcusdcV3.address, true)
    await ctx.wcusdcV3.connect(user).depositTo(user.address, ethers.constants.MaxUint256)
}

const reduceRefPerTok = async (ctx: CometCollateralFixtureContext) => {
  await ctx.wcusdcV3.connect(ctx.alice as SignerWithAddress).withdraw(bn('19900e6'))
}

/*
  Define collateral-specific tests
*/

const collateralSpecificConstructorTests = () => {
  it('does not allow 0 reservesThresholdIffy', async () => {
    await expect(
      deployCollateral({ erc20: CUSDC_V3, reservesThresholdIffy: 0 })
    ).to.be.revertedWith('reservesThresholdIffy zero')
  })

  it('does not allow 0 reservesThresholdDisabled', async () => {
    await expect(
      deployCollateral({ erc20: CUSDC_V3, reservesThresholdDisabled: 0 })
    ).to.be.revertedWith('reservesThresholdDisabled zero')
  })
}

const collateralSpecificStatusTests = () => {
  it('enters DISABLED state if reserves go negative', async () => {
    const mockOpts = { reservesThresholdDisabled: 1000n }
    const { collateral, cusdcV3 } = await deployCollateralCometMockContext(mockOpts)

    // Check initial state
    expect(await collateral.status()).to.equal(CollateralStatus.SOUND)
    expect(await collateral.whenDefault()).to.equal(MAX_UINT48)

    // cUSDC/Comet's reserves gone down to 19% of target reserves
    await cusdcV3.setReserves(-1)

    await expect(collateral.refresh()).to.emit(collateral, 'CollateralStatusChanged')
    // State remains the same
    expect(await collateral.status()).to.equal(CollateralStatus.DISABLED)
    expect(await collateral.whenDefault()).to.equal(await getLatestBlockTimestamp())
  })

  it('soft-defaults when compound reserves are below target reserves iffy threshold', async () => {
    const mockOpts = { reservesThresholdIffy: 5000n, reservesThresholdDisabled: 1000n }
    const { collateral, cusdcV3 } = await deployCollateralCometMockContext(mockOpts)
    const delayUntilDefault = await collateral.delayUntilDefault()

    // Check initial state
    await expect(collateral.refresh()).to.not.emit(collateral, 'CollateralStatusChanged')
    expect(await collateral.status()).to.equal(CollateralStatus.SOUND)
    expect(await collateral.whenDefault()).to.equal(MAX_UINT48)

    // cUSDC/Comet's reserves gone down below reservesThresholdIffy
    await cusdcV3.setReserves(4000n)

    const nextBlockTimestamp = (await getLatestBlockTimestamp()) + 1
    await setNextBlockTimestamp(nextBlockTimestamp)
    const expectedDefaultTimestamp = nextBlockTimestamp + delayUntilDefault

    await expect(collateral.refresh())
      .to.emit(collateral, 'CollateralStatusChanged')
      .withArgs(CollateralStatus.SOUND, CollateralStatus.IFFY)
    expect(await collateral.status()).to.equal(CollateralStatus.IFFY)
    expect(await collateral.whenDefault()).to.equal(expectedDefaultTimestamp)

    // Move time forward past delayUntilDefault
    await advanceTime(delayUntilDefault)
    expect(await collateral.status()).to.equal(CollateralStatus.DISABLED)

    // Nothing changes if attempt to refresh after default for CTokenV3
    const prevWhenDefault: bigint = (await collateral.whenDefault()).toBigInt()
    await expect(collateral.refresh()).to.not.emit(collateral, 'CollateralStatusChanged')
    expect(await collateral.status()).to.equal(CollateralStatus.DISABLED)
    expect(await collateral.whenDefault()).to.equal(prevWhenDefault)
  })

  it('hard-defaults when reserves threshold is at disabled levels', async () => {
    const mockOpts = { reservesThresholdDisabled: 1000n }
    const { collateral, cusdcV3 } = await deployCollateralCometMockContext( mockOpts)

    // Check initial state
    expect(await collateral.status()).to.equal(CollateralStatus.SOUND)
    expect(await collateral.whenDefault()).to.equal(MAX_UINT48)

    // cUSDC/Comet's reserves gone down to 19% of target reserves
    await cusdcV3.setReserves(900n)

    await expect(collateral.refresh()).to.emit(collateral, 'CollateralStatusChanged')
    // State remains the same
    expect(await collateral.status()).to.equal(CollateralStatus.DISABLED)
    expect(await collateral.whenDefault()).to.equal(await getLatestBlockTimestamp())
  })
}



/*
  Run the test suite
*/

const opts = {
    oracleError,
    deployCollateral,
    collateralSpecificConstructorTests,
    collateralSpecificStatusTests,
    makeCollateralFixtureContext,
    mintCollateralTo,
    reduceRefPerTok
}

collateralTests(opts)