// SPDX-License-Identifier: BUSL
pragma solidity 0.8.19;

// libraries
import { LibMoneyMarket01 } from "../libraries/LibMoneyMarket01.sol";
import { LibSafeToken } from "../libraries/LibSafeToken.sol";
import { LibConstant } from "../libraries/LibConstant.sol";
import { LibReentrancyGuard } from "../libraries/LibReentrancyGuard.sol";

// interfaces
import { IFlashloanFacet } from "../interfaces/IFlashloanFacet.sol";
import { IAlpacaFlashloanCallback } from "../interfaces/IAlpacaFlashloanCallback.sol";
import { IERC20 } from "../interfaces/IERC20.sol";

contract FlashloanFacet is IFlashloanFacet {
  using LibSafeToken for IERC20;

  // error
  error FlashloanFacet_InvalidToken(address _token);
  error FlashloanFacet_NotEnoughToken(uint256 _amount);
  error FlashloanFacet_NotEnoughRepay();

  modifier nonReentrant() {
    LibReentrancyGuard.lock();
    _;
    LibReentrancyGuard.unlock();
  }

  /// @notice Receive token0 and/or token1 and pay it back, plus a fee, in the callback
  /// @dev The caller of this method receives a callback in the form of IAlpacaFlashloanCallback#alpacaFlashloanCallback
  /// @param _token The address of loan token
  /// @param _amount The amount of the loan token
  /// @param _data Any data to be passed through to the callback
  function flashloan(
    address _token,
    uint256 _amount,
    bytes calldata _data
  ) external nonReentrant {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    // expected fee = (_amount * feeBps) / maxBps
    uint256 _expectedFee = (_amount * moneyMarketDs.flashloanFeeBps) / LibConstant.MAX_BPS;

    // balance before
    uint256 _balanceBefore = IERC20(_token).balanceOf(address(this));
    IERC20(_token).safeTransfer(msg.sender, _amount);

    // call alpacaFlashloanCallback from msg.sender
    IAlpacaFlashloanCallback(msg.sender).alpacaFlashloanCallback(_token, _amount + _expectedFee, _data);

    // revert if actual fee < fee
    uint256 _actualTotalFee = IERC20(_token).balanceOf(address(this)) - _balanceBefore;
    if (_actualTotalFee < _expectedFee) {
      revert FlashloanFacet_NotEnoughRepay();
    }

    // 50% of fee add to reserve
    uint256 _lenderFee = (_expectedFee * moneyMarketDs.lenderFlashloanBps) / LibConstant.MAX_BPS;

    // lender fee (add on reserve)
    moneyMarketDs.reserves[_token] += _actualTotalFee;
    // transfer the rest of fee to protocol reserve
    moneyMarketDs.protocolReserves[_token] += _actualTotalFee - _lenderFee;
  }
}
