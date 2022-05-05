// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@rari-capital/solmate/src/utils/ReentrancyGuard.sol";
import "@rari-capital/solmate/src/tokens/ERC20.sol";
import "../interfaces/IHelixNFT.sol";

contract HelixChefNFT is Ownable, ReentrancyGuard {

    // Total Helix Points staked in Pool across all NFTs by all users.
    uint256 public totalHelixPoints;
    // Last block that rewards were calculated.
    uint256 public lastRewardBlock;
    // instance of HelixNFT
    IHelixNFT private helixNFT;

    // Used during calculations of accumulated tokens per share
    uint256 public constant PRECISION_FACTOR = 1e12;

    // Here is a main formula to stake. Basically, any point in time, the amount of rewards entitled to a user but is pending to be distributed is:
    //
    //   pending reward = (user.helixPointAmount * rewardTokens.accCakePerShare) - user.rewardDebt
    //
    // Whenever a user stake/unstake/withdraw. Here's what happens:
    //   1. The RewardToken's `accCakePerShare` (and `lastRewardBlock`) gets updated in `updatePool` function
    //   2. User receives the pending reward sent to user's address.
    //   3. User's `helixPointAmount` (and `totalHelixPoints`) gets updated.
    //   4. User's `rewardDebt` gets updated.

    // Info of each user who took part in staking
    struct UserInfo {
        // list of staked NFT's ID
        uint[] stakedNFTsId;
        // HelixPoint Amount user gain with staked(A helixNFT has helixPoint amount initially)
        uint256 helixPointAmount;
    }

    // Info of reward token
    struct RewardToken {
        // reward will be accrued per block, must not be zero.
        uint256 rewardPerBlock;
        // block number which reward token is created.
        uint256 startBlock;
        // Accumulated Tokens per share, times PRECISION_FACTOR.(1e12 is for suming as integer)
        uint256 accTokenPerShare;
        // true - enable; false - disable
        bool enabled;
    }

    // users took part in staking : UserAddress => UserInfo
    mapping (address => UserInfo) public users;
    // list of reward token's address
    address[] public rewardTokenAddresses;
    // RewardTokenAddress => RewardToken
    mapping (address => RewardToken) public rewardTokens;
    // rewardDebt is for removing duplicated reward that means whatever you’ve already received: UserAddress => (RewardTokenAddress => amount of rewardDebt)
    mapping (address => mapping(address => uint)) public rewardDebt;

    event AddNewRewardToken(address token);
    event DisableRewardToken(address token);
    event ChangeRewardToken(address indexed token, uint256 rewardPerBlock);
    event StakeTokens(address indexed user, uint256 amountRB, uint[] tokensId);
    event UnstakeToken(address indexed user, uint256 amountRB, uint[] tokensId);
    event BoostHelixNFT(uint256 indexed tokenId, uint256 boostedAP);

    constructor(IHelixNFT _helixNFT, uint256 _lastRewardBlock) {
        helixNFT = _helixNFT;
        lastRewardBlock = _lastRewardBlock;
    }

    //Public functions -------------------------------------------------------
    
    /**
     * @dev Update reward variables of the pool to be up-to-date.
     *
     * NOTE: - Update `lastRewardBlock` with current block number.
     *       - Update `accTokenPerShare` of all `rewardTokens` to current time.
     */
    function updatePool() public {
        uint256 _fromLastRewardToNow = getDiffBlock(lastRewardBlock, block.number);
        uint256 _totalHelixPoints = totalHelixPoints;

        if(_fromLastRewardToNow == 0){
            return;
        }
        lastRewardBlock = block.number;
        if(_totalHelixPoints == 0){
            return;
        }
        for(uint256 i = 0; i < rewardTokenAddresses.length; i++){
            address _tokenAddress = rewardTokenAddresses[i];
            RewardToken memory curRewardToken = rewardTokens[_tokenAddress];
            if(curRewardToken.enabled && curRewardToken.startBlock < block.number){
                uint256 fromRewardStartToNow = getDiffBlock(curRewardToken.startBlock, block.number);
                uint256 curMultiplier = Math.min(fromRewardStartToNow, _fromLastRewardToNow);
                rewardTokens[_tokenAddress].accTokenPerShare += (curRewardToken.rewardPerBlock * curMultiplier * PRECISION_FACTOR) / _totalHelixPoints;
            }
        }
    }

    /**
     * @dev Used by owner to add new reward Token
     * @param newToken address of reward Token to be added
     * @param startBlock startBlock of new reward Token
     * @param rewardPerBlock rewardPerBlock of new reward Token
     *
     * Requirements:
     *
     * - `newToken` cannot be the zero address and it must be what doesn't exist.
     * - `rewardPerBlock` cannot be the zero.
     */
    function addNewRewardToken(address newToken, uint256 startBlock, uint256 rewardPerBlock) public onlyOwner {
        require(newToken != address(0), "Address shouldn't be 0");
        require(!isRewardToken(newToken), "Token is already in the list");
        require(rewardPerBlock != 0, "rewardPerBlock shouldn't be 0");

        rewardTokenAddresses.push(newToken);
        if(startBlock == 0){
            rewardTokens[newToken].startBlock = block.number + 1;
        } else {
            rewardTokens[newToken].startBlock = startBlock;
        }
        rewardTokens[newToken].rewardPerBlock = rewardPerBlock;
        rewardTokens[newToken].enabled = true;

        emit AddNewRewardToken(newToken);
    }

    /**
     * @dev Used by owner to disable rewardToken
     * @param token address of reward Token to be disabled
     * 
     * NOTE: UpdatePool() is required to reward users so far before token is disabled.
     *
     * Requirements:
     * - `token` must exist.
     * - `token` must be enabled.
     */
    function disableRewardToken(address token) public onlyOwner {
        require(isRewardToken(token), "Token not in the list");
        require(rewardTokens[token].enabled, "Reward token is already disabled");

        updatePool();
        rewardTokens[token].enabled = false;
        emit DisableRewardToken(token);
    }

    /**
     * @dev Used by owner to enable rewardToken 
     * @param token address of reward Token to be enabled
     * @param startBlock startBlock of reward Token to be enabled
     * @param rewardPerBlock rewardPerBlock of reward Token to be enabled
     *
     * NOTE: UpdatePool() is required to refresh once token is enabled.
     *
     * Requirements:
     *
     * - `token` must exist.
     * - `token` must be diabled.
     * - `rewardPerBlock` cannot be the zero.
     * - `startBlock` must be later than current.
     */
    function enableRewardToken(address token, uint256 startBlock, uint256 rewardPerBlock) public onlyOwner {
        require(isRewardToken(token), "Token not in the list");
        require(!rewardTokens[token].enabled, "Reward token is already enabled");
        require(rewardPerBlock != 0, "rewardPerBlock shouldn't be 0");

        if (startBlock == 0) {
            startBlock = block.number + 1;
        }
        require(startBlock >= block.number, "Start block Must be later than current");

        rewardTokens[token].enabled = true;
        rewardTokens[token].startBlock = startBlock;
        rewardTokens[token].rewardPerBlock = rewardPerBlock;

        updatePool();

        emit ChangeRewardToken(token, rewardPerBlock);
    }

    /**
     * @dev staking
     *
     * NOTE: 1. UpdatePool and User receives the pending reward sent to user's address.
     *       2. Push new NFT to be staked
     *       3. User's `helixPointAmount`(and `totalHelixPoints`) gets updated.
     *       4. User's `rewardDebt` gets updated.
     *
     * Requirements:
     *
     * - `tokensId`'s owner must be sender
     * - `tokensId` must be unstaked
     */
    function stake(uint[] memory tokensId) public nonReentrant {
        
        _withdrawRewardToken();// --------1
        
        UserInfo storage user = users[msg.sender];
        uint256 depositedAPs = 0;
        for(uint256 i = 0; i < tokensId.length; i++){
            (address tokenOwner, bool isStaked, uint256 helixPoints) = helixNFT.getInfoForStaking(tokensId[i]);
            require(tokenOwner == msg.sender, "Not token owner");
            require(!isStaked, "Token has already been staked");
            helixNFT.setIsStaked(tokensId[i], true);
            depositedAPs += helixPoints;
            user.stakedNFTsId.push(tokensId[i]);// --------2
        }
        if(depositedAPs > 0){
            user.helixPointAmount += depositedAPs;// --------3
            totalHelixPoints += depositedAPs;
        }
        _updateRewardDebt(msg.sender);// --------4
        emit StakeTokens(msg.sender, depositedAPs, tokensId);
    }

    /**
     * @dev unstaking
     *
     * NOTE: 1. UpdatePool and User receives the pending reward sent to user's address.
     *       2. Remove NFTs to be unstaked
     *       3. User's `helixPointAmount`(and `totalHelixPoints`) gets updated.
     *       4. User's `rewardDebt` gets updated.
     *
     * Requirements:
     *
     * - `tokensId`'s owner must be sender
     * - `tokensId` must be staked
     */
    function unstake(uint[] memory tokensId) public nonReentrant {
        
        _withdrawRewardToken();// --------1
        
        UserInfo storage user = users[msg.sender];
        uint256 withdrawalAPs = 0;
        for(uint256 i = 0; i < tokensId.length; i++){
            (address tokenOwner, bool isStaked, uint256 helixPoints) = helixNFT.getInfoForStaking(tokensId[i]);
            require(tokenOwner == msg.sender, "Not token owner");
            require(isStaked, "Token has already been unstaked");
            helixNFT.setIsStaked(tokensId[i], false);
            withdrawalAPs += helixPoints;
            removeTokenIdFromUsers(tokensId[i], msg.sender);// --------2
        }
        if(withdrawalAPs > 0){
            user.helixPointAmount -= withdrawalAPs;// --------3
            totalHelixPoints -= withdrawalAPs;
        }
        _updateRewardDebt(msg.sender);// --------4
        emit UnstakeToken(msg.sender, withdrawalAPs, tokensId);
    }

    //External functions -----------------------------------------------------
    
    /**
     * @dev To withdraw reward token
     */
    function withdrawRewardToken() external nonReentrant {
        _withdrawRewardToken();
    }

    /**
     * @dev Boost helixNFT `tokenId` with accumulated HelixPoints `amount` by an user
     * @param tokenId uint256 ID of the token to be boosted
     * @param amount uint256 amount of HelixPoints to boost for the token
     *
     * Requirements:
     *      - sender must be an owner of token to be boosted.
     *      - The current held HelixPoints amount must be sufficient.
     *      - The counted helixPoints amount must be not over limit by level.
     */
    function boostHelixNFT(uint256 tokenId, uint256 amount) external {
        (address tokenOwner, bool isStaked, uint256 helixPoints) = helixNFT.getInfoForStaking(tokenId);
        require(tokenOwner == msg.sender, "Not token owner");
        uint256 _accumulatedAP = helixNFT.getAccumulatedAP(msg.sender);
        require(amount <= _accumulatedAP, "Insufficient amount of HelixPoints");

        uint256 _remainAP = helixNFT.remainAPToNextLevel(tokenId);
        uint256 _amount = Math.min(amount, _remainAP);

        uint[] memory tokensId = new uint[](1);
        tokensId[0] = tokenId;
        if (isStaked) {
            unstake(tokensId);
        }
        helixNFT.setAccumulatedAP(msg.sender, _accumulatedAP - _amount);
        uint256 newAP = helixPoints + _amount;
        helixNFT.setHelixPoints(tokenId, newAP);
        if (_amount == _remainAP) {
            helixNFT.levelUp(tokenId);
        }
        if (isStaked) {
            stake(tokensId);
        }
        emit BoostHelixNFT(tokenId, newAP);
    }

    /**
     * @dev See the list of the NFT ids that `_user` has staked
     */
    function getUserStakedTokens(address _user) external view returns(uint[] memory){
        uint[] memory tokensId = new uint[](users[_user].stakedNFTsId.length);
        tokensId = users[_user].stakedNFTsId;
        return tokensId;
    }

    /**
     * @dev See HelixPoint Amount by `_user`
     */
    function getUserHelixPointAmount(address _user) external view returns(uint){
        return users[_user].helixPointAmount;
    }

    /**
     * @dev See the list of Reward Tokens
     */
    function getListRewardTokens() external view returns(address[] memory){
        address[] memory list = new address[](rewardTokenAddresses.length);
        list = rewardTokenAddresses;
        return list;
    }

    /**
     * @dev See pending Reward on frontend.
     */
    function pendingReward(address _user) external view returns (address[] memory, uint[] memory) {
        UserInfo memory user = users[_user];
        uint[] memory rewards = new uint[](rewardTokenAddresses.length);
        if(user.helixPointAmount == 0){
            return (rewardTokenAddresses, rewards);
        }
        uint256 _totalHelixPoints = totalHelixPoints;
        uint256 _fromLastRewardToNow = getDiffBlock(lastRewardBlock, block.number);
        uint256 _accTokenPerShare = 0;
        for(uint256 i = 0; i < rewardTokenAddresses.length; i++){
            address _tokenAddress = rewardTokenAddresses[i];
            RewardToken memory curRewardToken = rewardTokens[_tokenAddress];
            if (_fromLastRewardToNow != 0 && _totalHelixPoints != 0 && curRewardToken.enabled) {
                uint256 fromRewardStartToNow = getDiffBlock(curRewardToken.startBlock, block.number);
                uint256 curMultiplier = Math.min(fromRewardStartToNow, _fromLastRewardToNow);
                _accTokenPerShare = curRewardToken.accTokenPerShare + (curMultiplier * curRewardToken.rewardPerBlock * PRECISION_FACTOR / _totalHelixPoints);
            } else {
                _accTokenPerShare = curRewardToken.accTokenPerShare;
            }
            rewards[i] = (user.helixPointAmount * _accTokenPerShare / PRECISION_FACTOR) - rewardDebt[_user][_tokenAddress];
        }
        return (rewardTokenAddresses, rewards);
    }

    //internal functions -----------------------------------------------------

    /**
     * @dev Withdraw rewardToken from HelixChefNFT.
     *
     * NOTE: 1. updatePool()
     *       2. User's `rewardDebt` gets updated.
     *       3. User receives the pending reward sent to user's address.
     */
    function _withdrawRewardToken() internal {
        updatePool();

        UserInfo memory user = users[msg.sender];
        address[] memory _rewardTokenAddresses = rewardTokenAddresses;

        if (user.helixPointAmount == 0) {
            return;
        }

        for(uint256 i = 0; i < _rewardTokenAddresses.length; i++){
            RewardToken memory curRewardToken = rewardTokens[_rewardTokenAddresses[i]];
            uint256 pending = user.helixPointAmount * curRewardToken.accTokenPerShare / PRECISION_FACTOR - rewardDebt[msg.sender][_rewardTokenAddresses[i]];
            
            if (pending > 0){
                rewardDebt[msg.sender][_rewardTokenAddresses[i]] = user.helixPointAmount * curRewardToken.accTokenPerShare / PRECISION_FACTOR;
                ERC20(_rewardTokenAddresses[i]).transfer(address(msg.sender), pending);
            }
        }
    }

    /**
     * @dev check if `token` is RewardToken
     * @return true if so, false otherwise.
     */
    function isRewardToken(address token) internal view returns(bool){
        return rewardTokens[token].rewardPerBlock != 0;
    }
    
    /**
     * @dev Return difference block between _from and _to
     */
    function getDiffBlock(uint256 _from, uint256 _to) internal pure returns (uint) {
        if(_to > _from)
            return _to - _from;
        else
            return 0;
    }
    
    /**
     * @dev Update RewardDebt by user who is staking
     *
     * NOTE: Why divided by PRECISION_FACTOR is that `accTokenPerShare` is the value multiplied by 1e12.
     */
    function _updateRewardDebt(address _user) internal {
        for(uint256 i = 0; i < rewardTokenAddresses.length; i++){
            rewardDebt[_user][rewardTokenAddresses[i]] = users[_user].helixPointAmount * rewardTokens[rewardTokenAddresses[i]].accTokenPerShare / PRECISION_FACTOR;
        }
    }

    /**
     * @dev Remove TokenId to be unstaked from userInfo
     * @param tokenId to be removed
     * @param user who is unstaking
     */
    function removeTokenIdFromUsers(uint256 tokenId, address user) internal {
        uint[] storage tokensId = users[user].stakedNFTsId;
        for (uint256 i = 0; i < tokensId.length; i++) {
            if (tokenId == tokensId[i]) {
                tokensId[i] = tokensId[tokensId.length - 1];
                tokensId.pop();
                return;
            }
        }
    }
}
