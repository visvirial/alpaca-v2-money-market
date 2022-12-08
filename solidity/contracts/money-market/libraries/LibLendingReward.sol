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

  function claimFor(
    address _account,
    address _rewardToken,
    address _token,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage ds
  ) internal returns (uint256 _unclaimedReward) {
    if (ds.lendingRewardPerSecList.getAmount(_rewardToken) > 0) {
      LibMoneyMarket01.PoolInfo memory poolInfo = updatePool(_rewardToken, _token, ds);
      uint256 _amount = ds.accountCollats[_account][_token];
      bytes32 _poolKey = LibMoneyMarket01.getPoolKey(_rewardToken, _token);
      int256 _rewardDebt = ds.lenderRewardDebts[_account][_poolKey];

      int256 _accumulatedReward = ((_amount * poolInfo.accRewardPerShare) / LibMoneyMarket01.ACC_REWARD_PRECISION)
        .toInt256();

      _unclaimedReward = (_accumulatedReward - _rewardDebt).toUint256();

      ds.lenderRewardDebts[_account][_poolKey] = _accumulatedReward;

      if (_unclaimedReward > 0) {
        IRewardDistributor(ds.rewardDistributor).safeTransferReward(_rewardToken, _account, _unclaimedReward);
      }
    }
  }

  function updateRewardDebt(
    address _account,
    address _rewardToken,
    address _token,
    int256 _amount,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage ds
  ) internal {
    bytes32 _poolKey = LibMoneyMarket01.getPoolKey(_rewardToken, _token);
    ds.lenderRewardDebts[_account][_poolKey] +=
      (_amount * ds.lendingPoolInfos[_poolKey].accRewardPerShare.toInt256()) /
      LibMoneyMarket01.ACC_REWARD_PRECISION.toInt256();
  }

  function pendingReward(
    address _account,
    address _rewardToken,
    address _token,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage ds
  ) internal view returns (uint256 _actualReward) {
    bytes32 _poolKey = LibMoneyMarket01.getPoolKey(_rewardToken, _token);
    LibMoneyMarket01.PoolInfo storage poolInfo = ds.lendingPoolInfos[_poolKey];
    uint256 _accRewardPerShare = poolInfo.accRewardPerShare + _calculateRewardPerShare(_rewardToken, _token, ds);
    uint256 _amount = ds.accountCollats[_account][_token];

    int256 _rewardDebt = ds.lenderRewardDebts[_account][_poolKey];
    int256 _reward = ((_amount * _accRewardPerShare) / LibMoneyMarket01.ACC_REWARD_PRECISION).toInt256();
    _actualReward = (_reward - _rewardDebt).toUint256();
  }

  function updatePool(
    address _rewardToken,
    address _token,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage ds
  ) internal returns (LibMoneyMarket01.PoolInfo memory poolInfo) {
    bytes32 _poolKey = LibMoneyMarket01.getPoolKey(_rewardToken, _token);
    ds.lendingPoolInfos[_poolKey].accRewardPerShare += _calculateRewardPerShare(_rewardToken, _token, ds);
    ds.lendingPoolInfos[_poolKey].lastRewardTime = block.timestamp.toUint128();
    return ds.lendingPoolInfos[_poolKey];
  }

  function _calculateRewardPerShare(
    address _rewardToken,
    address _token,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage ds
  ) internal view returns (uint256 _rewardPerShare) {
    LibMoneyMarket01.PoolInfo memory poolInfo = ds.lendingPoolInfos[LibMoneyMarket01.getPoolKey(_rewardToken, _token)];
    if (block.timestamp > poolInfo.lastRewardTime) {
      uint256 _tokenBalance = ds.collats[_token];
      if (_tokenBalance > 0) {
        uint256 _timePast = block.timestamp - poolInfo.lastRewardTime;
        uint256 _reward = (_timePast *
          LibMoneyMarket01.getLendingRewardPerSec(_rewardToken, ds) *
          poolInfo.allocPoint) / ds.totalLendingPoolAllocPoints[_rewardToken];
        _rewardPerShare = (_reward * LibMoneyMarket01.ACC_REWARD_PRECISION) / _tokenBalance;
      }
    }
  }

  function massUpdatePoolInReward(address _rewardToken, LibMoneyMarket01.MoneyMarketDiamondStorage storage ds)
    internal
  {
    LibDoublyLinkedList.Node[] memory poolList = LibMoneyMarket01
      .moneyMarketDiamondStorage()
      .rewardLendingPoolList[_rewardToken]
      .getAll();

    uint256 _poolLength = poolList.length;

    for (uint256 _i = 0; _i < _poolLength; ) {
      updatePool(_rewardToken, poolList[_i].token, ds);
      unchecked {
        _i++;
      }
    }
  }

  function massUpdatePool(address _token, LibMoneyMarket01.MoneyMarketDiamondStorage storage ds) internal {
    LibDoublyLinkedList.Node[] memory rewardsPerSec = ds.lendingRewardPerSecList.getAll();
    uint256 _rewardsPerSecLength = rewardsPerSec.length;

    for (uint256 _i = 0; _i < _rewardsPerSecLength; ) {
      updatePool(rewardsPerSec[_i].token, _token, ds);
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
    LibDoublyLinkedList.Node[] memory rewardsPerSec = ds.lendingRewardPerSecList.getAll();
    uint256 _rewardsPerSecLength = rewardsPerSec.length;

    for (uint256 _i = 0; _i < _rewardsPerSecLength; ) {
      updateRewardDebt(_account, rewardsPerSec[_i].token, _token, _amount, ds);
      unchecked {
        _i++;
      }
    }
  }
}
