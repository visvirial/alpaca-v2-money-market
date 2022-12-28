// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ILiquidationStrategy } from "../../contracts/money-market/interfaces/ILiquidationStrategy.sol";
import { LibSafeToken } from "../../contracts/money-market/libraries/LibSafeToken.sol";

import { MockAlpacaV2Oracle } from "../mocks/MockAlpacaV2Oracle.sol";

contract MockLiquidationStrategy is ILiquidationStrategy {
  using SafeERC20 for ERC20;

  MockAlpacaV2Oracle internal _mockOracle;

  constructor(address _oracle) {
    _mockOracle = MockAlpacaV2Oracle(_oracle);
  }

  /// @dev swap collat for exact repay amount and send remaining collat to caller
  function executeLiquidation(
    address _collatToken,
    address _repayToken,
    uint256 _repayAmount,
    address _repayTo,
    bytes calldata /* _data */
  ) external {
    (uint256 _collatPrice, ) = _mockOracle.getTokenPrice(_collatToken);
    (uint256 _repayTokenPrice, ) = _mockOracle.getTokenPrice(_repayToken);

    uint256 _priceCollatPerRepayToken = (_collatPrice * 1e18) / _repayTokenPrice;

    uint256 _collatAmountBefore = ERC20(_collatToken).balanceOf(address(this));
    uint256 _collatSold = (_repayAmount * 10**ERC20(_repayToken).decimals()) / _priceCollatPerRepayToken;
    uint256 _actualCollatSold = _collatSold > _collatAmountBefore ? _collatAmountBefore : _collatSold;
    uint256 _actualRepayAmount = (_actualCollatSold * _priceCollatPerRepayToken) / 10**ERC20(_collatToken).decimals();

    ERC20(_repayToken).safeTransfer(_repayTo, _actualRepayAmount);
    ERC20(_collatToken).safeTransfer(_repayTo, _collatAmountBefore - _actualCollatSold);
  }
}
