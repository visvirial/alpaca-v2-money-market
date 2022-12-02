// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// interfaces
import { IRewardFacet } from "../interfaces/IRewardFacet.sol";
import { IRewardDistributor } from "../interfaces/IRewardDistributor.sol";

// libraries
import { LibMoneyMarket01 } from "../libraries/LibMoneyMarket01.sol";
import { LibLendingReward } from "../libraries/LibLendingReward.sol";
import { LibBorrowingReward } from "../libraries/LibBorrowingReward.sol";
import { LibDoublyLinkedList } from "../libraries/LibDoublyLinkedList.sol";
import { LibReentrancyGuard } from "../libraries/LibReentrancyGuard.sol";

contract RewardFacet is IRewardFacet {
  using SafeERC20 for ERC20;
  using LibDoublyLinkedList for LibDoublyLinkedList.List;

  // events
  event LogClaimReward(address indexed _to, address _rewardToken, uint256 _amount);
  event LogClaimBorrowingRewardFor(address indexed _to, address _rewardToken, uint256 _amount);

  modifier nonReentrant() {
    LibReentrancyGuard.lock();
    _;
    LibReentrancyGuard.unlock();
  }

  function claimReward(address _token, address _rewardToken) external nonReentrant {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    uint256 _pendingReward = LibLendingReward.claim(msg.sender, _token, _rewardToken, moneyMarketDs);

    emit LogClaimReward(msg.sender, _rewardToken, _pendingReward);
  }

  function claimBorrowingRewardFor(
    address _to,
    address _token,
    address _rewardToken
  ) external nonReentrant {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    uint256 _pendingReward = LibBorrowingReward.claim(_to, _token, _rewardToken, moneyMarketDs);

    emit LogClaimBorrowingRewardFor(_to, _rewardToken, _pendingReward);
  }

  function pendingLendingReward(
    address _account,
    address _token,
    address _rewardToken
  ) external view returns (uint256) {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    return LibLendingReward.pendingReward(_account, _token, _rewardToken, moneyMarketDs);
  }

  function pendingBorrowingReward(
    address _account,
    address _token,
    address _rewardToken
  ) external view returns (uint256) {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    return LibBorrowingReward.pendingReward(_account, _token, _rewardToken, moneyMarketDs);
  }

  function lenderRewardDebts(
    address _account,
    address _token,
    address _rewardToken
  ) external view returns (int256) {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    return moneyMarketDs.lenderRewardDebts[_account][_token][_rewardToken];
  }

  function borrowerRewardDebts(
    address _account,
    address _token,
    address _rewardToken
  ) external view returns (int256) {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    return moneyMarketDs.borrowerRewardDebts[_account][_token][_rewardToken];
  }

  function getLendingPool(address _rewardToken, address _token)
    external
    view
    returns (LibMoneyMarket01.PoolInfo memory)
  {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    return moneyMarketDs.lendingPoolInfos[_rewardToken][_token];
  }

  function getBorrowingPool(address _rewardToken, address _token)
    external
    view
    returns (LibMoneyMarket01.PoolInfo memory)
  {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    return moneyMarketDs.borrowingPoolInfos[_rewardToken][_token];
  }
}
