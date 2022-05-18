/**
 * @dev Verify the deplyed HELIX Token contract
 *
 * command for verify on bsc-testnet: 
 * 
 *      npx hardhat run scripts/verifyHelixToken.js --network testnetBSC
 *      npx hardhat run scripts/verifyHelixToken.js --network mainnetETH
 */

const hre = require('hardhat');
const env = require('./constants/env')

const contracts = require('./constants/contracts')

// deployed contract address
const helixTokenAddress = contracts.helixToken[env.network]

async function main() {
    console.log(`Verify Helix Token contract ${helixTokenAddress}`);
    await hre.run("verify:verify", { address: helixTokenAddress, constructorArguments: [] })
    console.log('done');
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
