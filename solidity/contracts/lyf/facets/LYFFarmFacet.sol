// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// libs
import { LibLYF01 } from "../libraries/LibLYF01.sol";
import { LibUIntDoublyLinkedList } from "../libraries/LibUIntDoublyLinkedList.sol";
import { LibDoublyLinkedList } from "../libraries/LibDoublyLinkedList.sol";
import { LibShareUtil } from "../libraries/LibShareUtil.sol";
import { LibFullMath } from "../libraries/LibFullMath.sol";
import { LibReentrancyGuard } from "../libraries/LibReentrancyGuard.sol";

// interfaces
import { ILYFFarmFacet } from "../interfaces/ILYFFarmFacet.sol";
import { ISwapPairLike } from "../interfaces/ISwapPairLike.sol";
import { IStrat } from "../interfaces/IStrat.sol";
import { IMoneyMarket } from "../interfaces/IMoneyMarket.sol";
import { IMasterChefLike } from "../interfaces/IMasterChefLike.sol";

contract LYFFarmFacet is ILYFFarmFacet {
  using SafeERC20 for ERC20;
  using LibUIntDoublyLinkedList for LibUIntDoublyLinkedList.List;
  using LibDoublyLinkedList for LibDoublyLinkedList.List;

  struct ReducePositionLocalVars {
    address subAccount;
    address token0;
    address token1;
    uint256 debtShareId0;
    uint256 debtShareId1;
  }

  event LogRemoveDebt(
    address indexed _subAccount,
    uint256 indexed _debtShareId,
    uint256 _removeDebtShare,
    uint256 _removeDebtAmount
  );

  event LogAddFarmPosition(address indexed _subAccount, address indexed _lpToken, uint256 _lpAmount);

  event LogRepay(address indexed _user, uint256 indexed _subAccountId, address _token, uint256 _actualRepayAmount);

  event LogRepayWithCollat(
    address indexed _user,
    uint256 indexed _subAccountId,
    address _token,
    uint256 _debtShareId,
    uint256 _actualRepayAmount
  );

  modifier nonReentrant() {
    LibReentrancyGuard.lock();
    _;
    LibReentrancyGuard.unlock();
  }

  function addFarmPosition(
    uint256 _subAccountId,
    address _lpToken,
    uint256 _desireToken0Amount,
    uint256 _desireToken1Amount,
    uint256 _minLpReceive
  ) external nonReentrant {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    LibLYF01.LPConfig memory lpConfig = lyfDs.lpConfigs[_lpToken];

    address _subAccount = LibLYF01.getSubAccount(msg.sender, _subAccountId);

    LibLYF01.accrueAllSubAccountDebtShares(_subAccount, lyfDs);

    address _token0 = ISwapPairLike(_lpToken).token0();
    address _token1 = ISwapPairLike(_lpToken).token1();

    LibLYF01.accrueInterest(lyfDs.debtShareIds[_token0][_lpToken], lyfDs);
    LibLYF01.accrueInterest(lyfDs.debtShareIds[_token1][_lpToken], lyfDs);

    // 1. get token from collat (underlying and ib if possible), borrow if not enough
    _removeCollatWithIbAndBorrow(_subAccount, _token0, _lpToken, _desireToken0Amount, lyfDs);
    _removeCollatWithIbAndBorrow(_subAccount, _token1, _lpToken, _desireToken1Amount, lyfDs);

    // 2. send token to strat
    ERC20(_token0).safeTransfer(lpConfig.strategy, _desireToken0Amount);
    ERC20(_token1).safeTransfer(lpConfig.strategy, _desireToken1Amount);

    // 3. compose lp
    uint256 _lpReceived = IStrat(lpConfig.strategy).composeLPToken(
      _token0,
      _token1,
      _lpToken,
      _desireToken0Amount,
      _desireToken1Amount,
      _minLpReceive
    );

    // 4. deposit to masterChef
    LibLYF01.depositToMasterChef(_lpToken, lpConfig, _lpReceived);

    // 5. add it to collateral
    LibLYF01.addCollat(_subAccount, _lpToken, _lpReceived, lyfDs);

    // 6. health check on sub account
    if (!LibLYF01.isSubaccountHealthy(_subAccount, lyfDs)) {
      revert LYFFarmFacet_BorrowingPowerTooLow();
    }
    emit LogAddFarmPosition(_subAccount, _lpToken, _lpReceived);
  }

  function directAddFarmPosition(
    uint256 _subAccountId,
    address _lpToken,
    uint256 _desireToken0Amount,
    uint256 _desireToken1Amount,
    uint256 _minLpReceive,
    uint256 _token0AmountIn,
    uint256 _token1AmountIn
  ) external nonReentrant {
    if (_token0AmountIn > _desireToken0Amount || _token1AmountIn > _desireToken1Amount) {
      revert LYFFarmFacet_BadInput();
    }

    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    LibLYF01.LPConfig memory lpConfig = lyfDs.lpConfigs[_lpToken];

    address _subAccount = LibLYF01.getSubAccount(msg.sender, _subAccountId);

    LibLYF01.accrueAllSubAccountDebtShares(_subAccount, lyfDs);

    address _token0 = ISwapPairLike(_lpToken).token0();
    address _token1 = ISwapPairLike(_lpToken).token1();

    LibLYF01.accrueInterest(lyfDs.debtShareIds[_token0][_lpToken], lyfDs);
    LibLYF01.accrueInterest(lyfDs.debtShareIds[_token1][_lpToken], lyfDs);

    // 1. if desired amount exceeds provided amount, get token from collat (underlying and ib if possible), borrow if not enough
    _removeCollatWithIbAndBorrow(_subAccount, _token0, _lpToken, _desireToken0Amount - _token0AmountIn, lyfDs);
    _removeCollatWithIbAndBorrow(_subAccount, _token1, _lpToken, _desireToken1Amount - _token1AmountIn, lyfDs);

    // 2. send token to strat
    ERC20(_token0).safeTransferFrom(msg.sender, lpConfig.strategy, _token0AmountIn);
    ERC20(_token1).safeTransferFrom(msg.sender, lpConfig.strategy, _token1AmountIn);
    ERC20(_token0).safeTransfer(lpConfig.strategy, _desireToken0Amount - _token0AmountIn);
    ERC20(_token1).safeTransfer(lpConfig.strategy, _desireToken1Amount - _token1AmountIn);

    // 3. compose lp
    uint256 _lpReceived = IStrat(lpConfig.strategy).composeLPToken(
      _token0,
      _token1,
      _lpToken,
      _desireToken0Amount,
      _desireToken1Amount,
      _minLpReceive
    );

    // 4. deposit to masterChef
    LibLYF01.depositToMasterChef(_lpToken, lpConfig, _lpReceived);

    // 5. add it to collateral
    LibLYF01.addCollat(_subAccount, _lpToken, _lpReceived, lyfDs);

    // 6. health check on sub account
    if (!LibLYF01.isSubaccountHealthy(_subAccount, lyfDs)) {
      revert LYFFarmFacet_BorrowingPowerTooLow();
    }
    emit LogAddFarmPosition(_subAccount, _lpToken, _lpReceived);
  }

  function reducePosition(
    uint256 _subAccountId,
    address _lpToken,
    uint256 _lpShareAmount,
    uint256 _amount0Out,
    uint256 _amount1Out
  ) external nonReentrant {
    // todo: should revinvest here before anything
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    ReducePositionLocalVars memory _vars;

    _vars.subAccount = LibLYF01.getSubAccount(msg.sender, _subAccountId);

    if (lyfDs.tokenConfigs[_lpToken].tier != LibLYF01.AssetTier.LP) {
      revert LYFFarmFacet_InvalidAssetTier();
    }

    LibLYF01.LPConfig memory lpConfig = lyfDs.lpConfigs[_lpToken];

    _vars.token0 = ISwapPairLike(_lpToken).token0();
    _vars.token1 = ISwapPairLike(_lpToken).token1();

    _vars.debtShareId0 = lyfDs.debtShareIds[_vars.token0][_lpToken];
    _vars.debtShareId1 = lyfDs.debtShareIds[_vars.token1][_lpToken];

    LibLYF01.accrueInterest(lyfDs.debtShareIds[_vars.token0][_lpToken], lyfDs);
    LibLYF01.accrueInterest(lyfDs.debtShareIds[_vars.token1][_lpToken], lyfDs);

    // 1. Remove LP collat
    uint256 _lpFromCollatRemoval = LibLYF01.removeCollateral(_vars.subAccount, _lpToken, _lpShareAmount, lyfDs);

    // 2. Remove from masterchef staking
    IMasterChefLike(lpConfig.masterChef).withdraw(lpConfig.poolId, _lpFromCollatRemoval);

    ERC20(_lpToken).safeTransfer(lpConfig.strategy, _lpFromCollatRemoval);

    (uint256 _token0Return, uint256 _token1Return) = IStrat(lpConfig.strategy).removeLiquidity(_lpToken);

    // slipage check

    if (_token0Return < _amount0Out || _token1Return < _amount1Out) {
      revert LYFFarmFacet_TooLittleReceived();
    }

    // 3. Repay debt

    _repayDebt(msg.sender, _subAccountId, _vars.token0, _vars.debtShareId0, _token0Return - _amount0Out, lyfDs);
    _repayDebt(msg.sender, _subAccountId, _vars.token1, _vars.debtShareId1, _token1Return - _amount1Out, lyfDs);

    // 4. Transfer remaining back to user
    if (_amount0Out > 0) {
      ERC20(_vars.token0).safeTransfer(msg.sender, _amount0Out);
    }
    if (_amount1Out > 0) {
      ERC20(_vars.token1).safeTransfer(msg.sender, _amount1Out);
    }

    if (!LibLYF01.isSubaccountHealthy(_vars.subAccount, lyfDs)) {
      revert LYFFarmFacet_BorrowingPowerTooLow();
    }
  }

  function repay(
    address _account,
    uint256 _subAccountId,
    address _token,
    address _lpToken,
    uint256 _repayAmount
  ) external nonReentrant {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    uint256 _debtShareId = lyfDs.debtShareIds[_token][_lpToken];

    LibLYF01.accrueInterest(_debtShareId, lyfDs);

    // remove debt as much as possible
    uint256 _actualRepayAmount = _repayDebt(_account, _subAccountId, _token, _debtShareId, _repayAmount, lyfDs);

    // transfer only amount to repay
    ERC20(_token).safeTransferFrom(msg.sender, address(this), _actualRepayAmount);
  }

  function reinvest(address _lpToken) external nonReentrant {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    if (!lyfDs.reinvestorsOk[msg.sender]) {
      revert LYFFarmFacet_Unauthorized();
    }

    LibLYF01.LPConfig memory _lpConfig = lyfDs.lpConfigs[_lpToken];
    if (_lpConfig.rewardToken == address(0)) {
      revert LYFFarmFacet_InvalidLP();
    }

    LibLYF01.reinvest(_lpToken, 0, lyfDs.lpConfigs[_lpToken], lyfDs);
  }

  function repayWithCollat(
    address _account,
    uint256 _subAccountId,
    address _token,
    address _lpToken,
    uint256 _repayAmount
  ) external nonReentrant {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    address _subAccount = LibLYF01.getSubAccount(_account, _subAccountId);
    LibLYF01.accrueAllSubAccountDebtShares(_subAccount, lyfDs);

    uint256 _debtShareId = lyfDs.debtShareIds[_token][_lpToken];
    (, uint256 _debtAmount) = _getDebt(_subAccount, _debtShareId, lyfDs);

    // repay maxmimum debt
    _repayAmount = _repayAmount > _debtAmount ? _debtAmount : _repayAmount;

    if (_repayAmount > 0) {
      // remove collat as much as possible
      uint256 _collatRemoved = LibLYF01.removeCollateral(_subAccount, _token, _repayAmount, lyfDs);
      // remove debt as much as possible
      uint256 _actualRepayAmount = _repayDebt(_account, _subAccountId, _token, _debtShareId, _collatRemoved, lyfDs);

      emit LogRepayWithCollat(_account, _subAccountId, _token, _debtShareId, _actualRepayAmount);
    }
  }

  function _getDebt(
    address _subAccount,
    uint256 _debtShareId,
    LibLYF01.LYFDiamondStorage storage lyfDs
  ) internal view returns (uint256 _debtShare, uint256 _debtAmount) {
    _debtShare = lyfDs.subAccountDebtShares[_subAccount].getAmount(_debtShareId);
    // Note: precision loss 1 wei when convert share back to value
    _debtAmount = LibShareUtil.shareToValue(_debtShare, lyfDs.debtValues[_debtShareId], lyfDs.debtShares[_debtShareId]);
  }

  function _removeDebt(
    address _subAccount,
    uint256 _debtShareId,
    uint256 _oldSubAccountDebtShare,
    uint256 _shareToRemove,
    LibLYF01.LYFDiamondStorage storage lyfDs
  ) internal returns (uint256 _repayAmount) {
    if (lyfDs.subAccountDebtShares[_subAccount].getAmount(_debtShareId) > 0) {
      uint256 _oldDebtShare = lyfDs.debtShares[_debtShareId];
      uint256 _oldDebtValue = lyfDs.debtValues[_debtShareId];

      // update user debtShare
      lyfDs.subAccountDebtShares[_subAccount].updateOrRemove(_debtShareId, _oldSubAccountDebtShare - _shareToRemove);

      // update over collat debtShare
      _repayAmount = LibShareUtil.shareToValue(_shareToRemove, _oldDebtValue, _oldDebtShare);

      lyfDs.debtShares[_debtShareId] -= _shareToRemove;
      lyfDs.debtValues[_debtShareId] -= _repayAmount;

      // emit event
      emit LogRemoveDebt(_subAccount, _debtShareId, _shareToRemove, _repayAmount);
    }
  }

  // TODO: gas optimize on oracle call
  function _checkBorrowingPower(
    uint256 _borrowingPower,
    uint256 _borrowedValue,
    address _token,
    uint256 _amount,
    LibLYF01.LYFDiamondStorage storage lyfDs
  ) internal view {
    (uint256 _tokenPrice, ) = LibLYF01.getPriceUSD(_token, lyfDs);

    LibLYF01.TokenConfig memory _tokenConfig = lyfDs.tokenConfigs[_token];

    uint256 _borrowingUSDValue = LibLYF01.usedBorrowingPower(
      _amount * _tokenConfig.to18ConversionFactor,
      _tokenPrice,
      _tokenConfig.borrowingFactor
    );

    if (_borrowingPower < _borrowedValue + _borrowingUSDValue) {
      revert LYFFarmFacet_BorrowingValueTooHigh(_borrowingPower, _borrowedValue, _borrowingUSDValue);
    }
  }

  function _checkAvailableToken(
    address _token,
    uint256 _debtShareId,
    uint256 _borrowAmount,
    LibLYF01.LYFDiamondStorage storage lyfDs
  ) internal view {
    uint256 _mmTokenBalnce = ERC20(_token).balanceOf(address(this)) - lyfDs.collats[_token];

    if (_mmTokenBalnce < _borrowAmount) {
      revert LYFFarmFacet_NotEnoughToken(_borrowAmount);
    }

    if (_borrowAmount + lyfDs.debtValues[_debtShareId] > lyfDs.tokenConfigs[_token].maxBorrow) {
      revert LYFFarmFacet_ExceedBorrowLimit();
    }
  }

  function _removeCollatWithIbAndBorrow(
    address _subAccount,
    address _token,
    address _lpToken,
    uint256 _desireTokenAmount,
    LibLYF01.LYFDiamondStorage storage lyfDs
  ) internal {
    uint256 _tokenAmountFromCollat = LibLYF01.removeCollateral(_subAccount, _token, _desireTokenAmount, lyfDs);
    uint256 _tokenAmountFromIbCollat = LibLYF01.removeIbCollateral(
      _subAccount,
      _token,
      IMoneyMarket(lyfDs.moneyMarket).getIbTokenFromToken(_token),
      _desireTokenAmount - _tokenAmountFromCollat,
      lyfDs
    );
    _borrowFromMoneyMarket(
      _subAccount,
      _token,
      _lpToken,
      _desireTokenAmount - _tokenAmountFromCollat - _tokenAmountFromIbCollat,
      lyfDs
    );
  }

  function _borrowFromMoneyMarket(
    address _subAccount,
    address _token,
    address _lpToken,
    uint256 _amount,
    LibLYF01.LYFDiamondStorage storage lyfDs
  ) internal {
    if (_amount == 0) return;
    uint256 _debtShareId = lyfDs.debtShareIds[_token][_lpToken];

    IMoneyMarket(lyfDs.moneyMarket).nonCollatBorrow(_token, _amount);

    // update subaccount debt
    // todo: optimize this
    LibUIntDoublyLinkedList.List storage userDebtShare = lyfDs.subAccountDebtShares[_subAccount];

    if (
      lyfDs.subAccountDebtShares[_subAccount].getNextOf(LibUIntDoublyLinkedList.START) == LibUIntDoublyLinkedList.EMPTY
    ) {
      lyfDs.subAccountDebtShares[_subAccount].init();
    }

    uint256 _totalSupply = lyfDs.debtShares[_debtShareId];
    uint256 _totalValue = lyfDs.debtValues[_debtShareId];

    uint256 _shareToAdd = LibShareUtil.valueToShareRoundingUp(_amount, _totalSupply, _totalValue);

    // update over collat debt
    lyfDs.debtShares[_debtShareId] += _shareToAdd;
    lyfDs.debtValues[_debtShareId] += _amount;

    uint256 _newShareAmount = userDebtShare.getAmount(_debtShareId) + _shareToAdd;

    // update user's debtshare
    userDebtShare.addOrUpdate(_debtShareId, _newShareAmount);
  }

  function _repayDebt(
    address _account,
    uint256 _subAccountId,
    address _token,
    uint256 _debtShareId,
    uint256 _repayAmount,
    LibLYF01.LYFDiamondStorage storage lyfDs
  ) internal returns (uint256 _actualRepayAmount) {
    address _subAccount = LibLYF01.getSubAccount(_account, _subAccountId);

    (uint256 _oldSubAccountDebtShare, ) = _getDebt(_subAccount, _debtShareId, lyfDs);

    uint256 _shareToRemove = LibShareUtil.valueToShare(
      _repayAmount,
      lyfDs.debtShares[_debtShareId],
      lyfDs.debtValues[_debtShareId]
    );

    _shareToRemove = _oldSubAccountDebtShare > _shareToRemove ? _shareToRemove : _oldSubAccountDebtShare;

    _actualRepayAmount = _removeDebt(_subAccount, _debtShareId, _oldSubAccountDebtShare, _shareToRemove, lyfDs);

    emit LogRepay(_account, _subAccountId, _token, _actualRepayAmount);
  }

  function getTotalBorrowingPower(address _account, uint256 _subAccountId)
    external
    view
    returns (uint256 _totalBorrowingPowerUSDValue)
  {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    address _subAccount = LibLYF01.getSubAccount(_account, _subAccountId);

    _totalBorrowingPowerUSDValue = LibLYF01.getTotalBorrowingPower(_subAccount, lyfDs);
  }

  function getTotalUsedBorrowingPower(address _account, uint256 _subAccountId)
    external
    view
    returns (uint256 _totalBorrowedUSDValue)
  {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    address _subAccount = LibLYF01.getSubAccount(_account, _subAccountId);

    _totalBorrowedUSDValue = LibLYF01.getTotalUsedBorrowingPower(_subAccount, lyfDs);
  }

  function debtLastAccrueTime(address _token, address _lpToken) external view returns (uint256) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    uint256 _debtShareId = lyfDs.debtShareIds[_token][_lpToken];
    return lyfDs.debtLastAccrueTime[_debtShareId];
  }

  function pendingInterest(address _token, address _lpToken) public view returns (uint256) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    uint256 _debtShareId = lyfDs.debtShareIds[_token][_lpToken];
    return LibLYF01.pendingInterest(_debtShareId, lyfDs);
  }

  function accrueInterest(address _token, address _lpToken) external {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    uint256 _debtShareId = lyfDs.debtShareIds[_token][_lpToken];
    LibLYF01.accrueInterest(_debtShareId, lyfDs);
  }

  function debtValues(address _token, address _lpToken) external view returns (uint256) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    uint256 _debtShareId = lyfDs.debtShareIds[_token][_lpToken];
    return lyfDs.debtValues[_debtShareId];
  }

  function lpValues(address _lpToken) external view returns (uint256) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    return lyfDs.lpValues[_lpToken];
  }

  function lpShares(address _lpToken) external view returns (uint256) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    return lyfDs.lpShares[_lpToken];
  }

  function lpConfigs(address _lpToken) external view returns (LibLYF01.LPConfig memory) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    return lyfDs.lpConfigs[_lpToken];
  }

  function debtShares(address _token, address _lpToken) external view returns (uint256) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    uint256 _debtShareId = lyfDs.debtShareIds[_token][_lpToken];
    return lyfDs.debtShares[_debtShareId];
  }

  function pendingRewards(address _lpToken) external view returns (uint256) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    return lyfDs.pendingRewards[_lpToken];
  }

  function getGlobalDebt(address _token, address _lpToken) external view returns (uint256, uint256) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    uint256 _debtShareId = lyfDs.debtShareIds[_token][_lpToken];
    return (lyfDs.debtShares[_debtShareId], lyfDs.debtValues[_debtShareId]);
  }

  function getMMDebt(address _token) external view returns (uint256 _debtAmount) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    _debtAmount = IMoneyMarket(lyfDs.moneyMarket).getNonCollatAccountDebt(address(this), _token);
  }

  function getDebtShares(address _account, uint256 _subAccountId)
    external
    view
    returns (LibUIntDoublyLinkedList.Node[] memory)
  {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    address _subAccount = LibLYF01.getSubAccount(_account, _subAccountId);

    LibUIntDoublyLinkedList.List storage subAccountDebtShares = lyfDs.subAccountDebtShares[_subAccount];

    return subAccountDebtShares.getAll();
  }

  function getDebt(
    address _account,
    uint256 _subAccountId,
    address _token,
    address _lpToken
  ) public view returns (uint256 _debtShare, uint256 _debtAmount) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    address _subAccount = LibLYF01.getSubAccount(_account, _subAccountId);
    uint256 _debtShareId = lyfDs.debtShareIds[_token][_lpToken];

    (_debtShare, _debtAmount) = _getDebt(_subAccount, _debtShareId, lyfDs);
  }
}
