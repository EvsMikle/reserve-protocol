/* eslint-disable no-process-exit */
import hre from 'hardhat'
import { exec } from 'child_process'
import { getChainId } from '../common/blockchain-utils'
import { networkConfig } from '../common/configuration'

async function sh(cmd: string) {
  return new Promise(function (resolve, reject) {
    const execProcess = exec(cmd, (err, stdout, stderr) => {
      if (err) {
        if (cmd.indexOf('verify') >= 0) console.log('already verified, skipping...')
        else reject(err)
      } else {
        resolve({ stdout, stderr })
      }
    })

    execProcess.stdout?.pipe(process.stdout)
  })
}

async function main() {
  const [deployer] = await hre.ethers.getSigners()
  const chainId = await getChainId(hre)

  // Check if chain is supported
  if (!networkConfig[chainId]) {
    throw new Error(`Missing network configuration for ${hre.network.name}`)
  }

  console.log(`Starting full deployment on network ${hre.network.name} (${chainId})`)
  console.log(`Deployer account: ${deployer.address}\n`)

  // Part 1: Deploy and verify all contracts

  const allScripts = [
    'phase1-common/0_setup_deployments.ts',
    'phase1-common/1_deploy_libraries.ts',
    'phase1-common/2_verify_libraries.ts',
    'phase1-common/3_deploy_implementations.ts',
    'phase1-common/4_verify_implementations.ts',
    'phase1-common/5_deploy_rsrAsset.ts',
    'phase1-common/6_verify_rsrAsset.ts',
    'phase1-common/7_deploy_facade.ts',
    'phase1-common/8_verify_facade.ts',
    'phase1-common/9_deploy_deployer.ts',
    'phase1-common/10_verify_deployer.ts',
    'phase1-common/11_deploy_facadeWrite.ts',
    'phase1-common/12_verify_facadeWrite.ts',
    'phase2-assets/0_setup_deployments.ts',
    'phase2-assets/1_deploy_assets.ts',
    'phase2-assets/2_deploy_collateral.ts',
    'phase3-rtoken/0_setup_deployments.ts',
    'phase3-rtoken/1_deploy_rtoken.ts',
    'phase3-rtoken/2_setup_governance.ts',
    'phase3-rtoken/3_verify_rtoken.ts',
    'phase3-rtoken/4_verify_governance.ts',
  ]

  for (const script of allScripts) {
    console.log(
      '\n===========================================\n',
      script,
      '\n===========================================\n'
    )

    if (script.indexOf('verify') >= 0) {
      console.log('\n', 'sleeping 30s before verification...', '\n')

      // Sleep
      await new Promise((r) => setTimeout(r, 30000))
    }

    await sh(`hardhat run scripts/deployment/${script}`)
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
