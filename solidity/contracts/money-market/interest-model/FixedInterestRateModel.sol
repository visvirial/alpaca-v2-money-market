// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

// interfaces
import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";

contract FixedInterestRateModel is IInterestRateModel {
  /// @dev Return a static interest rate per second = 0.1
  function getInterestRate(
    uint256 debt,
    uint256 /*floating*/
  ) external pure returns (uint256 _interestRate) {
    _interestRate = debt == 0 ? 0 : 1e17;
  }
}