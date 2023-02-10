// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

// ---- External Libraries ---- //
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

// ---- Libraries ---- //
import { LibMoneyMarket01 } from "../libraries/LibMoneyMarket01.sol";
import { LibShareUtil } from "../libraries/LibShareUtil.sol";
import { LibSafeToken } from "../libraries/LibSafeToken.sol";
import { LibReentrancyGuard } from "../libraries/LibReentrancyGuard.sol";

// ---- Interfaces ---- //
import { ILendFacet } from "../interfaces/ILendFacet.sol";
import { IAdminFacet } from "../interfaces/IAdminFacet.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { IWNative } from "../interfaces/IWNative.sol";
import { IWNativeRelayer } from "../interfaces/IWNativeRelayer.sol";
import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { IInterestBearingToken } from "../interfaces/IInterestBearingToken.sol";

/// @title LendFacet is dedicated for depositing and withdrawing token for lending
contract LendFacet is ILendFacet {
  using LibSafeToken for IERC20;

  event LogDeposit(
    address indexed _for,
    address _caller,
    address _token,
    address _ibToken,
    uint256 _amountIn,
    uint256 _amountOut
  );
  event LogWithdraw(address indexed _user, address _token, address _ibToken, uint256 _amountIn, uint256 _amountOut);

  modifier nonReentrant() {
    LibReentrancyGuard.lock();
    _;
    LibReentrancyGuard.unlock();
  }

  modifier nonReentrantWithdraw() {
    LibReentrancyGuard.lockWithdraw();
    _;
    LibReentrancyGuard.unlock();
  }

  /// @notice Deposit a token for lending
  /// @param _for The actual lender
  /// @param _token The token to lend
  /// @param _amount The amount to lend
  function deposit(
    address _for,
    address _token,
    uint256 _amount
  ) external nonReentrant {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    // This will revert if markets are paused
    LibMoneyMarket01.onlyLive(moneyMarketDs);

    // This function should not be called from anyone
    // except account manager contract and will revert upon trying to do so
    LibMoneyMarket01.onlyAccountManager(moneyMarketDs);

    address _ibToken = moneyMarketDs.tokenToIbTokens[_token];
    if (_ibToken == address(0)) {
      revert LendFacet_InvalidToken(_token);
    }

    LibMoneyMarket01.accrueInterest(_token, moneyMarketDs);

    (, uint256 _shareToMint) = LibMoneyMarket01.getShareAmountFromValue(_token, _ibToken, _amount, moneyMarketDs);

    moneyMarketDs.reserves[_token] += _amount;

    LibMoneyMarket01.pullExactTokens(_token, msg.sender, _amount);
    IInterestBearingToken(_ibToken).onDeposit(msg.sender, _amount, _shareToMint);

    // _for is purely used for event tracking purpose
    // since this function will be called from only AccountManager
    // we need a way to track the actual lender
    emit LogDeposit(_for, msg.sender, _token, _ibToken, _amount, _shareToMint);
  }

  /// @notice Withdraw the lended token by burning the interest bearing token
  /// @param _ibToken The interest bearing token to burn
  /// @param _shareAmount The amount of interest bearing token to burn
  function withdraw(address _ibToken, uint256 _shareAmount)
    external
    nonReentrantWithdraw
    returns (uint256 _withdrawAmount)
  {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    // This function should not be called from anyone
    // except account manager contract and will revert upon trying to do so
    LibMoneyMarket01.onlyAccountManager(moneyMarketDs);

    address _underlyingToken = moneyMarketDs.ibTokenToTokens[_ibToken];

    if (_underlyingToken == address(0)) {
      revert LendFacet_InvalidToken(_ibToken);
    }

    LibMoneyMarket01.accrueInterest(_underlyingToken, moneyMarketDs);

    _withdrawAmount = LibMoneyMarket01.withdraw(_underlyingToken, _ibToken, _shareAmount, msg.sender, moneyMarketDs);

    moneyMarketDs.reserves[_underlyingToken] -= _withdrawAmount;

    IERC20(_underlyingToken).safeTransfer(msg.sender, _withdrawAmount);
  }
}
