// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.7.4 <0.8.0;

import "@openzeppelin/contracts@3.4.0/math/SafeMath.sol";
import "@openzeppelin/contracts@3.4.0/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts@3.4.0/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts@3.4.0/access/Ownable.sol";
import "@openzeppelin/contracts@3.4.0/utils/ReentrancyGuard.sol";
import "./uniswap/interfaces/IUniswapV2Pair.sol";
import "./IUniswapV2Router01.sol";
import "./QuickswapHandler.sol";

//Credits

contract MasterChef is Ownable, ReentrancyGuard, QuickswapHandler {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of Bamboos
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accBambooPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accBambooPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. Bamboos to distribute per block.
        uint256 lastRewardBlock;  // Last block number that Bamboos distribution occurs.
        uint256 accBambooPerShare;   // Accumulated Bamboos per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
        bool isLp;
    }

    // Dev address.
    address public devaddr;
    // Deposit Fee address
    address public blackHoleAddress;
    //This address is in case auto-add LP doesn't work due to slippage or any other uniswap issues
    address public manualLpAddress;
    
    //Maxmimum amount of bamboos per block
    uint256 public maxBamboosPerBlock;
    // Bamboo tokens created per block.
    uint256 public bambooPerBlock;
    // Bonus muliplier for early bamboo makers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when Bamboo mining starts.
    uint256 public startBlock;
    //This is accumulated amount of bamboo to buyback
    uint256 public bambooToBuyback;
    //Minimum amount of bamboo needed to buyback
    uint256 public minBambooToBuyback = 10 ether;
    
    //Whether or not to disable or enable buyback
    bool public buybackEnabled = false;
    bool public buybackFeeEnabled = false;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;


    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetBlackHoleAddress(address indexed user, address indexed newAddress);
    event SetDevAddress(address indexed user, address indexed newAddress);
    event SetManualLpAddress(address indexed user, address indexed newAddress);
    event UpdateEmissionRate(address indexed user, uint256 goosePerBlock);

    constructor(
        Bamboo _bamboo,
        address _devaddr,
        address _blackHoleAddress,
        address _manualLpAddress,
        address _qsRouter,
        address _qsPairAddress,
        address _qsFactoryAddress,
        uint256 _maxBamboosPerBlock,
        uint256 _bambooPerBlock,
        uint256 _startBlock
    ) public {
        bamboo = _bamboo;
        devaddr = _devaddr;
        blackHoleAddress = _blackHoleAddress;
        manualLpAddress = _manualLpAddress;
        qsRouter = _qsRouter;
        qsPairAddress = _qsPairAddress;
        qsFactory = _qsFactoryAddress;
        maxBamboosPerBlock = _maxBamboosPerBlock;
        bambooPerBlock = _bambooPerBlock;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    mapping(IERC20 => bool) public poolExistence;
    
    modifier nonDuplicated(IERC20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }
    
    modifier poolExists(uint256 pid) {
        require(pid < poolInfo.length, "pool does not exist");
        _;
    }
    
    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20 _lpToken, uint16 _depositFeeBP, bool _withUpdate, bool _isLp) public onlyOwner nonDuplicated(_lpToken) {
        require(_depositFeeBP <= 10000, "add: invalid deposit fee basis points");
        
        if (_withUpdate) {
            massUpdatePools();
        }
        
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        
        poolExistence[_lpToken] = true;
        
        poolInfo.push(PoolInfo({
        lpToken : _lpToken,
        allocPoint : _allocPoint,
        lastRewardBlock : lastRewardBlock,
        accBambooPerShare : 0,
        depositFeeBP : _depositFeeBP,
        isLp : _isLp
        }));
    }

    // Update the given pool's Bamboo allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, bool _withUpdate, bool _isLp) public onlyOwner {
        require(_depositFeeBP <= 10000, "set: invalid deposit fee basis points");
        
        if (_withUpdate) {
            massUpdatePools();
        }
        
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        
        poolInfo[_pid].allocPoint = _allocPoint;
        
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        
        poolInfo[_pid].isLp = _isLp;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending Bamboos on frontend.
    function pendingBamboo(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        
        uint256 accBambooPerShare = pool.accBambooPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 bambooReward = multiplier.mul(bambooPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            
            accBambooPerShare = accBambooPerShare.add(bambooReward.mul(1e12).div(lpSupply));
        }
        
        return user.amount.mul(accBambooPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        emit Log("Mass updating pools ", length);
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    //event LogUpdatePool(string msg, uint256 num, )

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        emit Log("Updating pool ID: ", _pid);
        
        PoolInfo storage pool = poolInfo[_pid];

        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        

        uint256 bambooRewardInitial = multiplier.mul(bambooPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        

        uint256 bambooReward = bambooRewardInitial;
        
        uint256 fees = bambooRewardInitial.div(10);

        bambooToBuyback = bambooToBuyback.add(fees);

        //dev fee mint
        bamboo.mint(devaddr, fees);
        //Mint 10% for buyback to lp
        if(buybackEnabled)
            bamboo.mint(address(this), fees);
        //Mint 10% for blackhole lottery.
        bamboo.mint(blackHoleAddress, fees);
        
        //subtract 30% of fees from reward.
        bambooReward = bambooReward.sub(fees.mul(3));
        
        //Mint user rewards
        bamboo.mint(address(this), bambooReward);
        
        if(bambooToBuyback >= minBambooToBuyback && buybackEnabled){
            uint256 bambooAccumulated = bambooToBuyback;
            bambooToBuyback = 0;
            //buys back bamboo token and permanently locks it as liquidity pair
            this.buybackToLpSingle(true, bambooAccumulated, address(bamboo));
        }
        
        pool.accBambooPerShare = pool.accBambooPerShare.add(bambooReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for Bamboo allocation.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant poolExists (_pid) {
        
        emit Log("Starting deposit, pid: ", _pid);
        
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        
        updatePool(_pid);
        if (user.amount > 0) {
        require(user.amount > 0, "User.amount is empty");
            
            //Amount of bamboo that is currently pending for this specific user
            uint256 pending = user.amount.mul(pool.accBambooPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeBambooTransfer(msg.sender, pending);
            }
        }
        
        if (_amount > 0) {
            require(pool.lpToken.balanceOf(msg.sender) >= _amount, "User does not have enough tokens");
            require(pool.lpToken.allowance(msg.sender, address(this)) >= _amount, "Deposit: Not enough allowance. Please approve LP token before transacting");
            pool.lpToken.safeTransferFrom(msg.sender, address(this), _amount);
            
            //if the pool has any deposit fees, make sure to take fee into account
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                if(pool.isLp){
                    if(buybackFeeEnabled){
                        //We'll try to automatically buyback and add to LP
                        try this.buybackToLp(true, depositFee.div(2), address(pool.lpToken)) {
                    } catch {
                        //If it doesn't work, transfer to a team-controlled wallet so we can add it manually
                        //This sacrifices some decentralization and should only be an issue in the early hours of a farm
                            pool.lpToken.safeTransfer(manualLpAddress, depositFee.div(2));
                        }
                    }
                    pool.lpToken.safeTransfer(devaddr, depositFee.div(2));
                } else {
                    if(address(pool.lpToken) != address(bamboo)){
                        if(buybackFeeEnabled){
                            try this.buybackToLpSingle(true, depositFee.div(2), address(pool.lpToken)) {
                            } catch {
                                pool.lpToken.safeTransfer(manualLpAddress, depositFee.div(2));
                            }
                        }
                        pool.lpToken.safeTransfer(devaddr, depositFee.div(2));
                    } else {
                        bamboo.burn(depositFee.div(2));
                        safeBambooTransfer(devaddr, depositFee.div(2));
                    }
                }
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accBambooPerShare).div(1e12);
        
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        
        PoolInfo storage pool = poolInfo[_pid];
        
        UserInfo storage user = userInfo[_pid][msg.sender];
        
        require(user.amount >= _amount, "withdraw: not enough LP tokens in pool");
        
        updatePool(_pid);
        
        uint256 pending = user.amount.mul(pool.accBambooPerShare).div(1e12).sub(user.rewardDebt);
        
        if (pending > 0) {
            safeBambooTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accBambooPerShare).div(1e12);
        
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        
        uint256 amount = user.amount;
        
        user.amount = 0;
        user.rewardDebt = 0;
        
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe Bamboo transfer function, just in case if rounding error causes pool to not have enough Bamboos.
    function safeBambooTransfer(address _to, uint256 _amount) internal {
        uint256 bambooBal = bamboo.balanceOf(address(this));
        
        bool transferSuccess = false;
        
        if (_amount > bambooBal) {
            transferSuccess = bamboo.transfer(_to, bambooBal);
        } else {
            transferSuccess = bamboo.transfer(_to, _amount);
        }
        
        require(transferSuccess, "safeBambooTransfer: transfer failed");
    }
    
    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
        emit SetDevAddress(msg.sender, _devaddr);
    }

    function setBlackHoleAddress(address _blackHoleAddress) public {
        require(msg.sender == devaddr, "blackHoleAddress: FORBIDDEN");
        blackHoleAddress = _blackHoleAddress;
        emit SetBlackHoleAddress(msg.sender, _blackHoleAddress);
    }
    
    function setManualLpAddress(address _manualLpAddress) public {
        require(msg.sender == devaddr, "blackHoleAddress: FORBIDDEN");
        manualLpAddress = _manualLpAddress;
        emit SetManualLpAddress(msg.sender, _manualLpAddress);
    }
    
    function setQsRouterAddress(address _qsRouterAddress) public onlyOwner {
        qsRouter = _qsRouterAddress;
    }
    
    function setQsPairAddress(address _qsPairAddress) public onlyOwner {
        qsPairAddress = _qsPairAddress;
    }
    
    function enableBuybackMint(bool _enabled) public onlyOwner {
        buybackEnabled = _enabled;
    }
    
    function enableBuybackFee(bool _enabled) public onlyOwner {
        buybackFeeEnabled = _enabled;
    }
    
    //Pancake has to add hidden dummy pools inorder to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _bambooPerBlock) public onlyOwner {
        massUpdatePools();
        
        //To make sure emission rate cannot be abused, here we check if amount of bamboos produced per block
        //is bigger than the pre-determined maximum amount of bamboos per block
        if(_bambooPerBlock > maxBamboosPerBlock){
            _bambooPerBlock = maxBamboosPerBlock;
        } else {
            //if not, maxBamboosPerBlock is equals to new emission level
            maxBamboosPerBlock = _bambooPerBlock;
        }
        
        bambooPerBlock = _bambooPerBlock;
        emit UpdateEmissionRate(msg.sender, _bambooPerBlock);
    }

    //Only update before start of farm
    function updateStartBlock(uint256 _startBlock) public onlyOwner {
        startBlock = _startBlock;
    }
    
        //Only update before start of farm
    function updateMinBambooToBuyback(uint256 _amount) public onlyOwner {
        minBambooToBuyback = _amount;
    }
}
