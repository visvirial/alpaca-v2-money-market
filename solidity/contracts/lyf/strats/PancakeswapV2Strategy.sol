// SPDX-License-Identifier: BUSL
/**
  ∩~~~~∩ 
  ξ ･×･ ξ 
  ξ　~　ξ 
  ξ　　 ξ 
  ξ　　 “~～~～〇 
  ξ　　　　　　 ξ 
  ξ ξ ξ~～~ξ ξ ξ 
　 ξ_ξξ_ξ　ξ_ξξ_ξ
Alpaca Fin Corporation
*/

pragma solidity 0.8.17;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IPancakeRouter02 } from "../interfaces/IPancakeRouter02.sol";
import { IPancakePair } from "../interfaces/IPancakePair.sol";
import { IStrat } from "../interfaces/IStrat.sol";

import { LibFullMath } from "../libraries/LibFullMath.sol";
import { LibSafeToken } from "../libraries/LibSafeToken.sol";

// todo: reentrance
contract PancakeswapV2Strategy is IStrat, Ownable {
  using SafeERC20 for address;
  using LibSafeToken for address;

  mapping(address => bool) public whitelistedCallers;

  error PancakeswapV2Strategy_TooLittleReceived();
  error PancakeswapV2Strategy_TransferFailed();
  error PancakeswapV2Strategy_Reverse();
  error PancakeswapV2Strategy_Unauthorized(address _caller);

  IPancakeRouter02 public router;

  /// @dev Create a new add two-side optimal strategy instance.
  /// @param _router The PancakeSwap Router smart contract.
  constructor(IPancakeRouter02 _router) {
    router = _router;
  }

  modifier onlyWhitelisted() {
    if (!whitelistedCallers[msg.sender]) {
      revert PancakeswapV2Strategy_Unauthorized(msg.sender);
    }
    _;
  }

  /// @dev Compute optimal deposit amount
  /// @param amtA amount of token A desired to deposit
  /// @param amtB amonut of token B desired to deposit
  /// @param resA amount of token A in reserve
  /// @param resB amount of token B in reserve
  function optimalDeposit(
    uint256 amtA,
    uint256 amtB,
    uint256 resA,
    uint256 resB
  ) internal pure returns (uint256 swapAmt, bool isReversed) {
    if (amtA * resB >= amtB * resA) {
      swapAmt = _optimalDepositA(amtA, amtB, resA, resB);
      isReversed = false;
    } else {
      swapAmt = _optimalDepositA(amtB, amtA, resB, resA);
      isReversed = true;
    }
  }

  /// @dev Compute optimal deposit amount helper
  /// @param amtA amount of token A desired to deposit
  /// @param amtB amonut of token B desired to deposit
  /// @param resA amount of token A in reserve
  /// @param resB amount of token B in reserve
  function _optimalDepositA(
    uint256 amtA,
    uint256 amtB,
    uint256 resA,
    uint256 resB
  ) internal pure returns (uint256) {
    if (amtA * (resB) < amtB * (resA)) {
      revert PancakeswapV2Strategy_Reverse();
    }

    uint256 a = 9975;
    uint256 b = uint256(19975) * (resA);
    uint256 _c = (amtA * (resB)) - (amtB * (resA));
    uint256 c = ((_c * (10000)) / (amtB + (resB))) * (resA);

    uint256 d = a * (c) * (4);
    uint256 e = LibFullMath.sqrt(b * (b) + (d));

    uint256 numerator = e - (b);
    uint256 denominator = a * (2);

    return numerator / (denominator);
  }

  function composeLPToken(
    address _token0,
    address _token1,
    address _lpToken,
    uint256 _token0Amount,
    uint256 _token1Amount,
    uint256 _minLPAmount
  ) external onlyWhitelisted returns (uint256 _lpRecieved) {
    IPancakePair lpToken = IPancakePair(_lpToken);
    // 1. Approve router to do their stuffs
    ERC20(_token0).approve(address(router), type(uint256).max);
    ERC20(_token1).approve(address(router), type(uint256).max);
    // 2. Compute the optimal amount of BaseToken and FarmingToken to be converted.

    uint256 swapAmt;
    bool isReversed;
    {
      (uint256 r0, uint256 r1, ) = lpToken.getReserves();
      (swapAmt, isReversed) = optimalDeposit(_token0Amount, _token1Amount, r0, r1);
    }
    // 3. Convert between BaseToken and farming tokens
    address[] memory path = new address[](2);
    (path[0], path[1]) = isReversed ? (_token1, _token0) : (_token0, _token1);
    // 4. Swap according to path
    if (swapAmt > 0) router.swapExactTokensForTokens(swapAmt, 0, path, address(this), block.timestamp);
    // 5. Mint more LP tokens and return all LP tokens to the sender.
    (, , uint256 moreLPAmount) = router.addLiquidity(
      _token0,
      _token1,
      ERC20(_token0).balanceOf(address(this)),
      ERC20(_token1).balanceOf(address(this)),
      0,
      0,
      address(this),
      block.timestamp
    );
    if (moreLPAmount < _minLPAmount) {
      revert PancakeswapV2Strategy_TooLittleReceived();
    }
    // return parameter
    _lpRecieved = lpToken.balanceOf(address(this));

    if (!lpToken.transfer(msg.sender, _lpRecieved)) {
      revert PancakeswapV2Strategy_TransferFailed();
    }
    // 7. Reset approve to 0 for safety reason
    ERC20(_token0).approve(address(router), 0);
    ERC20(_token1).approve(address(router), 0);
  }

  function removeLiquidity(address _lpToken)
    external
    onlyWhitelisted
    returns (uint256 _token0Return, uint256 _token1Return)
  {
    uint256 _lpToRemove = ERC20(_lpToken).balanceOf(address(this));

    ERC20(_lpToken).approve(address(router), type(uint256).max);

    address _token0 = IPancakePair(_lpToken).token0();
    address _token1 = IPancakePair(_lpToken).token1();

    router.removeLiquidity(_token0, _token1, _lpToRemove, 0, 0, address(this), block.timestamp);

    _token0Return = ERC20(_token0).balanceOf(address(this));
    _token1Return = ERC20(_token1).balanceOf(address(this));

    _token0.safeTransfer(msg.sender, _token0Return);
    _token1.safeTransfer(msg.sender, _token1Return);

    ERC20(_lpToken).approve(address(router), 0);
  }

  function setWhitelistedCallers(address[] calldata callers, bool ok) external onlyOwner {
    uint256 len = uint256(callers.length);
    for (uint256 i = 0; i < len; ) {
      whitelistedCallers[callers[i]] = ok;
      unchecked {
        i++;
      }
    }
  }

  receive() external payable {}
}