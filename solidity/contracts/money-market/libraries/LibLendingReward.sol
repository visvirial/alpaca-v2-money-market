// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// libraries
import { LibMoneyMarket01 } from "./LibMoneyMarket01.sol";
import { LibDoublyLinkedList } from "./LibDoublyLinkedList.sol";

// interfaces
import { IRewardDistributor } from "../interfaces/IRewardDistributor.sol";

library LibLendingReward {
  using LibDoublyLinkedList for LibDoublyLinkedList.List;
  using SafeCast for uint256;
  using SafeCast for int256;

  error LibLendingReward_InvalidRewardToken();
  error LibLendingReward_InvalidRewardDistributor();

  function claim(
    address _account,
    address _token,
    address _rewardToken,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage ds
  ) internal returns (uint256 _unclaimedReward) {
    address _rewardDistributor = ds.rewardDistributor;

    if (_rewardToken == address(0)) revert LibLendingReward_InvalidRewardToken();
    if (_rewardDistributor == address(0)) revert LibLendingReward_InvalidRewardDistributor();

    if (ds.rewardPerSecList.getAmount(_rewardToken) > 0) {
      LibMoneyMarket01.PoolInfo memory poolInfo = updatePool(_token, _rewardToken, ds);
      uint256 _amount = ds.accountCollats[_account][_token];
      int256 _rewardDebt = ds.lenderRewardDebts[_account][_token][_rewardToken];

      int256 _accumulatedReward = ((_amount * poolInfo.accRewardPerShare) / LibMoneyMarket01.ACC_REWARD_PRECISION)
        .toInt256();

      _unclaimedReward = (_accumulatedReward - _rewardDebt).toUint256();

      ds.lenderRewardDebts[_account][_token][_rewardToken] = _accumulatedReward;

      if (_unclaimedReward > 0) {
        IRewardDistributor(_rewardDistributor).safeTransferReward(_rewardToken, _account, _unclaimedReward);
      }
    }
  }

  function updateRewardDebt(
    address _account,
    address _token,
    address _rewardToken,
    int256 _amount,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage ds
  ) internal {
    ds.lenderRewardDebts[_account][_token][_rewardToken] +=
      (_amount * ds.lendingPoolInfos[_rewardToken][_token].accRewardPerShare.toInt256()) /
      LibMoneyMarket01.ACC_REWARD_PRECISION.toInt256();
  }

  function pendingReward(
    address _account,
    address _token,
    address _rewardToken,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage ds
  ) internal view returns (uint256 _actualReward) {
    LibMoneyMarket01.PoolInfo storage poolInfo = ds.lendingPoolInfos[_rewardToken][_token];
    uint256 _accRewardPerShare = poolInfo.accRewardPerShare + _calculateRewardPerShare(_token, _rewardToken, ds);
    uint256 _amount = ds.accountCollats[_account][_token];
    int256 _rewardDebt = ds.lenderRewardDebts[_account][_token][_rewardToken];
    int256 _reward = ((_amount * _accRewardPerShare) / LibMoneyMarket01.ACC_REWARD_PRECISION).toInt256();
    _actualReward = (_reward - _rewardDebt).toUint256();
  }

  function updatePool(
    address _token,
    address _rewardToken,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage ds
  ) internal returns (LibMoneyMarket01.PoolInfo memory poolInfo) {
    ds.lendingPoolInfos[_rewardToken][_token].accRewardPerShare += _calculateRewardPerShare(_token, _rewardToken, ds);
    ds.lendingPoolInfos[_rewardToken][_token].lastRewardTime = block.timestamp.toUint128();
    return ds.lendingPoolInfos[_rewardToken][_token];
  }

  function _calculateRewardPerShare(
    address _token,
    address _rewardToken,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage ds
  ) internal view returns (uint256 _rewardPerShare) {
    LibMoneyMarket01.PoolInfo memory poolInfo = ds.lendingPoolInfos[_rewardToken][_token];
    if (block.timestamp > poolInfo.lastRewardTime) {
      uint256 _tokenBalance = ds.collats[_token];
      if (_tokenBalance > 0) {
        uint256 _timePast = block.timestamp - poolInfo.lastRewardTime;
        uint256 _reward = (_timePast * LibMoneyMarket01.getRewardPerSec(_rewardToken, ds) * poolInfo.allocPoint) /
          ds.totalLendingPoolAllocPoints[_rewardToken];
        _rewardPerShare = (_reward * LibMoneyMarket01.ACC_REWARD_PRECISION) / _tokenBalance;
      }
    }
  }

  function massUpdatePool(address _token, LibMoneyMarket01.MoneyMarketDiamondStorage storage ds) internal {
    LibDoublyLinkedList.Node[] memory rewardsPerSec = ds.rewardPerSecList.getAll();
    uint256 _rewardsPerSecLength = rewardsPerSec.length;

    for (uint256 _i = 0; _i < _rewardsPerSecLength; ) {
      updatePool(_token, rewardsPerSec[_i].token, ds);
      unchecked {
        _i++;
      }
    }
  }

  function massUpdateRewardDebt(
    address _account,
    address _token,
    int256 _amount,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage ds
  ) internal {
    LibDoublyLinkedList.Node[] memory rewardsPerSec = ds.rewardPerSecList.getAll();
    uint256 _rewardsPerSecLength = rewardsPerSec.length;

    for (uint256 _i = 0; _i < _rewardsPerSecLength; ) {
      updateRewardDebt(_account, _token, rewardsPerSec[_i].token, _amount, ds);
      unchecked {
        _i++;
      }
    }
  }
}
