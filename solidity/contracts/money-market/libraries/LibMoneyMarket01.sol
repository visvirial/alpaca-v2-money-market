// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { LibDoublyLinkedList } from "./LibDoublyLinkedList.sol";
import { LibFullMath } from "./LibFullMath.sol";
import { LibShareUtil } from "./LibShareUtil.sol";

library LibMoneyMarket01 {
  using LibDoublyLinkedList for LibDoublyLinkedList.List;

  // keccak256("moneymarket.diamond.storage");
  bytes32 internal constant MONEY_MARKET_STORAGE_POSITION =
    0x2758c6926500ec9dc8ab8cea4053d172d4f50d9b78a6c2ee56aa5dd18d2c800b;

  error LibMoneyMarket01_BadSubAccountId();

  // Storage
  struct MoneyMarketDiamondStorage {
    mapping(address => address) tokenToIbTokens;
    mapping(address => address) ibTokenToTokens;
    mapping(address => uint256) debtValues;
    mapping(address => uint256) debtShares;
    mapping(address => uint256) collats;
    mapping(address => LibDoublyLinkedList.List) subAccountCollats;
    mapping(address => LibDoublyLinkedList.List) subAccountDebtShares;
    address oracle;
  }

  function moneyMarketDiamondStorage()
    internal
    pure
    returns (MoneyMarketDiamondStorage storage moneyMarketStorage)
  {
    assembly {
      moneyMarketStorage.slot := MONEY_MARKET_STORAGE_POSITION
    }
  }

  function getSubAccount(address primary, uint256 subAccountId)
    internal
    pure
    returns (address)
  {
    if (subAccountId > 255) revert LibMoneyMarket01_BadSubAccountId();
    return address(uint160(primary) ^ uint160(subAccountId));
  }

  function getTotalBorrowingPowerUSDValue(
    address _subAccount,
    MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal view returns (uint256 _totalBorrowingPowerUSDValue) {
    LibDoublyLinkedList.Node[] memory _collats = moneyMarketDs
      .subAccountCollats[_subAccount]
      .getAll();

    uint256 _collatsLength = _collats.length;

    for (uint256 _i = 0; _i < _collatsLength; ) {
      // TODO: get tokenPrice from oracle
      uint256 _tokenPrice = 1e18;
      // TODO: add collateral factor
      _totalBorrowingPowerUSDValue += LibFullMath.mulDiv(
        _collats[_i].amount,
        _tokenPrice,
        1e18
      );

      unchecked {
        _i++;
      }
    }
  }

  function getTotalBorrowedUSDValue(
    address _subAccount,
    MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal view returns (uint256 _totalBorrowedUSDValue) {
    LibDoublyLinkedList.Node[] memory _borrowed = moneyMarketDs
      .subAccountDebtShares[_subAccount]
      .getAll();

    uint256 _borrowedLength = _borrowed.length;

    for (uint256 _i = 0; _i < _borrowedLength; ) {
      // TODO: get tokenPrice from oracle
      uint256 _tokenPrice = 1e18;
      uint256 _borrowedAmount = LibShareUtil.shareToValue(
        moneyMarketDs.debtShares[_borrowed[_i].token],
        _borrowed[_i].amount,
        moneyMarketDs.debtValues[_borrowed[_i].token]
      );

      // TODO: add borrow factor
      _totalBorrowedUSDValue += LibFullMath.mulDiv(
        _borrowedAmount,
        _tokenPrice,
        1e18
      );

      unchecked {
        _i++;
      }
    }
  }
}
