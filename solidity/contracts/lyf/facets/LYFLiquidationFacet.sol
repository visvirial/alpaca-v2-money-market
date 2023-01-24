// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

// libraries
import { LibLYF01 } from "../libraries/LibLYF01.sol";
import { LibDoublyLinkedList } from "../libraries/LibDoublyLinkedList.sol";
import { LibUIntDoublyLinkedList } from "../libraries/LibUIntDoublyLinkedList.sol";
import { LibShareUtil } from "../libraries/LibShareUtil.sol";
import { LibReentrancyGuard } from "../libraries/LibReentrancyGuard.sol";
import { LibSafeToken } from "../libraries/LibSafeToken.sol";

// interfaces
import { ILYFLiquidationFacet } from "../interfaces/ILYFLiquidationFacet.sol";
import { ILiquidationStrategy } from "../interfaces/ILiquidationStrategy.sol";
import { IMoneyMarket } from "../interfaces/IMoneyMarket.sol";
import { ISwapPairLike } from "../interfaces/ISwapPairLike.sol";
import { IMasterChefLike } from "../interfaces/IMasterChefLike.sol";
import { IStrat } from "../interfaces/IStrat.sol";
import { IERC20 } from "../interfaces/IERC20.sol";

import { console } from "../../../tests/utils/console.sol";

contract LYFLiquidationFacet is ILYFLiquidationFacet {
  using LibSafeToken for IERC20;
  using LibDoublyLinkedList for LibDoublyLinkedList.List;
  using LibUIntDoublyLinkedList for LibUIntDoublyLinkedList.List;

  // todo: move to state
  uint256 constant REPURCHASE_FEE_BPS = 100;
  uint256 constant REPURCHASE_REWARD_BPS = 100;
  uint256 constant LIQUIDATION_FEE_BPS = 100;
  uint256 constant MAX_LIQUIDATE_BPS = 5000;

  event LogRepurchase(
    address indexed repurchaser,
    address _repayToken,
    address _collatToken,
    uint256 _amountIn,
    uint256 _amountOut
  );

  event LogLiquidateIb(
    address indexed liquidator,
    address _strat,
    address _repayToken,
    address _collatToken,
    uint256 _amountIn,
    uint256 _amountOut,
    uint256 _feeToTreasury
  );

  event LogLiquidate(
    address indexed liquidator,
    address _strat,
    address _repayToken,
    address _collatToken,
    uint256 _amountIn,
    uint256 _amountOut,
    uint256 _feeToTreasury
  );

  event LogLiquidateLP(
    address indexed liquidator,
    address _account,
    uint256 _subAccountId,
    address _lpToken,
    uint256 _lpSharesToLiquidate,
    uint256 _amount0Repaid,
    uint256 _amount1Repaid,
    uint256 _remainingAmount0AfterRepay,
    uint256 _remainingAmount1AfterRepay
  );

  struct InternalLiquidationCallParams {
    address liquidationStrat;
    address subAccount;
    address repayToken;
    address collatToken;
    uint256 repayAmount;
    uint256 debtShareId;
    uint256 minReceive;
  }

  struct LiquidateLPLocalVars {
    address subAccount;
    address token0;
    address token1;
    uint256 debtShareId0;
    uint256 debtShareId1;
    uint256 token0Return;
    uint256 token1Return;
    uint256 actualAmount0ToRepay;
    uint256 actualAmount1ToRepay;
    uint256 remainingAmount0AfterRepay;
    uint256 remainingAmount1AfterRepay;
  }

  modifier nonReentrant() {
    LibReentrancyGuard.lock();
    _;
    LibReentrancyGuard.unlock();
  }

  function repurchase(
    address _account,
    uint256 _subAccountId,
    address _debtToken,
    address _collatToken,
    address _lpToken,
    uint256 _desiredAmountToRepay,
    uint256 _minCollatOut
  ) external nonReentrant returns (uint256 _collatAmountOut) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    address _subAccount = LibLYF01.getSubAccount(_account, _subAccountId);
    uint256 _debtShareId = lyfDs.debtShareIds[_debtToken][_lpToken];

    // accrue interest for all debt tokens which are under subaccount
    LibLYF01.accrueDebtSharesOf(_subAccount, lyfDs);

    // health check sub account borrowing power
    {
      uint256 _borrowingPower = LibLYF01.getTotalBorrowingPower(_subAccount, lyfDs);
      uint256 _borrowedValue = LibLYF01.getTotalBorrowedUSDValue(_subAccount, lyfDs);
      if (_borrowingPower > _borrowedValue) {
        revert LYFLiquidationFacet_Healthy();
      }
    }

    // maximum amount to repay is sub account debt value
    uint256 _actualAmountToRepay = _desiredAmountToRepay;
    {
      uint256 _currentSubAccountDebtShare = lyfDs.subAccountDebtShares[_subAccount].getAmount(_debtShareId);
      uint256 _currentSubAccountDebtValue = LibShareUtil.shareToValue(
        _currentSubAccountDebtShare,
        lyfDs.debtValues[_debtShareId],
        lyfDs.debtShares[_debtShareId]
      );

      // calculate debt value with fee is max possible that caller can repay
      uint256 _maxAmountToRepay = (_currentSubAccountDebtValue * (REPURCHASE_FEE_BPS + LibLYF01.MAX_BPS)) /
        LibLYF01.MAX_BPS;

      _actualAmountToRepay = _desiredAmountToRepay;

      // if desired amount > max amount to repay, then repay with max amount
      if (_desiredAmountToRepay > _maxAmountToRepay) {
        _actualAmountToRepay = _maxAmountToRepay;
      }
    }

    console.log("_actualAmountToRepay", _actualAmountToRepay);

    // check how much borrowing power reduced after repay with _actualAmountToRepay
    {
      LibLYF01.TokenConfig memory _debtTokenConfig = lyfDs.tokenConfigs[_debtToken];
      uint256 _repaidBorrowingPower = LibLYF01.usedBorrowingPower(
        _actualAmountToRepay,
        LibLYF01.getPriceUSD(_debtToken, lyfDs),
        _debtTokenConfig.borrowingFactor,
        _debtTokenConfig.to18ConversionFactor
      );
      // todo: description
      uint256 _borrowedValue = LibLYF01.getTotalBorrowedUSDValue(_subAccount, lyfDs);
      if (_repaidBorrowingPower * LibLYF01.MAX_BPS > _borrowedValue * MAX_LIQUIDATE_BPS) {
        revert LYFLiquidationFacet_RepayDebtValueTooHigh();
      }
    }

    {
      // repurchaser should receive collat amount base on repaid value + premium
      uint256 _repayTokenPriceWithPremium = (LibLYF01.getPriceUSD(_debtToken, lyfDs) *
        (LibLYF01.MAX_BPS + REPURCHASE_REWARD_BPS)) / LibLYF01.MAX_BPS;

      console.log("_repayTokenPriceWithPremium", _repayTokenPriceWithPremium);

      _collatAmountOut =
        ((_actualAmountToRepay * _repayTokenPriceWithPremium * lyfDs.tokenConfigs[_debtToken].to18ConversionFactor) /
          LibLYF01.getPriceUSD(_collatToken, lyfDs)) *
        lyfDs.tokenConfigs[_collatToken].to18ConversionFactor;

      if (_minCollatOut > _collatAmountOut) {
        revert LYFLiquidationFacet_TooLittleReceived();
      }

      if (_collatAmountOut > lyfDs.subAccountCollats[_subAccount].getAmount(_collatToken)) {
        revert LYFLiquidationFacet_InsufficientAmount();
      }
    }

    console.log("_collatAmountOut", _collatAmountOut);

    // pull token and use that to repay without fee
    // collat out calculate from repay with fee and premium

    // transfer
    uint256 _fee = (_actualAmountToRepay * REPURCHASE_FEE_BPS) / (REPURCHASE_FEE_BPS + LibLYF01.MAX_BPS);
    uint256 _x = _actualAmountToRepay - _fee;

    console.log("_x", _x);
    console.log("_fee", _fee);

    IERC20(_debtToken).safeTransferFrom(msg.sender, address(this), _x);
    IERC20(_debtToken).safeTransferFrom(msg.sender, lyfDs.treasury, _fee);
    IERC20(_collatToken).safeTransfer(msg.sender, _collatAmountOut);

    // reduce debt with repaid amount
    if (_x > 0) {
      _removeDebtByAmount(_subAccount, _debtShareId, _x, lyfDs);
    }
    LibLYF01.removeCollateral(_subAccount, _collatToken, _collatAmountOut, lyfDs);

    emit LogRepurchase(msg.sender, _debtToken, _collatToken, _x, _collatAmountOut);
  }

  function liquidationCall(
    address _liquidationStrat,
    address _account,
    uint256 _subAccountId,
    address _repayToken,
    address _collatToken,
    address _lpToken,
    uint256 _repayAmount,
    uint256 _minReceive
  ) external nonReentrant {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    if (!lyfDs.liquidationStratOk[_liquidationStrat] || !lyfDs.liquidationCallersOk[msg.sender]) {
      revert LYFLiquidationFacet_Unauthorized();
    }

    address _subAccount = LibLYF01.getSubAccount(_account, _subAccountId);
    uint256 _debtShareId = lyfDs.debtShareIds[_repayToken][_lpToken];

    LibLYF01.accrueDebtSharesOf(_subAccount, lyfDs);

    // 1. check if position is underwater and can be liquidated
    {
      uint256 _borrowingPower = LibLYF01.getTotalBorrowingPower(_subAccount, lyfDs);
      uint256 _usedBorrowingPower = LibLYF01.getTotalUsedBorrowingPower(_subAccount, lyfDs);
      if ((_borrowingPower * 10000) > _usedBorrowingPower * 9000) {
        revert LYFLiquidationFacet_Healthy();
      }
    }

    InternalLiquidationCallParams memory _params = InternalLiquidationCallParams({
      liquidationStrat: _liquidationStrat,
      subAccount: _subAccount,
      repayToken: _repayToken,
      collatToken: _collatToken,
      repayAmount: _repayAmount,
      debtShareId: _debtShareId,
      minReceive: _minReceive
    });

    address _collatUnderlyingToken = lyfDs.moneyMarket.getTokenFromIbToken(_collatToken);
    if (_collatUnderlyingToken != address(0)) {
      _ibLiquidationCall(_params, _collatUnderlyingToken, lyfDs);
    } else {
      _liquidationCall(_params, lyfDs);
    }
  }

  function _liquidationCall(InternalLiquidationCallParams memory _params, LibLYF01.LYFDiamondStorage storage lyfDs)
    internal
  {
    // 2. send all collats under subaccount to strategy
    uint256 _collatAmountBefore = IERC20(_params.collatToken).balanceOf(address(this));
    uint256 _repayAmountBefore = IERC20(_params.repayToken).balanceOf(address(this));
    uint256 _collatAmountToStrat = lyfDs.subAccountCollats[_params.subAccount].getAmount(_params.collatToken);

    IERC20(_params.collatToken).safeTransfer(_params.liquidationStrat, _collatAmountToStrat);

    // 3. call executeLiquidation on strategy
    uint256 _actualRepayAmount = _getActualRepayAmount(
      _params.subAccount,
      _params.debtShareId,
      _params.repayAmount,
      lyfDs
    );
    uint256 _feeToTreasury = (_actualRepayAmount * LIQUIDATION_FEE_BPS) / 10000;

    ILiquidationStrategy(_params.liquidationStrat).executeLiquidation(
      _params.collatToken,
      _params.repayToken,
      _collatAmountToStrat,
      _actualRepayAmount + _feeToTreasury,
      _params.minReceive
    );

    // 4. check repaid amount, take fees, and update states
    uint256 _repayAmountFromLiquidation = IERC20(_params.repayToken).balanceOf(address(this)) - _repayAmountBefore;
    uint256 _repaidAmount = _repayAmountFromLiquidation - _feeToTreasury;

    uint256 _collatSold = _collatAmountBefore - IERC20(_params.collatToken).balanceOf(address(this));

    IERC20(_params.repayToken).safeTransfer(lyfDs.treasury, _feeToTreasury);

    // give priority to fee
    if (_repaidAmount > 0) {
      _removeDebtByAmount(_params.subAccount, _params.debtShareId, _repaidAmount, lyfDs);
    }
    LibLYF01.removeCollateral(_params.subAccount, _params.collatToken, _collatSold, lyfDs);

    emit LogLiquidate(
      msg.sender,
      _params.liquidationStrat,
      _params.repayToken,
      _params.collatToken,
      _repaidAmount,
      _collatSold,
      _feeToTreasury
    );
  }

  function _ibLiquidationCall(
    InternalLiquidationCallParams memory _params,
    address _collatUnderlyingToken,
    LibLYF01.LYFDiamondStorage storage lyfDs
  ) internal {
    uint256 _collatAmount = lyfDs.subAccountCollats[_params.subAccount].getAmount(_params.collatToken);

    // withdraw underlyingToken from MM
    uint256 _returnedUnderlyingAmount = lyfDs.moneyMarket.withdraw(_params.collatToken, _collatAmount);

    // 2. convert collat amount under subaccount to underlying amount and send underlying to strategy
    uint256 _underlyingAmountBefore = IERC20(_collatUnderlyingToken).balanceOf(address(this));
    uint256 _repayAmountBefore = IERC20(_params.repayToken).balanceOf(address(this));

    // transfer _underlyingToken to strat
    IERC20(_collatUnderlyingToken).safeTransfer(_params.liquidationStrat, _returnedUnderlyingAmount);

    // 3. call executeLiquidation on strategy to liquidate underlying token
    uint256 _actualRepayAmount = _getActualRepayAmount(
      _params.subAccount,
      _params.debtShareId,
      _params.repayAmount,
      lyfDs
    );
    uint256 _feeToTreasury = (_actualRepayAmount * LIQUIDATION_FEE_BPS) / 10000;

    ILiquidationStrategy(_params.liquidationStrat).executeLiquidation(
      _collatUnderlyingToken,
      _params.repayToken,
      _returnedUnderlyingAmount,
      _actualRepayAmount + _feeToTreasury,
      _params.minReceive
    );

    // 4. check repaid amount, take fees, and update states
    uint256 _repayAmountFromLiquidation = IERC20(_params.repayToken).balanceOf(address(this)) - _repayAmountBefore;
    uint256 _repaidAmount = _repayAmountFromLiquidation - _feeToTreasury;
    uint256 _underlyingSold = _underlyingAmountBefore - IERC20(_collatUnderlyingToken).balanceOf(address(this));

    IERC20(_params.repayToken).safeTransfer(lyfDs.treasury, _feeToTreasury);

    // give priority to fee
    if (_repaidAmount > 0) {
      _removeDebtByAmount(_params.subAccount, _params.debtShareId, _repaidAmount, lyfDs);
    }
    // withdraw all ib
    LibLYF01.removeCollateral(_params.subAccount, _params.collatToken, _collatAmount, lyfDs);
    // deposit leftover underlyingToken as collat
    LibLYF01.addCollatWithoutMaxCollatNumCheck(
      _params.subAccount,
      _collatUnderlyingToken,
      _returnedUnderlyingAmount - _underlyingSold,
      lyfDs
    );

    emit LogLiquidateIb(
      msg.sender,
      _params.liquidationStrat,
      _params.repayToken,
      _params.collatToken,
      _repaidAmount,
      _underlyingSold,
      _feeToTreasury
    );
  }

  function lpLiquidationCall(
    address _account,
    uint256 _subAccountId,
    address _lpToken,
    uint256 _lpSharesToLiquidate,
    uint256 _amount0ToRepay,
    uint256 _amount1ToRepay
  ) external {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    if (!lyfDs.liquidationCallersOk[msg.sender]) {
      revert LYFLiquidationFacet_Unauthorized();
    }

    if (lyfDs.tokenConfigs[_lpToken].tier != LibLYF01.AssetTier.LP) {
      revert LYFLiquidationFacet_InvalidAssetTier();
    }

    LibLYF01.LPConfig memory lpConfig = lyfDs.lpConfigs[_lpToken];

    LiquidateLPLocalVars memory vars;

    vars.subAccount = LibLYF01.getSubAccount(_account, _subAccountId);

    vars.token0 = ISwapPairLike(_lpToken).token0();
    vars.token1 = ISwapPairLike(_lpToken).token1();

    vars.debtShareId0 = lyfDs.debtShareIds[vars.token0][_lpToken];
    vars.debtShareId1 = lyfDs.debtShareIds[vars.token1][_lpToken];

    LibLYF01.accrueDebtSharesOf(vars.subAccount, lyfDs);

    // 0. check borrowing power
    {
      uint256 _borrowingPower = LibLYF01.getTotalBorrowingPower(vars.subAccount, lyfDs);
      uint256 _usedBorrowingPower = LibLYF01.getTotalUsedBorrowingPower(vars.subAccount, lyfDs);
      if ((_borrowingPower * 10000) > _usedBorrowingPower * 9000) {
        revert LYFLiquidationFacet_Healthy();
      }
    }

    // 1. remove LP collat
    uint256 _lpFromCollatRemoval = LibLYF01.removeCollateral(vars.subAccount, _lpToken, _lpSharesToLiquidate, lyfDs);

    // 2. remove from masterchef staking
    IMasterChefLike(lpConfig.masterChef).withdraw(lpConfig.poolId, _lpFromCollatRemoval);

    IERC20(_lpToken).safeTransfer(lpConfig.strategy, _lpFromCollatRemoval);

    (vars.token0Return, vars.token1Return) = IStrat(lpConfig.strategy).removeLiquidity(_lpToken);

    // 3. repay what we can and add remaining to collat
    (vars.actualAmount0ToRepay, vars.remainingAmount0AfterRepay) = _repayAndAddRemainingToCollat(
      vars.subAccount,
      vars.debtShareId0,
      vars.token0,
      _amount0ToRepay,
      vars.token0Return,
      lyfDs
    );
    (vars.actualAmount1ToRepay, vars.remainingAmount1AfterRepay) = _repayAndAddRemainingToCollat(
      vars.subAccount,
      vars.debtShareId1,
      vars.token1,
      _amount1ToRepay,
      vars.token1Return,
      lyfDs
    );

    emit LogLiquidateLP(
      msg.sender,
      _account,
      _subAccountId,
      _lpToken,
      _lpSharesToLiquidate,
      vars.actualAmount0ToRepay,
      vars.actualAmount1ToRepay,
      vars.remainingAmount0AfterRepay,
      vars.remainingAmount1AfterRepay
    );
  }

  function _repayAndAddRemainingToCollat(
    address _subAccount,
    uint256 _debtShareId,
    address _token,
    uint256 _amountToRepay,
    uint256 _amountAvailable,
    LibLYF01.LYFDiamondStorage storage lyfDs
  ) internal returns (uint256 _actualAmountToRepay, uint256 _remainingAmountAfterRepay) {
    // repay what we can
    _actualAmountToRepay = _getActualRepayAmount(_subAccount, _debtShareId, _amountToRepay, lyfDs);
    _actualAmountToRepay = _actualAmountToRepay > _amountAvailable ? _amountAvailable : _actualAmountToRepay;

    if (_actualAmountToRepay > 0) {
      uint256 _feeToTreasury = (_actualAmountToRepay * LIQUIDATION_FEE_BPS) / 10000;
      _removeDebtByAmount(_subAccount, _debtShareId, _actualAmountToRepay - _feeToTreasury, lyfDs);
      // transfer fee to treasury
      IERC20(_token).safeTransfer(lyfDs.treasury, _feeToTreasury);
    }

    // add remaining as subAccount collateral
    _remainingAmountAfterRepay = _amountAvailable - _actualAmountToRepay;
    if (_remainingAmountAfterRepay > 0) {
      LibLYF01.addCollatWithoutMaxCollatNumCheck(_subAccount, _token, _remainingAmountAfterRepay, lyfDs);
    }
  }

  /// @dev min(amountToRepurchase, debtValue)
  function _getActualRepayAmount(
    address _subAccount,
    uint256 _debtShareId,
    uint256 _repayAmount,
    LibLYF01.LYFDiamondStorage storage lyfDs
  ) internal view returns (uint256 _actualToRepay) {
    uint256 _debtShare = lyfDs.subAccountDebtShares[_subAccount].getAmount(_debtShareId);
    // Note: precision loss 1 wei when convert share back to value
    uint256 _debtValue = LibShareUtil.shareToValue(
      _debtShare,
      lyfDs.debtValues[_debtShareId],
      lyfDs.debtShares[_debtShareId]
    );

    _actualToRepay = _repayAmount > _debtValue ? _debtValue : _repayAmount;
  }

  function _calculateCollat(
    address _subAccount,
    address _collatToken,
    uint256 _collatValueInUSD,
    uint256 _rewardBps,
    LibLYF01.LYFDiamondStorage storage lyfDs
  ) internal view returns (uint256 _collatAmountOut) {
    IMoneyMarket _moneyMarket = lyfDs.moneyMarket;
    address _underlyingToken = _moneyMarket.getTokenFromIbToken(_collatToken);

    uint256 _collatTokenPrice;
    if (_underlyingToken != address(0)) {
      // if _collatToken is ibToken convert underlying price to ib price
      _collatTokenPrice =
        (LibLYF01.getPriceUSD(_underlyingToken, lyfDs) *
          LibLYF01.getIbToUnderlyingConversionFactor(_collatToken, _underlyingToken, _moneyMarket)) /
        1e18;
    } else {
      // _collatToken is normal ERC20 or LP token
      _collatTokenPrice = LibLYF01.getPriceUSD(_collatToken, lyfDs);
    }

    // _collatAmountOut = _collatValueInUSD + _rewardInUSD
    _collatAmountOut =
      (_collatValueInUSD * (10000 + _rewardBps) * 1e14) /
      (_collatTokenPrice * lyfDs.tokenConfigs[_collatToken].to18ConversionFactor);

    uint256 _totalSubAccountCollat = lyfDs.subAccountCollats[_subAccount].getAmount(_collatToken);

    if (_collatAmountOut > _totalSubAccountCollat) {
      revert LYFLiquidationFacet_InsufficientAmount();
    }
  }

  function _removeDebtByAmount(
    address _subAccount,
    uint256 _debtShareId,
    uint256 _repayAmount,
    LibLYF01.LYFDiamondStorage storage lyfDs
  ) internal {
    uint256 _shareToRepay = LibShareUtil.valueToShare(
      _repayAmount,
      lyfDs.debtShares[_debtShareId],
      lyfDs.debtValues[_debtShareId]
    );

    LibLYF01.removeDebt(_subAccount, _debtShareId, _shareToRepay, _repayAmount, lyfDs);
  }
}
