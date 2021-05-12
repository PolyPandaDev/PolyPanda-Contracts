// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.6.0 <0.8.0;

import "./math/SafeMath.sol";
import "./token/ERC20/ERC20.sol";
import "./access/Ownable.sol";
import "./ERC20Burnable.sol";
import "./IUniswapV2Factory.sol";

contract Bamboo is ERC20("PolyPanda", "Bamboo"), ERC20Burnable, Ownable {
    using SafeMath for uint256;
    
    address public usdcContract;
    address public qsFactory;

    event LogTx(string msg, uint256 value);
    event LogMsg(string msg);

    constructor (address _usdcContract, address _qsFactory, address _qsRouter, uint256 _burnFee){
        usdcContract = _usdcContract;
        qsFactory = _qsFactory;
        qsRouter = _qsRouter;
        burnFee = _burnFee;
    }

    function mint(address _to, uint256 _amount) public onlyOwner {
        emit LogTx("Minted ", _amount);
        
        _mint(_to, _amount);
    }
    
    //adds lp pair to quickswap
    //do this AFTER liquidity has been added
    function updateLpPair(address _lpAdd) public onlyOwner {
        unilpAddress = _lpAdd;
    }
    
    function setUsdcContract(address _contract) public onlyOwner {
        usdcContract = _contract;
    }
    
    function setRouterContract(address _contract) public onlyOwner {
        qsRouter = _contract;
    }
    
    function setFactoryContract(address _contract) public onlyOwner {
        qsFactory = _contract;
    }
    
    //Has to be done before transferring ownership
    function setMasterChef(address _contract) public onlyOwner {
        masterChefAddress = _contract;
    }
}