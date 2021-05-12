pragma solidity >= 0.7.4 < 0.8.0;

import "@openzeppelin/contracts@3.4.0/math/SafeMath.sol";
import "@openzeppelin/contracts@3.4.0/token/ERC20/ERC20.sol";
import "./uniswap/interfaces/IUniswapV2Pair.sol";
import "./PolyPanda.sol";
import "./IUniswapV2Router02.sol";
import "./IUniswapV2Factory.sol";

//Should probably come up with a better name, but whatever. Contract could probably be written better too.
//In this contract you'll find the functions and methods which has to do with token buyback
//Basically, instead of just burning our tokens, we add them to quickswap liquidity pool
//This way, we ACTUALLY create a price floor instead of "faking" it. 

contract QuickswapHandler {
    using SafeMath for uint256;

    // Bamboo token
    Bamboo public bamboo;
    
    //Quickswap addresses
    address public qsRouter;
    address public qsPairAddress;
    address public usdc = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address public qsFactory;
    
    //acceptedSlippage = 15%
    //10 000 - 8500 = 1500
    uint acceptedSlippage = 8500;
    
    
    event Log (string log, uint256 num);
    
    //This is for single-asset tokens
    function buybackToLpSingle(bool _isChef, uint256 _amount, address _token) external {
        
        emit Log("Buyback to lp single-asset: ", _amount);
        
        IERC20(_token).approve(qsRouter, _amount);
        
        require(IERC20(_token).allowance(address(this), qsRouter) >= _amount, "Not enough allowance for Quickswap Router to buyback LP");
        
        //Split token in half. We sell half to USDC, which we need to provide for tokens.
        // ex. 2 bamboos at $1 each. We sell 1, now we have 1 bamboo, 1 USDC. 
        // Then we provide 1-1 Bamboo/USDC liquidity pair to quickswap pools.
        uint256 halfToken = _amount.div(2);
        uint256 otherHalf = _amount.sub(halfToken);
        
        address[] memory path;
        
        //if token is NOT equal to bamboo address, swap half to bamboo.  
        if(_token != address(bamboo)){
            path = findPath(_token, address(bamboo));
            (, halfToken) = swap(_isChef, _token, address (bamboo), halfToken, 0, address(this), path);
        }
        
        //if token is NOT USDC, swap to USDC.
        if(_token != usdc){
            path = findPathUSDC(_token);
            (,otherHalf) = swap(_isChef, _token, usdc, otherHalf, 0, address(this), path);
        }

        emit Log("Adding to lp, tokenA amount: ", otherHalf);
        emit Log("Adding to lp, tokenB amount: ", halfToken);
        
        //Then we actually add token A and token B to liquidity pool.
        //This should always be Bamboo/USDC
        permaAddToLp(address (bamboo), usdc, halfToken, otherHalf);
        
    }
    
    //This is for liquidity pairs
    function buybackToLp(bool _isChef, uint256 _amount, address _pair) external {
        
        IERC20(_pair).approve(qsRouter, _amount);
        
        require(IERC20(_pair).allowance(address(this), qsRouter) >= _amount, "Not enough allowance for Quickswap Router to buyback LP");
        
        //get the quickswap pair of LP
        IUniswapV2Pair pair = IUniswapV2Pair(_pair);
        
        //get Token A and token B of pair
        //e.g BAMBOO/USDC - bamboo is A, USDC is B
        address tokenA = pair.token0();
        address tokenB = pair.token1();
        
        //Split the tokens from the pair
        //uint A is the amount of token A, uint B is the amount of token B
        (uint256 a, uint256 b) = removeLiquidity(tokenA, tokenB, _amount);
        
        //If token A is not equals to bamboo token, swap to bamboo
        if(tokenA != address (bamboo)){
            (address newTokenA, uint amountA) = swap(_isChef, tokenA, address (bamboo), a, 0, address(this), findPath(tokenA, address(bamboo)));
            tokenA = newTokenA;
            a = amountA;
        }
        
        //if token B is not equals to USDC, swap to USDC
        if(tokenB != usdc){
            (address newTokenB, uint newAmountB) = swap(_isChef, tokenB, usdc, b, 0, address(this), findPath(tokenB, usdc));
            tokenB = newTokenB;
            b = newAmountB;
        }
        
        //Add token A and token B to LP, this will always be Bamboo/USDC
        permaAddToLp(tokenA, tokenB, a, b);
        
    }
    
    //adds liquidity to pool
    function permaAddToLp(address _tokenA, address _newEth, uint256 _amountA, uint256 _amountB) internal {
        IERC20(_tokenA).approve(qsRouter, _amountA);
        IERC20(_newEth).approve(qsRouter, _amountB);

        
        
        IUniswapV2Router01(qsRouter).addLiquidity(_tokenA, _newEth, _amountA, _amountB, 0, 0, address(this), block.timestamp);
    }
    
    //This is a function which simplifies swapping
    //Basically, we need to swap into the LP pool tokens before locking them (unless they are the correct pair already)
    function swap(bool isChef, address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _amountOut, address _to, address[] memory path) internal returns (address newTokenAddress, uint256 amountReturned) {
        emit Log("Swap, amount in: ", _amountIn);
        address _wethAddress = IUniswapV2Router01(qsRouter).WETH();

        if(isChef){
            require(IERC20(_tokenIn).balanceOf(address(this)) >= _amountIn, "Not enough tokens in contract to cover swap");
        } else {
            require(IERC20(_tokenIn).balanceOf(msg.sender) >= _amountIn, "Not enough tokens to cover swap");
            require(IERC20(_tokenIn).allowance(msg.sender, address(this)) >= _amountIn, "Not enough allowance of swap");
        }
        
        IERC20(_tokenIn).approve(qsRouter, _amountIn);
        
        if(_amountOut == 0){
            uint[] memory amounts = IUniswapV2Router02(qsRouter).getAmountsOut(_amountIn, path);
            
            try IUniswapV2Router02(qsRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(_amountIn, calculateFee(amounts[amounts.length - 1], acceptedSlippage), path, _to, block.timestamp) {
                    
            } catch {
                IUniswapV2Router02(qsRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(_amountIn, calculateFee(amounts[amounts.length - 1], acceptedSlippage), path, _to, block.timestamp);
            }
            
            _amountOut = amounts[amounts.length - 1];
        } else {
            try IUniswapV2Router02(qsRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(_amountIn, calculateFee(_amountOut, acceptedSlippage), path, _to, block.timestamp) {
                    
            } catch {
                IUniswapV2Router02(qsRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(_amountIn, calculateFee(_amountOut, acceptedSlippage), path, _to, block.timestamp);
            }
        }

        
        emit Log("Swap, amount out: ", _amountOut);
        
        return (_tokenOut, _amountOut);
    }
    
    function removeLiquidity(address _tokenA, address _tokenB, uint256 _amount) internal returns (uint256 a, uint256 b){
        return IUniswapV2Router01(qsRouter).removeLiquidity(
        _tokenA,
        _tokenB,
        _amount,
        0,
        0,
        address(this),
        block.timestamp);
    }
    
    function getLiquidityReserves(address tokenA, address tokenB) view internal returns (uint112 a, uint112 b) {
       (uint112 _a, uint112 _b,) = IUniswapV2Pair(IUniswapV2Factory(qsFactory).getPair(tokenA, tokenB)).getReserves();
       return (_a, _b);
    }
    
    function findPathUSDC(address _tokenIn) internal returns (address[] memory path){
            address _wethAddress = IUniswapV2Router01(qsRouter).WETH();

            if (_tokenIn == _wethAddress) {
                path = new address[](2);
                path[0] = _tokenIn;
                path[1] = usdc;
            } else {
                (,uint112 reserve) = getLiquidityReserves(_tokenIn, _wethAddress);
                
                if(reserve > 1000 ether){
                    path = new address[](3);
                    path[0] = _tokenIn;
                    path[1] = _wethAddress;
                    path[2] = usdc;
                } else {
                    path = new address[](2);
                    path[0] = _tokenIn;
                    path[1] = usdc;
                }
            }
            
            return path;
    }
    
    function findPath(address _tokenIn, address _tokenOut) internal returns (address[] memory path){
            address _wethAddress = IUniswapV2Router01(qsRouter).WETH();

            if (_tokenOut == _wethAddress || _tokenIn == address(bamboo) || _tokenOut == usdc || _tokenIn == usdc) {
                path = new address[](2);
                path[0] = _tokenIn;
                path[1] = _tokenOut;
            } else if(_tokenIn == _wethAddress){
                path = new address[](2);
                path[0] = _tokenIn;
                path[1] = usdc;
                path[2] = _tokenOut;
            } else {
                (,uint112 reserve) = getLiquidityReserves(_tokenIn, _wethAddress);
                
                if(reserve > 1000 ether){
                    path = new address[](4);
                    path[0] = _tokenIn;
                    path[1] = _wethAddress;
                    path[2] = usdc;
                    path[3] = _tokenOut;
                } else {
                    path = new address[](3);
                    path[0] = _tokenIn;
                    path[1] = usdc;
                    path[2] = _tokenOut;
                }
            }
            
            return path;
    }
    function calculateFee(uint amount, uint feePercent) internal pure returns (uint){
        return (amount / 10000) * feePercent;
    }
}