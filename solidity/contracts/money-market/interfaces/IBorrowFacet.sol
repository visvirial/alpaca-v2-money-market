// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { LibDoublyLinkedList } from "../libraries/LibDoublyLinkedList.sol";

interface IBorrowFacet {
  function borrow(
    address _account,
    uint256 _subAccountId,
    address _token,
    uint256 _amount
  ) external;

  function getDebtShares(address _account, uint256 _subAccountId)
    external
    view
    returns (LibDoublyLinkedList.Node[] memory);

  function getTotalBorrowingPowerUSDValue(
    address _account,
    uint256 _subAccountId
  ) external view returns (uint256 _totalBorrowingPowerUSDValue);

  function getTotalBorrowedUSDValue(address _account, uint256 _subAccountId)
    external
    view
    returns (uint256 _totalBorrowedUSDValue, bool _hasIsolateAsset);

  // Errors
  error BorrowFacet_InvalidToken(address _token);
  error BorrowFacet_NotEnoughToken(uint256 _borrowAmount);
  error BorrowFacet_BorrowingValueTooHigh(
    uint256 _totalBorrowingPowerUSDValue,
    uint256 _totalBorrowedUSDValue,
    uint256 _borrowingUSDValue
  );
  error BorrowFacet_InvalidAssetTier();
}