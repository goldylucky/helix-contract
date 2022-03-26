/**
 * @dev Master Chef Deployment
 *
 * command for deploy on bsc-testnet: 
 * 
 *      npx hardhat run scripts/5_deployMasterChef.js --network testnetBSC
 *       
 * Workflow:
 * 
 *      1. Deploy `MasterChef` contract.
 *      2. Add `MasterChef` as minter to `HelixToken`
 */
const { ethers, network } = require(`hardhat`);
const contracts = require("./constants/contracts")
const addresses = require("./constants/addresses")
const initials = require("./constants/initials")
const env = require("./constants/env")

const HelixTokenAddress = contracts.helixToken[env.network];
const ReferralRegister = contracts.referralRegister[env.network];
const DeveloperAddress = addresses.masterChefDeveloper[env.network];
const StartBlock = initials.MASTERCHEF_START_BLOCK[env.network];
const HelixTokenRewardPerBlock = initials.MASTERCHEF_HELIX_TOKEN_REWARD_PER_BLOCK[env.network];
const StakingPercent = initials.MASTERCHEF_STAKING_PERCENT[env.network];
const DevPercent = initials.MASTERCHEF_DEV_PERCENT[env.network];

async function main() {

    const [deployer] = await ethers.getSigners();
    console.log(`Deployer address: ${ deployer.address}`);
    
    let nonce = await network.provider.send(`eth_getTransactionCount`, [deployer.address, "latest"]);
    
    if (DevPercent + StakingPercent != 1000000) {
        console.log('DevPercent + StakingPercent != 1000000');
        return;
    }

    console.log(`------ Start deploying Master Chef contract ---------`);
    const MasterChef = await ethers.getContractFactory(`MasterChef`);
    chef = await MasterChef.deploy(
    /*helix token address=*/HelixTokenAddress,
    /*dev address=*/DeveloperAddress,
    /*helix token per block=*/HelixTokenRewardPerBlock,
    /*start block=*/StartBlock,
    /*staking percent=*/StakingPercent,
    /*dev percent=*/DevPercent,
    /*ref=*/ ReferralRegister, 
    {nonce: nonce});
    await chef.deployTransaction.wait();
    console.log(`Master Chef deployed to ${chef.address}`);

    console.log(`------ Add MasterChef as Minter to HelixToken ---------`);
    const HelixToken = await ethers.getContractFactory(`HelixToken`);
    const helixToken = HelixToken.attach(HelixTokenAddress);

    let tx = await helixToken.addMinter(chef.address, {nonce: ++nonce, gasLimit: 3000000});
    await tx.wait();
    console.log(`Done!`)
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
