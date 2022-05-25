// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.0;

import "../tokens/HelixNFT.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * HelixNFTBridge is responsible for many things related to NFT Bridging from-/to-
 * Solana blockchain. Here's the full list:
 *  - allow Solana NFT to be minted on BSC (bridgeFromSolana)
 */
contract HelixNFTBridge is Ownable, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /**
     * @dev If the NFT is available on the BSC, then this map stores true
     * for the externalID, false otherwise.
     */
    mapping(string => bool) private _bridgedExternalTokenIDs;

    /**
     * @dev If the NFT is available on the BSC, but it either:
     * - has not been minted
     * - has not been picked up by the owner from the bridge contract
     */
    mapping(string => address) private _bridgedExternalTokenIDsPickUp;
    mapping(string => string) private _externalIDToURI;

    /**
     * @dev Stores the mapping between external token IDs and addresses of the actual
     * minted HelixNFTs.
     */
    mapping(string => uint256) private _minted;

    /// for counting whenever add bridge once approve on solana 
    /// if it's down to 0, will call to remove bridger
    /// user => counts
    mapping(address => uint256) private _countAddBridge;
    /**
     * @dev Bridgers are Helix service accounts which listen to the events
     *      happening on the Solana chain and then enabling the NFT for
     *      minting / unlocking it for usage on BSC.
     */
    EnumerableSet.AddressSet private _bridgers;

    event BridgeToSolana(string externalTokenID, string externalRecipientAddr, uint256 timestamp);
    event AddBridger(address indexed user, string externalTokenID);
    
    /**
     * @dev HelixNFT contract    
     */
    HelixNFT helixNFT;

    constructor(HelixNFT _helixNFT) {
        helixNFT = _helixNFT;
    }
    
    /**
     * @dev This function is called ONLY by bridgers to bridge the token to BSC
     */
    function bridgeToBSC(string calldata externalTokenID, address owner, string calldata uri) 
        onlyBridger 
        external 
        returns (bool) {
        require(
            !_bridgedExternalTokenIDs[externalTokenID], 
            "HelixNFTBridge: token already bridged"
        );
        require(_countAddBridge[owner] > 0, "HelixNFTBridge: You are not a Bridger");

        _bridgedExternalTokenIDs[externalTokenID] = true;
        _bridgedExternalTokenIDsPickUp[externalTokenID] = owner;

        // If the token is already minted, we could send it directly to the user's wallet
        if (_minted[externalTokenID] > 0) {
            helixNFT.transferFrom(address(this), owner, _minted[externalTokenID]);
        } else {
            _externalIDToURI[externalTokenID] = uri;
        }
        _countAddBridge[owner]--;
        if (_countAddBridge[owner] == 0) 
            return _delBridger(owner);
        return true;
    }

    /**
     * @dev Used for minting the NFT first-time bridged to BSC from Solana.
     */
    function mintBridgedNFT(string calldata externalTokenID) external whenNotPaused {
        require(_bridgedExternalTokenIDs[externalTokenID], "HelixNFTBridge: not available");
        require(
            _bridgedExternalTokenIDsPickUp[externalTokenID] == msg.sender, 
            "HelixNFTBridge: pick up not allowed"
        );

        // Add 1 in expectation of _lastTokenId being incremented during mintExternal call
        _minted[externalTokenID] = helixNFT.getLastTokenId() + 1;

        helixNFT.mintExternal(msg.sender, externalTokenID, _externalIDToURI[externalTokenID]);

    }

    /**
     * @dev Whether the token is bridged or not.
     */
    function isBridged(string calldata externalTokenID) external view returns (bool) {
        return _bridgedExternalTokenIDs[externalTokenID];
    }

    /**
     * @dev Get the owner to pick up the NFT from the bridge contract.
     */
    function getPickUpOwner(string calldata externalTokenID) external view returns (address) {
        return _bridgedExternalTokenIDsPickUp[externalTokenID];
    }

    /// Called by the owner to pause the contract
    function pause() external onlyOwner {
        _pause();
    }

    /// Called by the owner to unpause the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Returns the address of the minted NFT if available, address(0) otherwise.
     */
    function getMinted(string calldata externalTokenID) external view returns (uint256) {
        return _minted[externalTokenID];
    }

    /**
     * @dev Mark token as unavailable on BSC.
     */
    function bridgeToSolana(uint256 tokenId, string calldata externalRecipientAddr) 
        external 
        whenNotPaused
    {
        string memory externalTokenID = helixNFT.getExternalTokenID(tokenId);
        require(_bridgedExternalTokenIDs[externalTokenID], "HelixNFTBridge: already bridged to Solana");
        require(_bridgedExternalTokenIDsPickUp[externalTokenID] == msg.sender, "HelixNFTBridge: Not owner");

        // Mark as unavailable on BSC.
        _bridgedExternalTokenIDs[externalTokenID] = false;
        _bridgedExternalTokenIDsPickUp[externalTokenID] = address(0);

        helixNFT.transferFrom(msg.sender, address(this), tokenId);

        emit BridgeToSolana(externalTokenID, externalRecipientAddr, block.timestamp);
    }

    /**
     * @dev used by owner to add a bridger service account who calls `bridgeFromSolana`
     * @param _bridger address of bridger to be added.
     * @return true if successful.
     */
    function addBridger(address _bridger, string calldata externalTokenID) external onlyOwner returns (bool) {
        require(
            _bridger != address(0),
            "HelixNFTBridge: _bridger is the zero address"
        );
        _countAddBridge[_bridger]++;
        emit AddBridger(_bridger, externalTokenID);
        return EnumerableSet.add(_bridgers, _bridger);
    }

    /**
     * @dev used by owner to delete bridger
     * @param _bridger address of bridger to be deleted.
     * @return true if successful.
     */
    function delBridger(address _bridger) external onlyOwner returns (bool) {
        return _delBridger(_bridger);
    }

    function _delBridger(address _bridger) internal returns (bool) {
        require(
            _bridger != address(0),
            "HelixNFTBridge: _bridger is the zero address"
        );
        return EnumerableSet.remove(_bridgers, _bridger);
    }

    /**
     * @dev See the number of bridgers
     * @return number of bridges.
     */
    function getBridgersLength() public view returns (uint256) {
        return EnumerableSet.length(_bridgers);
    }

    /**
     * @dev Check if an address is a bridger
     * @return true or false based on bridger status.
     */
    function isBridger(address account) public view returns (bool) {
        return EnumerableSet.contains(_bridgers, account);
    }

    /**
     * @dev Get the staker at n location
     * @param _index index of address set
     * @return address of staker at index.
     */
    function getBridger(uint256 _index)
        external
        view
        onlyOwner
        returns (address)
    {
        require(_index <= getBridgersLength() - 1, "HelixNFTBridge: index out of bounds");
        return EnumerableSet.at(_bridgers, _index);
    }

    /**
     * @dev Modifier for operations which can be performed only by bridgers
     */
    modifier onlyBridger() {
        require(isBridger(msg.sender), "caller is not the bridger");
        _;
    }
}
