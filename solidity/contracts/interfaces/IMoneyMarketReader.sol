// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

interface IMoneyMarketReader {
  struct MarketSummary {
    // ---- ibToken ---- //
    uint256 ibTotalSupply;
    uint256 ibTotalAsset;
    address ibAddress;
    // ---- Token Config ---- //
    uint8 tierAsUInt;
    uint16 collateralFactor;
    uint16 borrowingFactor;
    uint64 to18ConversionFactor;
    uint256 maxCollateral;
    uint256 maxBorrow;
    uint256 tokenPrice;
    // ---- Money Market ---- //
    uint256 globalDebtValue;
    uint256 totalToken;
    uint256 pendingIntetest;
    uint256 lastAccruedAt;
    // ---- MiniFL ---- //
    uint256 allocPoint;
    uint256 totalAllocPoint;
    uint256 rewardPerSec;
    uint256 blockTimestamp;
  }

  struct CollateralPosition {
    address token;
    uint256 amount;
    uint256 price;
    uint16 collateralFactor;
  }
  struct DebtPosition {
    address token;
    uint256 shares;
    uint256 amount;
    uint256 price;
    uint16 borrowingFactor;
  }

  struct SubAccountSummary {
    uint256 totalBorrowedValue;
    uint256 totalCollateralValue;
    uint256 totalBorrowingPower;
    uint256 totalUsedBorrowingPower;
    CollateralPosition[] collaterals;
    DebtPosition[] debts;
  }

  function getMarketSummary(address _underlyingToken) external view returns (MarketSummary memory);

  function getSubAccountSummary(address _account, uint256 _subAccountId)
    external
    view
    returns (SubAccountSummary memory);

  function moneyMarket() external view returns (address);
}