import { ethers } from "hardhat"
import { expect } from "chai"
import { BigNumber } from "ethers"
import { ZERO, bn, pow10 } from "../../common/numbers"
import { Address, Simulation, Token } from "./interface"
import { Implementation0 } from "./implementations/0"
import { EVMImplementation } from "./implementations/evm"

/*
 * Simulation Test Harness
 *
 * How this works:
 * - Tests are written against the simulation interface definitions in `interface.ts`.
 * - Accounts should be represented and referred to using the `Address` type.
 * - The simulation interface re-uses the `*.connect` pattern to set tx originators.
 * - The `both` helper function is used to run and compare individual test results across implementations.
 * - The function passed to `both` should return an object containing all relevant state for comparison.
 */

describe("Simulation", function () {
    let sim1: Simulation
    let sim2: Simulation
    let owner: Address
    let addr1: Address
    let tokens: Token[]

    // Runs the same function on two implementations of our protocol and compares the results.
    async function both(func: Function, ...args: any[]): Promise<void> {
        const res1 = await func(sim1, ...args)
        const res2 = await func(sim2, ...args)
        for (const key in res1) {
            expect(res2[key]).to.equal(res1[key])
        }
    }

    beforeEach(async function () {
        tokens = [
            { name: "DAI", symbol: "DAI", quantityE18: bn(333334).mul(pow10(12)) },
            { name: "TUSD", symbol: "TUSD", quantityE18: bn(333333).mul(pow10(12)) },
            { name: "USDC", symbol: "USDC", quantityE18: bn(333333) }, // 6 decimals
        ]
        const result = await ethers.getSigners()
        owner = result[0].address
        addr1 = result[1].address
        sim1 = new Implementation0(owner, "RToken", "RSV", tokens)
        sim2 = await new EVMImplementation().create(result[0], "RToken", "RSV", tokens)
    })

    describe("RToken", function () {
        let amount: BigNumber

        beforeEach(async function () {
            amount = pow10(21)

            await both(async function (sim: Simulation) {
                await sim.rToken.basketERC20(0).connect(owner).mint(owner, amount)
                await sim.rToken.basketERC20(1).connect(owner).mint(owner, amount)
                await sim.rToken.basketERC20(2).connect(owner).mint(owner, amount)
                await sim.rToken.connect(owner).issue(amount)
            })
        })

        it("Should allow issuance", async function () {
            await both(async function (sim: Simulation) {
                return {
                    rToken: await sim.rToken.balanceOf(owner),
                    token1: await sim.rToken.basketERC20(0).balanceOf(owner),
                    token2: await sim.rToken.basketERC20(1).balanceOf(owner),
                    token3: await sim.rToken.basketERC20(2).balanceOf(owner),
                }
            })
        })

        it("Should allow redemption", async function () {
            await both(async function (sim: Simulation) {
                await sim.rToken.connect(owner).redeem(amount)
                return {
                    rToken: await sim.rToken.balanceOf(owner),
                    token1: await sim.rToken.basketERC20(0).balanceOf(owner),
                    token2: await sim.rToken.basketERC20(1).balanceOf(owner),
                    token3: await sim.rToken.basketERC20(2).balanceOf(owner),
                }
            })
        })

        it("Should allow transfer", async function () {
            await both(async function (sim: Simulation) {
                await sim.rToken.connect(owner).transfer(addr1, amount)
                return {
                    ownerBal: await sim.rToken.balanceOf(owner),
                    addr1Bal: await sim.rToken.balanceOf(addr1),
                }
            })
        })
    })
})
