// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.6.0 <0.8.0;

import "@openzeppelin/contracts@3.4.0/math/SafeMath.sol";
import "@openzeppelin/contracts@3.4.0/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts@3.4.0/access/Ownable.sol";
import "./ERC20Burnable.sol";

contract Bamboo is ERC20("trash", "trash"), ERC20Burnable, Ownable {

    constructor (){
    }

    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);
    }
}