// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { LibFullMath } from "./LibFullMath.sol";

library LibShareUtil {
  function shareToValue(
    uint256 _totalShare,
    uint256 _shareAmount,
    uint256 _totalValue
  ) public pure returns (uint256) {
    if (_totalShare == 0) return _shareAmount;
    return LibFullMath.mulDiv(_shareAmount, _totalValue, _totalShare);
  }

  function valueToShare(
    uint256 _totalShare,
    uint256 _tokenAmount,
    uint256 _totalValue
  ) internal pure returns (uint256) {
    if (_totalShare == 0) return _tokenAmount;
    return LibFullMath.mulDiv(_tokenAmount, _totalShare, _totalValue);
  }
}