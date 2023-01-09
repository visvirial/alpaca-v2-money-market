// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { AV_BaseTest, console } from "./AV_BaseTest.t.sol";

import { LibAV01 } from "../../contracts/automated-vault/libraries/LibAV01.sol";

contract AV_Trade_ManagementFeeTest is AV_BaseTest {
  function setUp() public override {
    super.setUp();
  }

  function testCorrectness_GetPendingManagementFee() external {
    // managementFeePerSec = 1, set in AV_BaseTest

    // block.timestamp = 1
    assertEq(tradeFacet.pendingManagementFee(address(avShareToken)), 0); // totalSupply(avShareToken) = 0

    vm.prank(ALICE);
    tradeFacet.deposit(address(avShareToken), 1 ether, 1 ether);
    assertEq(tradeFacet.pendingManagementFee(address(avShareToken)), 0);

    // time pass = 2 seconds
    vm.warp(block.timestamp + 2);
    assertEq(tradeFacet.pendingManagementFee(address(avShareToken)), 2);
  }

  function testCorrectness_WhenDepositAndWithdraw_ShouldMintPendingManagementFeeToTreasury() external {
    assertEq(tradeFacet.pendingManagementFee(address(avShareToken)), 0);

    vm.prank(ALICE);
    tradeFacet.deposit(address(avShareToken), 1 ether, 1 ether);

    assertEq(tradeFacet.pendingManagementFee(address(avShareToken)), 0); // fee was collected during deposit, so no more pending fee in the same block
    assertEq(avShareToken.balanceOf(treasury), 0);

    vm.warp(block.timestamp + 2);
    assertEq(tradeFacet.pendingManagementFee(address(avShareToken)), 2);

    mockRouter.setRemoveLiquidityAmountsOut(1 ether, 1 ether);
    vm.prank(ALICE);
    tradeFacet.withdraw(address(avShareToken), 1 ether, 0);

    assertEq(tradeFacet.pendingManagementFee(address(avShareToken)), 0);
    assertEq(avShareToken.balanceOf(treasury), 2);
  }
}