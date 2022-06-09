// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "../interfaces/IMigratorChef.sol";
import "../interfaces/IMasterChef.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";

/// Thrown when caller is a contract
error CallerIsContract(address caller);

/// Thrown when caller is a proxy
error CallerIsProxy(address caller);

/// Thrown when deposit amount is 0
error ZeroDeposit();

/// Thrown when address(0) is encountered
error ZeroAddress();

/// Thrown when fee exceeds max
error FeeExceedsMax(uint256 fee, uint256 max);

/// Thrown when trying to "unstuck" token that isn't stuck
error TokenNotStuck(address token);

/// Thrown when withdraw amount is 0
error ZeroWithdraw();

/// Thrown when amount exceeds balance
error InsufficientBalance(uint256 amount, uint256 balance);

contract AutoHelix is Initializable, OwnableUpgradeable, PausableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct UserInfo {
        uint256 shares; // number of shares for a user
        uint256 lastDepositedTime; // keeps track of deposited time for potential penalty
        uint256 helixAtLastUserAction; // keeps track of Helix deposited at the last user action
        uint256 lastUserActionTime; // keeps track of the last user action time
    }

    IERC20Upgradeable public token; // Helix token

    IMasterChef public masterchef;

    uint256 public totalShares;
    uint256 public lastHarvestedTime;
    address public treasury;

    uint256 public constant MAX_PERFORMANCE_FEE = 500; // 5%
    uint256 public constant MAX_CALL_FEE = 100; // 1%
    uint256 public constant MAX_WITHDRAW_FEE = 100; // 1%
    uint256 public constant MAX_WITHDRAW_FEE_PERIOD = 3 days; // 3 days

    uint256 public performanceFee;
    uint256 public callFee;
    uint256 public withdrawFee;
    uint256 public withdrawFeePeriod;

    mapping(address => UserInfo) public userInfo;

    // Emitted when a deposit is made
    event Deposit(
        address indexed sender, 
        uint256 amount, 
        uint256 shares, 
        uint256 lastDepositedTime
    );

    // Emitted when tokens are withdrawn
    event Withdraw(
        address indexed sender, 
        uint256 amount, 
        uint256 shares
    );

    // Emitted when tokens are harvested
    event Harvest(
        address indexed sender, 
        uint256 performanceFee, 
        uint256 callFee
    );

    // Emitted when the owner updates the performance fee
    event SetPerformanceFee(address indexed setter, uint256 performanceFee);

    // Emitted when the owner updates the call fee
    event SetCallFee(address indexed setter, uint256 callFee);

    // Emitted when the owner updates the withdraw fee
    event SetWithdrawFee(address indexed setter, uint256 withdrawFee);

    // Emitted when the owner updates the withdraw fee period
    event SetWithdrawFeePeriod(address indexed setter, uint256 withdrawFeePeriod);

    /**
     * @notice Checks if the msg.sender is a contract or a proxy
     */
    modifier notContract() {
        if (AddressUpgradeable.isContract(msg.sender)) revert CallerIsContract(msg.sender);
        if (msg.sender != tx.origin) revert CallerIsProxy(msg.sender);
        _;
    }

    /**
     * @param _token: Helix token contract
     * @param _masterchef: MasterChef contract
     * @param _treasury: address of the treasury (collects fees)
     */
    function initialize(
        address _token,
        IMasterChef _masterchef,
        address _treasury
    ) external initializer {
        __Ownable_init();
        __Pausable_init();
        token = IERC20Upgradeable(_token);
        masterchef = _masterchef;
        treasury = _treasury;

        // Infinite approve
        IERC20Upgradeable(_token).safeApprove(address(_masterchef), type(uint256).max);

        performanceFee = 299; // 2.99%
        callFee = 25; // 0.25%
        withdrawFee = 10; // 0.1%
        withdrawFeePeriod = 3 days; // 3 days
    }

    /**
     * @notice Deposits funds into the Helix Vault
     * @dev Only possible when contract not paused.
     * @param _amount: number of tokens to deposit (in Helix)
     */
    function deposit(uint256 _amount) external whenNotPaused notContract {
        if (_amount == 0) revert ZeroDeposit();

        uint256 pool = balanceOf();

        uint256 currentShares = _amount;
        if (totalShares > 0) {
            currentShares = (currentShares * totalShares) / pool;
        } 
        totalShares += currentShares;

        UserInfo storage user = userInfo[msg.sender];
        user.shares = user.shares + currentShares;
        user.helixAtLastUserAction = user.shares * (pool + _amount) / totalShares;
        user.lastUserActionTime = block.timestamp;
        user.lastDepositedTime = block.timestamp;

        TransferHelper.safeTransferFrom(address(token), msg.sender, address(this), _amount);
        _earn();

        emit Deposit(
            msg.sender, 
            _amount, 
            currentShares, 
            block.timestamp
        );
    }

    /**
     * @notice Withdraws all funds for a user
     */
    function withdrawAll() external notContract {
        withdraw(userInfo[msg.sender].shares);
    }

    /**
     * @notice Reinvests Helix tokens into MasterChef
     * @dev Only possible when contract not paused.
     */
    function harvest() external notContract whenNotPaused {
        IMasterChef(masterchef).leaveStaking(0);

        lastHarvestedTime = block.timestamp;

        uint256 bal = available();

        uint256 currentPerformanceFee = bal * performanceFee / 10000;
        TransferHelper.safeTransfer(address(token), treasury, currentPerformanceFee); 

        uint256 currentCallFee = bal * callFee / 10000;
        TransferHelper.safeTransfer(address(token), msg.sender, currentCallFee);

        _earn();

        emit Harvest(msg.sender, currentPerformanceFee, currentCallFee);
    }

    /**
     * @notice Sets treasury address
     * @dev Only callable by the contract owner.
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    /**
     * @notice Sets performance fee
     * @dev Only callable by the contract owner.
     */
    function setPerformanceFee(uint256 _performanceFee) external onlyOwner {
        if (_performanceFee > MAX_PERFORMANCE_FEE) {
            revert FeeExceedsMax(_performanceFee, MAX_PERFORMANCE_FEE);
        }
        performanceFee = _performanceFee;
        emit SetPerformanceFee(msg.sender, _performanceFee);
    }

    /**
     * @notice Sets call fee
     * @dev Only callable by the contract owner.
     */
    function setCallFee(uint256 _callFee) external onlyOwner {
        if (_callFee > MAX_CALL_FEE) {
            revert FeeExceedsMax(_callFee, MAX_CALL_FEE);
        }
        callFee = _callFee;
        emit SetCallFee(msg.sender, _callFee);
    }

    /**
     * @notice Sets withdraw fee
     * @dev Only callable by the contract owner.
     */
    function setWithdrawFee(uint256 _withdrawFee) external onlyOwner {
        if (_withdrawFee > MAX_WITHDRAW_FEE) {
            revert FeeExceedsMax(_withdrawFee, MAX_WITHDRAW_FEE);
        }
        withdrawFee = _withdrawFee;
        emit SetWithdrawFee(msg.sender, _withdrawFee);
    }

    /**
     * @notice Sets withdraw fee period
     * @dev Only callable by the contract owner.
     */
    function setWithdrawFeePeriod(uint256 _withdrawFeePeriod) external onlyOwner {
        if (_withdrawFeePeriod > MAX_WITHDRAW_FEE_PERIOD) {
            revert FeeExceedsMax(_withdrawFeePeriod, MAX_WITHDRAW_FEE_PERIOD);
        }
        withdrawFeePeriod = _withdrawFeePeriod;
        emit SetWithdrawFeePeriod(msg.sender, _withdrawFeePeriod);
    }

    /**
     * @notice Withdraws from MasterChef to Vault without caring about rewards.
     * @dev EMERGENCY ONLY. Only callable by the contract owner.
     */
    function emergencyWithdraw() external onlyOwner {
        IMasterChef(masterchef).emergencyWithdraw(0);
    }

    /**
     * @notice Withdraw unexpected tokens sent to the Helix Vault
     */
    function inCaseTokensGetStuck(address _token) external onlyOwner {
        if (_token == address(token)) {
            revert TokenNotStuck(_token);
        }

        uint256 amount = IERC20Upgradeable(_token).balanceOf(address(this));
        TransferHelper.safeTransfer(address(_token), msg.sender, amount);
    }

    /**
     * @notice Triggers stopped state
     * @dev Only possible when contract not paused.
     */
    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    /**
     * @notice Returns to normal state
     * @dev Only possible when contract is paused.
     */
    function unpause() external onlyOwner whenPaused {
        _unpause();
    }

    /**
     * @notice Calculates the expected harvest reward from third party
     * @return Expected reward to collect in Helix
     */
    function calculateHarvestHelixRewards() external view returns (uint256) {
        uint256 amount = IMasterChef(masterchef).pendingHelixToken(0, address(this));
        amount = amount + available();
        uint256 currentCallFee = amount * callFee / 10000;

        return currentCallFee;
    }

    /**
     * @notice Calculates the total pending rewards that can be restaked
     * @return Returns total pending Helix rewards
     */
    function calculateTotalPendingHelixRewards() external view returns (uint256) {
        uint256 amount = IMasterChef(masterchef).pendingHelixToken(0, address(this));
        amount = amount + available();

        return amount;
    }

    /**
     * @notice Calculates the price per share
     */
    function getPricePerFullShare() external view returns (uint256) {
        return totalShares == 0 ? 1e18 : balanceOf() * 1e18 / totalShares;
    }

    /**
     * @notice Withdraws from funds from the Helix Vault
     * @param _shares: Number of shares to withdraw
     */
    function withdraw(uint256 _shares) public notContract {
        UserInfo storage user = userInfo[msg.sender];
        if (_shares == 0) revert ZeroWithdraw();
        if (_shares > user.shares) revert InsufficientBalance(_shares, user.shares);

        uint256 currentAmount = (balanceOf() * _shares) / totalShares;
        user.shares = user.shares - _shares;
        totalShares = totalShares - _shares;

        uint256 bal = available();
        if (bal < currentAmount) {
            uint256 balWithdraw = currentAmount - bal;
            IMasterChef(masterchef).leaveStaking(balWithdraw);
            uint256 balAfter = available();
            uint256 diff = balAfter - bal;
            if (diff < balWithdraw) {
                currentAmount = bal + diff;
            }
        }
        
        uint256 currentWithdrawFee;
        if (block.timestamp < user.lastDepositedTime + (withdrawFeePeriod)) {
            currentWithdrawFee = currentAmount * withdrawFee / 10000;
            currentAmount -= currentWithdrawFee;
        }

        user.helixAtLastUserAction = user.shares * balanceOf() / totalShares;
        user.lastUserActionTime = block.timestamp;

        if (currentWithdrawFee > 0) {
            TransferHelper.safeTransfer(address(token), treasury, currentWithdrawFee);
        }
        if (currentAmount > 0) {
            TransferHelper.safeTransfer(address(token), msg.sender, currentAmount);
        }

        emit Withdraw(msg.sender, currentAmount, _shares);
    }

    /**
     * @notice Custom logic for how much the vault allows to be borrowed
     * @dev The contract puts 100% of the tokens to work.
     */
    function available() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /**
     * @notice Calculates the total underlying tokens
     * @dev It includes tokens held by the contract and held in MasterChef
     */
    function balanceOf() public view returns (uint256) {
        (uint256 amount, ) = IMasterChef(masterchef).userInfo(0, address(this));
        return token.balanceOf(address(this)) + amount;
    }

    /**
     * @notice Deposits tokens into MasterChef to earn staking rewards
     */
    function _earn() internal {
        uint256 bal = available();
        if (bal > 0) {
            IMasterChef(masterchef).enterStaking(bal);
        }
    }
}
