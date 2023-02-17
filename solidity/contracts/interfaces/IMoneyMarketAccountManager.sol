// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

interface IMoneyMarketAccountManager {
  function deposit(address _token, uint256 _amount) external;

  function withdraw(address _ibToken, uint256 _ibAmount) external;

  function addCollateralFor(
    address _account,
    uint256 _subAccountId,
    address _token,
    uint256 _amount
  ) external;

  function removeCollateral(
    uint256 _subAccountId,
    address _token,
    uint256 _amount
  ) external;

  function transferCollateral(
    uint256 _fromSubAccountId,
    uint256 _toSubAccountId,
    address _token,
    uint256 _amount
  ) external;

  function depositAndAddCollateral(
    uint256 _subAccountId,
    address _token,
    uint256 _amount
  ) external;

  function removeCollateralAndWithdraw(
    uint256 _subAccountId,
    address _ibToken,
    uint256 _ibAmount
  ) external;

  function depositAndStake(address _token, uint256 _amount) external;

  function unstakeAndWithdraw(address _ibToken, uint256 _amount) external;

  function borrow(
    uint256 _subAccountId,
    address _token,
    uint256 _amount
  ) external;

  function repayFor(
    address _account,
    uint256 _subAccountId,
    address _token,
    uint256 _repayAmount,
    uint256 _debtShareToRepay
  ) external;

  function repayWithCollat(
    uint256 _subAccountId,
    address _token,
    uint256 _debtShareAmount
  ) external;
}