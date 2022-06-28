// This script exports "deploy" functions which are used to deploy contracts

const { deployOwnerMultiSig } = require("./ownerMultiSig")
const { deployTreasuryMultiSig } = require("./treasuryMultiSig")
const { deployDevTeamMultiSig } = require("./devTeamMultiSig")
const { deployTimelock } = require("./timelock")

module.exports = {
    deployOwnerMultiSig,
    deployTreasuryMultiSig,
    deployDevTeamMultiSig,
    deployTimelock,
}
