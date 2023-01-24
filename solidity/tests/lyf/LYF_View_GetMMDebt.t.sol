// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { LYF_BaseTest, MockERC20, console } from "./LYF_BaseTest.t.sol";

// interfaces
import { IMoneyMarket } from "../../contracts/lyf/interfaces/IMoneyMarket.sol";
import { ILYFFarmFacet } from "../../contracts/lyf/interfaces/ILYFFarmFacet.sol";

contract LYF_Farm_GetMMDebtTest is LYF_BaseTest {
  function setUp() public override {
    super.setUp();
  }

  function testCorrectness_GetMMDebt_ShouldWork() external {
    uint256 _wethToAddLP = 30 ether;
    uint256 _usdcToAddLP = 30 ether;
    uint256 _wethCollatAmount = 20 ether;
    uint256 _usdcCollatAmount = 20 ether;

    vm.startPrank(BOB);
    collateralFacet.addCollateral(BOB, subAccount0, address(weth), _wethCollatAmount);
    collateralFacet.addCollateral(BOB, subAccount0, address(usdc), _usdcCollatAmount);

    ILYFFarmFacet.AddFarmPositionInput memory _input = ILYFFarmFacet.AddFarmPositionInput({
      subAccountId: subAccount0,
      lpToken: address(wethUsdcLPToken),
      minLpReceive: 0,
      desireToken0Amount: _wethToAddLP,
      desireToken1Amount: _usdcToAddLP,
      token0ToBorrow: _wethToAddLP,
      token1ToBorrow: _usdcToAddLP,
      token0AmountIn: 0,
      token1AmountIn: 0
    });
    farmFacet.newAddFarmPosition(_input);

    vm.stopPrank();

    uint256 debtAmount = viewFacet.getMMDebt(address(weth));
    uint256 mmDebtAmount = IMoneyMarket(moneyMarketDiamond).getNonCollatAccountDebt(address(lyfDiamond), address(weth));

    assertEq(debtAmount, mmDebtAmount);
  }
}
