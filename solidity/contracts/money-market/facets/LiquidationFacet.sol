// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

// ---- Libraries ---- //
import { LibMoneyMarket01 } from "../libraries/LibMoneyMarket01.sol";
import { LibReentrancyGuard } from "../libraries/LibReentrancyGuard.sol";
import { LibDoublyLinkedList } from "../libraries/LibDoublyLinkedList.sol";
import { LibShareUtil } from "../libraries/LibShareUtil.sol";
import { LibReentrancyGuard } from "../libraries/LibReentrancyGuard.sol";
import { LibSafeToken } from "../libraries/LibSafeToken.sol";

// ---- Interfaces ---- //
import { ILiquidationFacet } from "../interfaces/ILiquidationFacet.sol";
import { ILiquidationStrategy } from "../interfaces/ILiquidationStrategy.sol";
import { ILendFacet } from "../interfaces/ILendFacet.sol";
import { IERC20 } from "../interfaces/IERC20.sol";

/// @title LiquidationFacet is dedicated to repurchasing and liquidating
contract LiquidationFacet is ILiquidationFacet {
  using LibDoublyLinkedList for LibDoublyLinkedList.List;
  using LibSafeToken for IERC20;

  event LogRepurchase(
    address indexed _repurchaser,
    address _account,
    uint256 _subAccountId,
    address _repayToken,
    address _collatToken,
    uint256 _actualRepayAmountWithoutFee,
    uint256 _collatAmountOut,
    uint256 _feeToTreasury,
    uint256 _repurchaseRewardToCaller
  );
  event LogLiquidate(
    address indexed _caller,
    address indexed _liquidationStrategy,
    address _account,
    uint256 _subAccountId,
    address _repayToken,
    address _collatToken,
    uint256 _amountDebtRepaid,
    uint256 _amountCollatLiquidated,
    uint256 _feeToTreasury,
    uint256 _feeToLiquidator
  );

  struct InternalLiquidationCallParams {
    address liquidationStrat;
    address account;
    uint256 subAccountId;
    address subAccount;
    address repayToken;
    address collatToken;
    uint256 repayAmount;
    uint256 usedBorrowingPower;
    uint256 minReceive;
    uint256 subAccountCollatAmount;
  }

  struct LiquidationLocalVars {
    uint256 maxPossibleRepayAmount;
    uint256 maxPossibleFee;
    uint256 expectedMaxRepayAmount;
    uint256 repaidAmount;
    uint256 actualLiquidationFee;
    uint256 feeToLiquidator;
    uint256 feeToTreasury;
    uint256 collatSold;
    uint256 collatTokenBalanceBefore;
    uint256 repayTokenBalaceBefore;
  }

  struct RepurchaseLocalVars {
    address subAccount;
    uint256 totalBorrowingPower;
    uint256 usedBorrowingPower;
    uint256 repayAmountWithFee;
    uint256 repurchaseFeeToProtocol;
    uint256 repurchaseRewardBps;
    uint256 repayAmountWithoutFee;
    uint256 repayTokenPrice;
  }

  modifier nonReentrant() {
    LibReentrancyGuard.lock();
    _;
    LibReentrancyGuard.unlock();
  }

  modifier liquidateExec() {
    LibReentrancyGuard.ReentrancyGuardDiamondStorage storage reentrancyGuardDs = LibReentrancyGuard
      .reentrancyGuardDiamondStorage();
    reentrancyGuardDs.liquidateExec = LibReentrancyGuard._ENTERED;
    _;
    reentrancyGuardDs.liquidateExec = LibReentrancyGuard._NOT_ENTERED;
  }

  /// @notice Repurchase the debt token in exchange of a collateral token
  /// @param _account The account to be repurchased
  /// @param _subAccountId The index to derive the subaccount
  /// @param _repayToken The token that will be repurchase and repay the debt
  /// @param _collatToken The collateral token that will be used for exchange
  /// @param _desiredRepayAmount The amount of debt token that the repurchaser will provide
  /// @return _collatAmountOut The amount of collateral returned to repurchaser
  function repurchase(
    address _account,
    uint256 _subAccountId,
    address _repayToken,
    address _collatToken,
    uint256 _desiredRepayAmount
  ) external nonReentrant returns (uint256 _collatAmountOut) {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    // We only allow EOA or whitelisted contract to repurchase
    // Revert if caller is contract that is not whitelisted
    // `msg.sender != tx.origin` means that `msg.sender` is contract
    if (msg.sender != tx.origin && !moneyMarketDs.repurchasersOk[msg.sender]) {
      revert LiquidationFacet_Unauthorized();
    }

    RepurchaseLocalVars memory _vars;

    _vars.subAccount = LibMoneyMarket01.getSubAccount(_account, _subAccountId);

    // Accrue all debt tokens under subaccount
    // Because used borrowing power is calculated from all debt token of the subaccount
    LibMoneyMarket01.accrueBorrowedPositionsOf(_vars.subAccount, moneyMarketDs);

    _vars.totalBorrowingPower = LibMoneyMarket01.getTotalBorrowingPower(_vars.subAccount, moneyMarketDs);
    (_vars.usedBorrowingPower, ) = LibMoneyMarket01.getTotalUsedBorrowingPower(_vars.subAccount, moneyMarketDs);
    // Revert if position is not repurchasable (borrowingPower / usedBorrowingPower >= 1)
    if (_vars.totalBorrowingPower >= _vars.usedBorrowingPower) {
      revert LiquidationFacet_Healthy();
    }

    // Cap repurchase amount if needed and calculate fee
    // ex. assume 1 eth = 2000 USD, 10% repurchase fee, ignore collat,borrowingFactor, no premium
    //     collateral: 2000 USDC
    //     debt      : 1 eth
    //     maxAmountRepurchaseable = currentDebt * (1 + fee)
    //                             = 1 * 1.1 = 1.1 eth
    //
    //     case 1: desiredRepayAmount exceeds maxAmountRepurchaseable
    //     input : desiredRepayAmount = 1.2 eth, collatToken = USDC
    //     repayAmountWithFee    = maxAmountRepurchaseable = 1.1 eth
    //     repayAmountWithoutFee = currentDebt = 1 eth
    //     repurchaseFee         = repayAmountWithFee - repayAmountWithoutFee = 1.1 - 1 = 0.1 eth
    //
    //     case 2: desiredRepayAmount less than or equal to debt
    //     input : desiredRepayAmount = 1 eth, collatToken = USDC
    //     repayAmountWithFee    = desiredRepayAmount = 1 eth
    //     repayAmountWithoutFee = desiredRepayAmount * (1 - fee)
    //                           = 1 * 0.9 = 0.9 eth
    //     repurchaseFee         = repayAmountWithFee - repayAmountWithoutFee = 1 - 0.9 = 0.1 eth
    //
    //     case3: desiredRepayAmount exceeds debt but less than maxAmountRepurchaseable
    //     input : desiredRepayAmount = 1.05 eth, collatToken = USDC
    //     repayAmountWithFee = desiredRepayAmount = 1.05 eth
    //     repayAmountWithoutFee = desiredRepayAmount * (1 - fee)
    //                           = 1.05 * 0.9 = 0.945 eth
    //     repurchaseFee         = repayAmountWithFee - repayAmountWithoutFee = 1.05 - 0.945 = 0.105 eth
    //     TODO: this is WRONG! all cases should never pay fee more than max fee (debt * feeBps)

    // maxAmountRepurchaseable = currentDebt * (1 + feePct)
    //
    // case 1: desiredRepayAmount >= maxAmountRepurchaseable
    // desiredRepayAmount = 1.2 eth
    // repaid = currentDebt
    //        = 1 eth
    // fee = currentDebt * feePct = repaid * feePct
    //     = 1 * 0.1 = 0.1 eth
    //
    // case 2: desiredRepayAmount < maxAmountRepurchaseable
    // desiredRepayAmount = 0.9 eth
    // fee = desiredRepayAmount * feePct
    //     = 0.9 * 0.1 = 0.09
    // repaid = desiredRepayAmount - fee
    //        = 0.9 - 0.09 = 0.81
    //
    // desiredRepayAmount = 1 eth
    // fee = desiredRepayAmount * feePct
    //     = 1 * 0.1 = 0.1
    // repaid = desiredRepayAmount - fee
    //        = 1 - 0.1 = 0.9
    //
    // desiredRepayAmount = 1.1 eth
    // fee = desiredRepayAmount * feePct
    //     = 1.1 * 0.1 = 0.11
    // repaid = desiredRepayAmount - fee
    //        = 1.1 - 0.11 = 0.99

    // maxAmountRepurchaseable = debt + maxFee
    // maxFee = (1 + feePct * debt) / (1 - feePct)
    // repaid = desiredRepayAmount - fee
    // fee = desiredRepayAmount * feePct
    //
    // maxFee = (1 + 0.1 * 1) / (1 - 0.1) = 1.222...
    // maxAmountRepurchaseable = 1 +
    //
    // R = 1 - feePct = 1 - 0.1 = 0.9
    // maxFee = debt * (1 - R) / R = 1 * (1 - 0.9) / 0.9 = 0.1111...
    // maxAmountRepurchaseable = 1 + 0.111 = 1.1111...
    //
    // case 1: desiredRepayAmount >= maxAmountRepurchaseable
    // desiredRepayAmount = 1.2 eth
    // repaid = debt = 1
    // fee = input

    // maxAmountRepurchaseable = currentDebt * (1 + feePct)
    //
    // case 1: desiredRepayAmount >= maxAmountRepurchaseable
    // desiredRepayAmount = 1.2 eth
    // repaid = currentDebt
    //        = 1 eth
    // fee = currentDebt * feePct = repaid * feePct
    //     = 1 * 0.1 = 0.1 eth
    //
    // case 2: desiredRepayAmount <= debt
    // desiredRepayAmount = 0.9 eth
    // repaid = desiredRepayAmount / (1 + feePct)
    //        = 0.9 / (1 + 0.1) = 0.[81]...
    // fee = repaid * feePct = desiredRepayAmount - repaid
    //     = 0.9 - 0.[81]... = 0.0[81]...
    //
    // desiredRepayAmount = 1 eth
    // repaid = desiredRepayAmount / (1 + feePct)
    //        = 1 / (1 + 0.1) = 0.[90]...
    // fee = repaid * feePct = desiredRepayAmount - repaid
    //     = 1 - 0.[90]... = 0.0[90]...
    //
    // case 3: debt < desiredRepayAmount < max
    // desiredRepayAmount = 1.05 eth
    // repaid = desiredRepayAmount / (1 + feePct)
    //        = 1.05 / (1 + 0.1) = 0.9[54]...
    // fee = repaid * feePct = desiredRepayAmount - repaid
    //     = 1.05 - 0.9[54]... = 0.09[54]...
    //

    {
      (, uint256 _currentDebtAmount) = LibMoneyMarket01.getOverCollatDebtShareAndAmountOf(
        _vars.subAccount,
        _repayToken,
        moneyMarketDs
      );
      uint256 _maxAmountRepurchaseable = (_currentDebtAmount *
        (moneyMarketDs.repurchaseFeeBps + LibMoneyMarket01.MAX_BPS)) / LibMoneyMarket01.MAX_BPS;

      // repay amount is capped if try to repay more than outstanding debt + fee
      if (_desiredRepayAmount > _maxAmountRepurchaseable) {
        _vars.repayAmountWithFee = _maxAmountRepurchaseable;
        _vars.repayAmountWithoutFee = _currentDebtAmount;
      } else {
        _vars.repayAmountWithFee = _desiredRepayAmount;
        // _vars.repayAmountWithoutFee =
        //   (_desiredRepayAmount * 1e18) /
        //   (_maxAmountRepurchaseable * moneyMarketDs.tokenConfigs[_repayToken].to18ConversionFactor);
        _vars.repayAmountWithoutFee =
          (_desiredRepayAmount * LibMoneyMarket01.MAX_BPS) /
          (moneyMarketDs.repurchaseFeeBps + LibMoneyMarket01.MAX_BPS);
      }

      _vars.repurchaseFeeToProtocol = _vars.repayAmountWithFee - _vars.repayAmountWithoutFee;
    }

    _vars.repayTokenPrice = LibMoneyMarket01.getPriceUSD(_repayToken, moneyMarketDs);

    // Revert if repayment exceeds threshold (repayment > maxLiquidateThreshold * usedBorrowingPower)
    _validateBorrowingPower(_repayToken, _vars.repayAmountWithoutFee, _vars.usedBorrowingPower, moneyMarketDs);

    // Get dynamic repurchase reward to further incentivize repurchase
    _vars.repurchaseRewardBps = moneyMarketDs.repurchaseRewardModel.getFeeBps(
      _vars.totalBorrowingPower,
      _vars.usedBorrowingPower
    );

    // Calculate payout for repurchaser (collateral with premium)
    {
      uint256 _collatTokenPrice = LibMoneyMarket01.getPriceUSD(_collatToken, moneyMarketDs);

      uint256 _repayTokenPriceWithPremium = (_vars.repayTokenPrice *
        (LibMoneyMarket01.MAX_BPS + _vars.repurchaseRewardBps)) / LibMoneyMarket01.MAX_BPS;

      // collatAmountOut = repayAmount * repayTokenPriceWithPremium / collatTokenPrice
      _collatAmountOut =
        (_vars.repayAmountWithFee *
          _repayTokenPriceWithPremium *
          moneyMarketDs.tokenConfigs[_repayToken].to18ConversionFactor) /
        (_collatTokenPrice * moneyMarketDs.tokenConfigs[_collatToken].to18ConversionFactor);

      // revert if subAccount collat is not enough to cover desired repay amount
      // this could happen when there are multiple small collat and one large debt
      // ex. assume 1 eth = 2000 USD, no repurchase fee or premium, ignore collat,borrowingFactor
      //     collateral : 1000 USDT, 1000 USDC
      //     debt       : 1 eth
      //     input      : desiredRepayAmount = 0.6 eth, collatToken = USDC
      //     collatAmountOut = repayAmount * repayTokenPrice / collatTokenPrice
      //                     = 0.6 * 2000 / 1 = 1200 USDC
      //     this should revert since there is not enough USDC collateral to be repurchased
      if (_collatAmountOut > moneyMarketDs.subAccountCollats[_vars.subAccount].getAmount(_collatToken)) {
        revert LiquidationFacet_InsufficientAmount();
      }
    }

    // Transfer repay token in
    // In case of token with fee on transfer, debt would be repaid by amount after transfer fee
    // which won't be able to repurchase entire position
    // repaidAmount = amountReceived - repurchaseFee
    uint256 _actualRepayAmountWithoutFee = LibMoneyMarket01.unsafePullTokens(
      _repayToken,
      msg.sender,
      _vars.repayAmountWithFee
    ) - _vars.repurchaseFeeToProtocol;

    // Remove subAccount debt
    LibMoneyMarket01.removeOverCollatDebtFromSubAccount(
      _account,
      _vars.subAccount,
      _repayToken,
      LibShareUtil.valueToShare(
        _actualRepayAmountWithoutFee,
        moneyMarketDs.overCollatDebtShares[_repayToken],
        moneyMarketDs.overCollatDebtValues[_repayToken]
      ),
      _actualRepayAmountWithoutFee,
      moneyMarketDs
    );
    // need to call removeCollat which might withdraw from miniFL to be able to transfer to repurchaser
    LibMoneyMarket01.removeCollatFromSubAccount(
      _account,
      _vars.subAccount,
      _collatToken,
      _collatAmountOut,
      moneyMarketDs
    );

    // Increase reserves balance with repaid tokens
    // Safe to use unchecked because _actualRepayAmountWithoutFee is derived from balanceOf
    unchecked {
      moneyMarketDs.reserves[_repayToken] += _actualRepayAmountWithoutFee;
    }

    // Transfer collat token with premium back to repurchaser
    IERC20(_collatToken).safeTransfer(msg.sender, _collatAmountOut);
    // Transfer protocol's repurchase fee to treasury
    IERC20(_repayToken).safeTransfer(moneyMarketDs.liquidationTreasury, _vars.repurchaseFeeToProtocol);

    emit LogRepurchase(
      msg.sender,
      _account,
      _subAccountId,
      _repayToken,
      _collatToken,
      _actualRepayAmountWithoutFee,
      _collatAmountOut,
      _vars.repurchaseFeeToProtocol,
      (_collatAmountOut * _vars.repurchaseRewardBps) / LibMoneyMarket01.MAX_BPS
    );
  }

  /// @notice Liquidate the collateral token in exchange of the debt token
  ///
  ///         liquidation process
  ///           1) withdraw all specified collateral of subAccount and withdraw from MiniFL staking if applicable
  ///           2) send all collateral to strategy to prepare for liquidation
  ///           3) call `executeLiquidation` on strategy
  ///               - strategy convert collateral to repay token
  ///               - strategy transfer converted repay token and leftover collateral (if any) back to diamond
  ///           4) calculate actual repayment and fees (fee to protocol and caller) based on
  ///              amount received from strategy
  ///           5) check if the repayment violate maximum amount allowed to be liquidated in single tx
  ///           6) update states
  ///               - increase repay token reserve by amount repaid
  ///               - reduce subAccount's debt by amount repaid
  ///               - if any collateral left, add them back to subAccount and stake to MiniFL if applicable
  ///           7) transfer fee to treasury and caller
  ///
  /// @param _liquidationStrat The address of strategy used in liqudation
  /// @param _account The account to be repurchased
  /// @param _subAccountId The index to derive the subaccount
  /// @param _repayToken The token that will be repurchase and repay the debt
  /// @param _collatToken The collateral token that will be used for exchange
  /// @param _repayAmount The amount of debt token will be repaid after exchaing the collateral
  /// @param _minReceive Minimum amount expected from liquidation in repayToken
  function liquidationCall(
    address _liquidationStrat,
    address _account,
    uint256 _subAccountId,
    address _repayToken,
    address _collatToken,
    uint256 _repayAmount,
    uint256 _minReceive
  ) external nonReentrant liquidateExec {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    // Revert if liquidationStrat or caller is not whitelisted
    if (!moneyMarketDs.liquidationStratOk[_liquidationStrat] || !moneyMarketDs.liquidatorsOk[msg.sender]) {
      revert LiquidationFacet_Unauthorized();
    }

    address _subAccount = LibMoneyMarket01.getSubAccount(_account, _subAccountId);
    uint256 _collatAmount = moneyMarketDs.subAccountCollats[_subAccount].getAmount(_collatToken);
    // Revert if subAccount doesn't have collateral to be liquidated
    if (_collatAmount == 0) {
      revert LiquidationFacet_InsufficientAmount();
    }

    // Accrue all debt tokens under subaccount
    // Because used borrowing power is calculated from all debt token of the subaccount
    LibMoneyMarket01.accrueBorrowedPositionsOf(_subAccount, moneyMarketDs);

    uint256 _borrowingPower = LibMoneyMarket01.getTotalBorrowingPower(_subAccount, moneyMarketDs);
    (uint256 _usedBorrowingPower, ) = LibMoneyMarket01.getTotalUsedBorrowingPower(_subAccount, moneyMarketDs);
    // Revert if position is not liquidatable (borrowingPower / usedBorrowingPower > 1 / liquidationThreshold)
    // This threshold should be lower than repurchase (liquidationThreshold > 1)
    // because position must be repurchasable before liquidatable
    if ((_usedBorrowingPower * LibMoneyMarket01.MAX_BPS) < _borrowingPower * moneyMarketDs.liquidationThresholdBps) {
      revert LiquidationFacet_Healthy();
    }

    InternalLiquidationCallParams memory _params = InternalLiquidationCallParams({
      liquidationStrat: _liquidationStrat,
      account: _account,
      subAccountId: _subAccountId,
      subAccount: _subAccount,
      repayToken: _repayToken,
      collatToken: _collatToken,
      repayAmount: _repayAmount,
      usedBorrowingPower: _usedBorrowingPower,
      minReceive: _minReceive,
      subAccountCollatAmount: _collatAmount
    });

    _liquidationCall(_params, moneyMarketDs);
  }

  // TODO: merge to main function
  function _liquidationCall(
    InternalLiquidationCallParams memory _params,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal {
    LiquidationLocalVars memory _vars;

    // Remove all collateral from the subaccount first
    // If applicable, this will withdraw staked collateral from miniFL
    // so that it can be transfered to strategy contract
    LibMoneyMarket01.removeCollatFromSubAccount(
      _params.account,
      _params.subAccount,
      _params.collatToken,
      _params.subAccountCollatAmount,
      moneyMarketDs
    );

    // Cache the balance of tokens before executing strategy contract
    // This will be used to find the actual collateral used and repay token back from the strategy
    _vars.collatTokenBalanceBefore = IERC20(_params.collatToken).balanceOf(address(this));
    _vars.repayTokenBalaceBefore = IERC20(_params.repayToken).balanceOf(address(this));

    // Send all collats under subaccount to strategy
    IERC20(_params.collatToken).safeTransfer(_params.liquidationStrat, _params.subAccountCollatAmount);

    // Calculated repayToken amount expected from liquidation
    // Cap repay amount to current debt if input exceeds it
    // maxPossibleRepayAmount = min(repayAmount, currentDebt)
    _vars.maxPossibleRepayAmount = _calculateMaxPossibleRepayAmount(
      _params.subAccount,
      _params.repayToken,
      _params.repayAmount,
      moneyMarketDs
    );
    _vars.maxPossibleFee = (_vars.maxPossibleRepayAmount * moneyMarketDs.liquidationFeeBps) / LibMoneyMarket01.MAX_BPS;
    unchecked {
      _vars.expectedMaxRepayAmount = _vars.maxPossibleRepayAmount + _vars.maxPossibleFee;
    }

    // Call executeLiquidation on strategy
    // Strategy should convert all of collatToken in there to repayToken and send back here
    ILiquidationStrategy(_params.liquidationStrat).executeLiquidation(
      _params.collatToken,
      _params.repayToken,
      _params.subAccountCollatAmount,
      _vars.expectedMaxRepayAmount,
      _params.minReceive
    );

    // Calculate actual repayment by comparing balance of repayToken before and after liquidation
    // actualLiquidationFee = amountFromStrat * liquidationFee
    //                      = amountFromStrat * maxPossibleFee / expectedMaxRepayAmount
    // repaidAmount = amountFromStrat - actualLiquidationFee
    (_vars.repaidAmount, _vars.actualLiquidationFee) = _calculateActualRepayAmountAndFee(
      _params.repayToken,
      _vars.repayTokenBalaceBefore,
      _vars.expectedMaxRepayAmount,
      _vars.maxPossibleFee
    );

    // Split fee between liquidator and treasury
    // ex. liquidationReward = 40%
    //     40% of actualLiquidationFee will go to liquidator aka. caller
    //     60% of actualLiquidationFee will go to treasury
    _vars.feeToLiquidator =
      (_vars.actualLiquidationFee * moneyMarketDs.liquidationRewardBps) /
      LibMoneyMarket01.MAX_BPS;
    // Safe to use unchecked because `feeToLiquidator` is fraction of `actualLiquidationFee`
    unchecked {
      _vars.feeToTreasury = _vars.actualLiquidationFee - _vars.feeToLiquidator;
    }

    // Revert if repayment exceeds threshold (repayment > maxLiquidateThreshold * usedBorrowingPower)
    _validateBorrowingPower(_params.repayToken, _vars.repaidAmount, _params.usedBorrowingPower, moneyMarketDs);

    // Increase repayToken reserve balance
    // Safe to use unchecked because repaidAmount is derived from balanceOf
    unchecked {
      moneyMarketDs.reserves[_params.repayToken] += _vars.repaidAmount;
    }

    // Remove repaid debt from subAccount
    LibMoneyMarket01.removeOverCollatDebtFromSubAccount(
      _params.account,
      _params.subAccount,
      _params.repayToken,
      LibShareUtil.valueToShare(
        _vars.repaidAmount,
        moneyMarketDs.overCollatDebtShares[_params.repayToken],
        moneyMarketDs.overCollatDebtValues[_params.repayToken]
      ),
      _vars.repaidAmount,
      moneyMarketDs
    );

    // Calculate the actual collateral used in liquidation strategy by comparing balance before and after
    _vars.collatSold = _vars.collatTokenBalanceBefore - IERC20(_params.collatToken).balanceOf(address(this));

    // Add remaining collateral back to the subaccount since we have removed all collateral earlier
    // This should deposit collateral back to miniFL if applicable
    if (_params.subAccountCollatAmount > _vars.collatSold) {
      unchecked {
        LibMoneyMarket01.addCollatToSubAccount(
          _params.account,
          _params.subAccount,
          _params.collatToken,
          _params.subAccountCollatAmount - _vars.collatSold,
          moneyMarketDs
        );
      }
    }

    IERC20(_params.repayToken).safeTransfer(msg.sender, _vars.feeToLiquidator);
    IERC20(_params.repayToken).safeTransfer(moneyMarketDs.liquidationTreasury, _vars.feeToTreasury);

    emit LogLiquidate(
      msg.sender,
      _params.liquidationStrat,
      _params.account,
      _params.subAccountId,
      _params.repayToken,
      _params.collatToken,
      _vars.repaidAmount,
      _vars.collatSold,
      _vars.feeToTreasury,
      _vars.feeToLiquidator
    );
  }

  /// @dev min(repayAmount, debtValue)
  function _calculateMaxPossibleRepayAmount(
    address _subAccount,
    address _repayToken,
    uint256 _repayAmount,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal view returns (uint256 _maxPossibleRepayAmount) {
    uint256 _debtShare = moneyMarketDs.subAccountDebtShares[_subAccount].getAmount(_repayToken);
    // for ib debtValue is in ib shares not in underlying
    uint256 _debtValue = LibShareUtil.shareToValue(
      _debtShare,
      moneyMarketDs.overCollatDebtValues[_repayToken],
      moneyMarketDs.overCollatDebtShares[_repayToken]
    );

    _maxPossibleRepayAmount = _repayAmount > _debtValue ? _debtValue : _repayAmount;
  }

  function _validateBorrowingPower(
    address _repayToken,
    uint256 _repaidAmount,
    uint256 _usedBorrowingPower,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal view {
    uint256 _repayTokenPrice = LibMoneyMarket01.getPriceUSD(_repayToken, moneyMarketDs);
    uint256 _repaidBorrowingPower = LibMoneyMarket01.usedBorrowingPower(
      _repaidAmount,
      _repayTokenPrice,
      moneyMarketDs.tokenConfigs[_repayToken].borrowingFactor,
      moneyMarketDs.tokenConfigs[_repayToken].to18ConversionFactor
    );
    // Revert if repayment exceeds threshold (repayment > maxLiquidateThreshold * usedBorrowingPower)
    if (_repaidBorrowingPower * LibMoneyMarket01.MAX_BPS > (_usedBorrowingPower * moneyMarketDs.maxLiquidateBps)) {
      revert LiquidationFacet_RepayAmountExceedThreshold();
    }
  }

  function _calculateActualRepayAmountAndFee(
    address _repayToken,
    uint256 _repayTokenBalanceBefore,
    uint256 _expectedMaxRepayAmount,
    uint256 _maxFeePossible
  ) internal view returns (uint256 _actualRepayAmount, uint256 _actualLiquidationFee) {
    // strategy will only swap exactly less than or equal to _expectedMaxRepayAmount
    uint256 _amountFromLiquidationStrat = IERC20(_repayToken).balanceOf(address(this)) - _repayTokenBalanceBefore;
    // find the actual fee through the rule of three
    // _actualLiquidationFee = maxFee * (_amountFromLiquidationStrat / _expectedMaxRepayAmount)
    _actualLiquidationFee = (_amountFromLiquidationStrat * _maxFeePossible) / _expectedMaxRepayAmount;
    unchecked {
      _actualRepayAmount = _amountFromLiquidationStrat - _actualLiquidationFee;
    }
  }
}
