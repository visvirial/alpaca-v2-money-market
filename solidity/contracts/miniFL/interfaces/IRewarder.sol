// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IRewarder {
  function name() external view returns (string memory);

  function miniFL() external view returns (address);

  function onDeposit(
    uint256 pid,
    address user,
    uint256 newStakeTokenAmount
  ) external;

  function onWithdraw(
    uint256 pid,
    address user,
    uint256 newStakeTokenAmount
  ) external;

  function onHarvest(uint256 pid, address user) external;

  function pendingToken(uint256 pid, address user) external view returns (uint256);
}
