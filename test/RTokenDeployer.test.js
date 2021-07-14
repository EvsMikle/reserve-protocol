const { expect } = require("chai");
const { expectInReceipt } = require("./utils/events");
const { ZERO_ADDRESS } = require("./utils/constants");

describe("RTokenDeployer contract", function () {
    beforeEach(async function () {
        [owner, newOwner, other] = await ethers.getSigners();

        // Deploy RToken and InsurancePool implementations
        RToken = await ethers.getContractFactory("RToken");
        rTokenImplementation = await RToken.connect(owner).deploy();

        InsurancePool = await ethers.getContractFactory("InsurancePool");
        iPoolImplementation = await InsurancePool.connect(owner).deploy();

        // Deploy RTokenFactory
        RTokenFactory = await ethers.getContractFactory("RTokenDeployer");
        factory = await RTokenFactory.connect(owner).deploy(rTokenImplementation.address, iPoolImplementation.address);
    });

    describe("Deployment", function () {
        it("Should start with the correct implementations defined", async function () {
            expect(await factory.rTokenImplementation()).to.equal(rTokenImplementation.address);
            expect(await factory.insurancePoolImplementation()).to.equal(iPoolImplementation.address);
        });
    });

    describe("Creating Rtokens", function () {
        beforeEach(async function () {
            // RToken Configuration and setup
            config = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, ZERO_ADDRESS, ZERO_ADDRESS, ZERO_ADDRESS, ZERO_ADDRESS, ZERO_ADDRESS];
            basketTokens = [[ZERO_ADDRESS, 0, 0, 0, 0, 0, 0]];
            // RSR (Insurance token)
            PrevRSR = await ethers.getContractFactory("ReserveRightsTokenMock");
            NewRSR = await ethers.getContractFactory("RSR");
            prevRSRToken = await PrevRSR.deploy("Reserve Rights", "RSR");
            rsrToken = await NewRSR.connect(owner).deploy(prevRSRToken.address, ZERO_ADDRESS, ZERO_ADDRESS);
            rsrTokenInfo = [rsrToken.address, 0, 0, 0, 0, 0, 0];

            // Create a new RToken
            receipt = await (await factory.deploy(newOwner.address, 'RToken Test', 'RTKN', config, basketTokens, rsrTokenInfo)).wait();
            tokenAddress = (expectInReceipt(receipt, 'RTokenDeployed')).args.rToken;
        });

        it("Should deploy RToken and Insurance Pool correctly", async function () {
            const RToken = await ethers.getContractFactory('RToken');
            const rTokenInstance = await RToken.attach(tokenAddress);
            expect(await rTokenInstance.name()).to.equal('RToken Test');
            expect(await rTokenInstance.symbol()).to.equal('RTKN');
            expect(await rTokenInstance.totalSupply()).to.equal(0);

            // Check Insurance Pool
            const iPoolAddress = await rTokenInstance.insurancePool()
            const iPoolInstance = await InsurancePool.attach(iPoolAddress);
            expect(iPoolAddress).to.not.equal(iPoolImplementation.address);
            expect(tokenAddress).to.not.equal(rTokenImplementation.address);
            expect(await iPoolInstance.rToken()).to.equal(tokenAddress);
            expect(await iPoolInstance.rsrToken()).to.equal(rsrToken.address);
        });

        it("Should setup owner for RToken correctly", async function () {
            const RToken = await ethers.getContractFactory('RToken');
            const rTokenInstance = await RToken.attach(tokenAddress);
            expect(await rTokenInstance.owner()).to.equal(newOwner.address);
        });

        it('Should track tokens created by the factory', async () => {
            expect(await factory.isRToken(tokenAddress)).to.be.true;
        });

        it('Should not track tokens that were not created by the factory', async () => {
            expect(await factory.isRToken(other.address)).to.be.false;
        });
    });

    describe("Upgradeability", function () {
        beforeEach(async function () {
            // RToken Configuration and setup
            config = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, ZERO_ADDRESS, ZERO_ADDRESS, ZERO_ADDRESS, ZERO_ADDRESS, ZERO_ADDRESS];
            basketTokens = [[ZERO_ADDRESS, 0, 0, 0, 0, 0, 0]];
            // RSR (Insurance token)
            PrevRSR = await ethers.getContractFactory("ReserveRightsTokenMock");
            NewRSR = await ethers.getContractFactory("RSR");
            prevRSRToken = await PrevRSR.deploy("Reserve Rights", "RSR");
            rsrToken = await NewRSR.connect(owner).deploy(prevRSRToken.address, ZERO_ADDRESS, ZERO_ADDRESS);
            rsrTokenInfo = [rsrToken.address, 0, 0, 0, 0, 0, 0];

            // Create a new RToken
            receipt = await (await factory.deploy(newOwner.address, 'RToken Test', 'RTKN', config, basketTokens, rsrTokenInfo)).wait();
            tokenAddress = (expectInReceipt(receipt, 'RTokenDeployed')).args.rToken;
        });

        it("Should allow upgrades in RToken if Owner", async function () {
            const RToken = await ethers.getContractFactory('RToken');
            const rTokenInstance = await RToken.attach(tokenAddress);
          
            // Deploy new RToken Implementation
            RTokenV2 = await ethers.getContractFactory("RTokenMockV2");
            rTokenV2Implementation = await RTokenV2.connect(owner).deploy();

            // Update implementation
            await rTokenInstance.connect(newOwner).upgradeTo(rTokenV2Implementation.address);

            //Check if new version is now being used
            const rTokenInstanceV2 = await RTokenV2.attach(tokenAddress);
            expect(await rTokenInstanceV2.getVersion()).to.equal("V2");
        });

        it("Should not allow upgrades in RToken if not Owner", async function () {
            const RToken = await ethers.getContractFactory('RToken');
            const rTokenInstance = await RToken.attach(tokenAddress);
          
            // Deploy new RToken Implementation
            RTokenV2 = await ethers.getContractFactory("RTokenMockV2");
            rTokenV2Implementation = await RTokenV2.connect(owner).deploy();

            // Try to update implementation
            await expect(
                rTokenInstance.connect(other).upgradeTo(rTokenV2Implementation.address)
            ).to.be.revertedWith("Ownable: caller is not the owner");
        });
    });
});
