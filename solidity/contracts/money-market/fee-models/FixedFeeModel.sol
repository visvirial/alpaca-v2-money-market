// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

// interfaces
import { IFeeModel } from "../interfaces/IFeeModel.sol";

contract FixedFeeModel is IFeeModel {
  /// @notice Get a static fee
  function getFeeBps(
    uint256, /*_total*/
    uint256 /*_used*/
  ) external pure returns (uint256 _interestRate) {
    return 100;
  }
}
