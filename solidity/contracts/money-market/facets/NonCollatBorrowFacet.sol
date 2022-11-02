// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// libs
import { LibMoneyMarket01 } from "../libraries/LibMoneyMarket01.sol";
import { LibDoublyLinkedList } from "../libraries/LibDoublyLinkedList.sol";
import { LibShareUtil } from "../libraries/LibShareUtil.sol";
import { LibFullMath } from "../libraries/LibFullMath.sol";

// interfaces
import { INonCollatBorrowFacet } from "../interfaces/INonCollatBorrowFacet.sol";

contract NonCollatBorrowFacet is INonCollatBorrowFacet {
  using SafeERC20 for ERC20;
  using LibDoublyLinkedList for LibDoublyLinkedList.List;

  event LogNonCollatRemoveDebt(
    address indexed _account,
    address indexed _token,
    uint256 _removeDebtAmount
  );

  event LogNonCollatRepay(
    address indexed _user,
    address indexed _token,
    uint256 _actualRepayAmount
  );

  function nonCollatBorrow(address _token, uint256 _amount) external {
    LibMoneyMarket01.MoneyMarketDiamondStorage
      storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    if (!moneyMarketDs.nonCollatBorrowerOk[msg.sender]) {
      revert NonCollatBorrowFacet_Unauthorized();
    }

    _validate(msg.sender, _token, _amount, moneyMarketDs);

    LibDoublyLinkedList.List storage debtValue = moneyMarketDs
      .nonCollatAccountDebtValues[msg.sender];

    if (
      debtValue.getNextOf(LibDoublyLinkedList.START) ==
      LibDoublyLinkedList.EMPTY
    ) {
      debtValue.init();
    }

    LibDoublyLinkedList.List storage tokenDebts = moneyMarketDs
      .nonCollatTokenDebtValues[_token];

    if (
      tokenDebts.getNextOf(LibDoublyLinkedList.START) ==
      LibDoublyLinkedList.EMPTY
    ) {
      tokenDebts.init();
    }

    uint256 _newAccountDebt = debtValue.getAmount(_token) + _amount;
    uint256 _newGlobalDebt = tokenDebts.getAmount(msg.sender) + _amount;

    debtValue.addOrUpdate(_token, _newAccountDebt);

    tokenDebts.addOrUpdate(msg.sender, _newGlobalDebt);

    ERC20(_token).safeTransfer(msg.sender, _amount);
  }

  function nonCollatRepay(
    address _account,
    address _token,
    uint256 _repayAmount
  ) external {
    LibMoneyMarket01.MoneyMarketDiamondStorage
      storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    uint256 _oldDebtValue = _getDebt(_account, _token, moneyMarketDs);

    uint256 _debtToRemove = _oldDebtValue > _repayAmount
      ? _repayAmount
      : _oldDebtValue;

    _removeDebt(_account, _token, _oldDebtValue, _debtToRemove, moneyMarketDs);

    // transfer only amount to repay
    ERC20(_token).safeTransferFrom(msg.sender, address(this), _debtToRemove);

    emit LogNonCollatRepay(_account, _token, _debtToRemove);
  }

  function nonCollatGetDebtValues(address _account)
    external
    view
    returns (LibDoublyLinkedList.Node[] memory)
  {
    LibMoneyMarket01.MoneyMarketDiamondStorage
      storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    LibDoublyLinkedList.List storage debtShares = moneyMarketDs
      .nonCollatAccountDebtValues[_account];

    return debtShares.getAll();
  }

  function nonCollatGetDebt(address _account, address _token)
    external
    view
    returns (uint256 _debtAmount)
  {
    LibMoneyMarket01.MoneyMarketDiamondStorage
      storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    _debtAmount = _getDebt(_account, _token, moneyMarketDs);
  }

  function _getDebt(
    address _account,
    address _token,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal view returns (uint256 _debtAmount) {
    _debtAmount = moneyMarketDs.nonCollatAccountDebtValues[_account].getAmount(
      _token
    );
  }

  function nonCollatGetTokenDebt(address _token)
    external
    view
    returns (uint256)
  {
    LibMoneyMarket01.MoneyMarketDiamondStorage
      storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    return LibMoneyMarket01.getNonCollatTokenDebt(_token, moneyMarketDs);
  }

  function _removeDebt(
    address _account,
    address _token,
    uint256 _oldAccountDebtValue,
    uint256 _valueToRemove,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal {
    // update user debtShare
    moneyMarketDs.nonCollatAccountDebtValues[_account].updateOrRemove(
      _token,
      _oldAccountDebtValue - _valueToRemove
    );

    uint256 _oldGlobalDebt = moneyMarketDs
      .nonCollatTokenDebtValues[_token]
      .getAmount(_account);

    // update global debt
    moneyMarketDs.nonCollatTokenDebtValues[_token].updateOrRemove(
      _account,
      _oldGlobalDebt - _valueToRemove
    );

    // emit event
    emit LogNonCollatRemoveDebt(_account, _token, _valueToRemove);
  }

  function _validate(
    address _account,
    address _token,
    uint256 _amount,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal view {
    address _ibToken = moneyMarketDs.tokenToIbTokens[_token];

    // check open market
    if (_ibToken == address(0)) {
      revert NonCollatBorrowFacet_InvalidToken(_token);
    }

    // check credit
    // TODO: use the correct state vars
    uint256 _totalBorrowingPowerUSDValue = 1e30;

    (uint256 _totalBorrowedUSDValue, ) = LibMoneyMarket01
      .getTotalUsedBorrowedPower(_account, moneyMarketDs);

    _checkBorrowingPower(
      _totalBorrowingPowerUSDValue,
      _totalBorrowedUSDValue,
      _token,
      _amount,
      moneyMarketDs
    );

    _checkAvailableToken(_token, _amount, moneyMarketDs);
  }

  // TODO: handle token decimal when calculate value
  // TODO: gas optimize on oracle call
  function _checkBorrowingPower(
    uint256 _borrowingPower,
    uint256 _borrowedValue,
    address _token,
    uint256 _amount,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal view {
    // TODO: get tokenPrice from oracle
    uint256 _tokenPrice = 1e18;

    LibMoneyMarket01.TokenConfig memory _tokenConfig = moneyMarketDs
      .tokenConfigs[_token];

    uint256 _borrowingUSDValue = LibFullMath.mulDiv(
      _amount * (LibMoneyMarket01.MAX_BPS + _tokenConfig.borrowingFactor),
      _tokenPrice,
      1e22
    );

    if (_borrowingPower < _borrowedValue + _borrowingUSDValue) {
      revert NonCollatBorrowFacet_BorrowingValueTooHigh(
        _borrowingPower,
        _borrowedValue,
        _borrowingUSDValue
      );
    }
  }

  function _checkAvailableToken(
    address _token,
    uint256 _borrowAmount,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal view {
    uint256 _mmTokenBalnce = ERC20(_token).balanceOf(address(this)) -
      moneyMarketDs.collats[_token];

    if (_mmTokenBalnce < _borrowAmount) {
      revert NonCollatBorrowFacet_NotEnoughToken(_borrowAmount);
    }

    // TODO: use the correct state vars
    if (_borrowAmount > moneyMarketDs.tokenConfigs[_token].maxBorrow) {
      revert NonCollatBorrowFacet_ExceedBorrowLimit();
    }
  }

  function nonCollatGetTotalUsedBorrowedPower(address _account)
    external
    view
    returns (uint256 _totalBorrowedUSDValue, bool _hasIsolateAsset)
  {
    LibMoneyMarket01.MoneyMarketDiamondStorage
      storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    // TODO: use the correct state vars
    (_totalBorrowedUSDValue, _hasIsolateAsset) = LibMoneyMarket01
      .getTotalUsedBorrowedPower(_account, moneyMarketDs);
  }
}