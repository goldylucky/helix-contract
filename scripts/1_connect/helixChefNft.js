/* 
 * @dev Used to (re)initialize Helix Chef Nft
 * 
 * Run from project root using:
 *     npx hardhat run scripts/1_connect/helixChefNft.js --network ropsten
 */

const verbose = true

const { ethers } = require(`hardhat`);
const { print } = require("../shared/utilities")
const { connectHelixChefNft } = require("../shared/connect")

async function main() {
    const [wallet] = await ethers.getSigners()
    await connectHelixChefNft(wallet)
    print('done')
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error)
        process.exit(1)
    })
