// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

interface IRewardFacet {
  function claimReward(address _token) external;

  function pendingReward(address _account, address _token) external view returns (uint256);

  function accountRewardDebts(address _account, address _token) external view returns (int256);

  // errors
  error RewardFacet_InvalidAddress();
  error RewardFacet_InvalidRewardDistributor();
}
