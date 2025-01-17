// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { MoneyMarket_BaseTest, console } from "../MoneyMarket_BaseTest.t.sol";

// interfaces
import { ILendFacet } from "../../../contracts/money-market/interfaces/ILendFacet.sol";
import { IERC20 } from "../../../contracts/money-market/interfaces/IERC20.sol";

// mocks
import { MockInterestModel } from "../../mocks/MockInterestModel.sol";

contract MoneyMarket_Lend_WithdrawTest is MoneyMarket_BaseTest {
  function setUp() public override {
    super.setUp();
  }

  function testCorrectness_WhenUserWithdraw_ibTokenShouldBurnedAndTransferTokenToUser() external {
    vm.startPrank(ALICE);
    accountManager.deposit(address(weth), 10 ether);
    vm.stopPrank();

    assertEq(weth.balanceOf(ALICE), 990 ether);
    assertEq(weth.balanceOf(moneyMarketDiamond), 10 ether);
    assertEq(ibWeth.balanceOf(ALICE), 10 ether);

    vm.startPrank(ALICE);
    accountManager.withdraw(address(ibWeth), 10 ether);
    vm.stopPrank();

    assertEq(ibWeth.totalSupply(), 0);
    assertEq(ibWeth.balanceOf(ALICE), 0);
    assertEq(weth.balanceOf(ALICE), 1000 ether);
  }

  function testRevert_WhenUserWithdrawInvalidibToken_ShouldRevert() external {
    address _randomToken = address(10);
    vm.startPrank(address(accountManager));
    vm.expectRevert(abi.encodeWithSelector(ILendFacet.LendFacet_InvalidToken.selector, _randomToken));
    lendFacet.withdraw(ALICE, _randomToken, 10 ether);
    vm.stopPrank();
  }

  function testCorrectness_WhenMultipleUserWithdraw_ShareShouldBurnedAndTransferTokenBackCorrectly() external {
    uint256 _depositAmount1 = 10 ether;
    uint256 _depositAmount2 = 20 ether;
    uint256 _expectedTotalShare = 0;

    vm.startPrank(ALICE);
    accountManager.deposit(address(weth), _depositAmount1);
    vm.stopPrank();

    // first depositor mintShare = depositAmount = 10
    _expectedTotalShare += _depositAmount1;
    assertEq(ibWeth.balanceOf(ALICE), _depositAmount1);

    vm.startPrank(BOB);
    accountManager.deposit(address(weth), _depositAmount2);
    vm.stopPrank();

    // mintShare = 20 * 10 / 10 = 20
    uint256 _expectedBoBShare = 20 ether;
    _expectedTotalShare += _expectedBoBShare;
    assertEq(ibWeth.balanceOf(BOB), 20 ether);
    assertEq(ibWeth.totalSupply(), _expectedTotalShare);

    // alice withdraw share
    vm.startPrank(ALICE);
    _expectedTotalShare -= 10 ether;
    accountManager.withdraw(address(ibWeth), 10 ether);
    vm.stopPrank();

    assertEq(weth.balanceOf(ALICE), 1000 ether);
    assertEq(ibWeth.balanceOf(ALICE), 0);
    assertEq(ibWeth.totalSupply(), _expectedTotalShare);

    // bob withdraw share
    vm.startPrank(BOB);
    _expectedTotalShare -= 20 ether;
    accountManager.withdraw(address(ibWeth), 20 ether);
    vm.stopPrank();

    assertEq(weth.balanceOf(BOB), 1000 ether);
    assertEq(ibWeth.balanceOf(BOB), 0);
    assertEq(ibWeth.totalSupply(), _expectedTotalShare);
  }

  function testCorrectness_WhenTryToExploitTinySharesOnLendFacet_ShouldDepositWithdrawCorrectlyWithoutTinyShares()
    external
  {
    // no tiny share exploit since we use reserves state variable internally instead of balanceOf

    // exploiter deposit 1 wei weth, get 1 wei ibWeth back
    vm.startPrank(ALICE);
    accountManager.deposit(address(weth), 1);

    assertEq(ibWeth.balanceOf(ALICE), 1);

    // exploiter direct transfer 1B weth
    weth.mint(ALICE, 1e10 ether);
    weth.transfer(moneyMarketDiamond, 1e10 ether);
    vm.stopPrank();

    // user deposit 1M weth, get 1M ibWeth back
    weth.mint(BOB, 1e7 ether);
    vm.startPrank(BOB);
    accountManager.deposit(address(weth), 1e7 ether);

    assertEq(ibWeth.balanceOf(BOB), 1e7 ether);

    // user withdraw 1M ibWeth, get 1M weth back
    uint256 _bobWethBalanceBefore = weth.balanceOf(BOB);
    accountManager.withdraw(address(ibWeth), 1e7 ether);

    assertEq(weth.balanceOf(BOB) - _bobWethBalanceBefore, 1e7 ether);
    vm.stopPrank();

    // exploiter withdraw 1 wei ibWeth, get 1 wei weth back
    uint256 _aliceWethBalanceBefore = weth.balanceOf(ALICE);

    vm.prank(ALICE);
    accountManager.withdraw(address(ibWeth), 1);

    assertEq(weth.balanceOf(ALICE) - _aliceWethBalanceBefore, 1);
  }

  function testCorrectness_WhenUnderlyingWasBorrowedAndAccrueInterest_AndUserPartialWithdraw_ShouldAccrueInterestAndTransferPrincipalWithInterestAndUpdateMMState()
    external
  {
    /**
     * scenario
     * 1. ALICE deposit 2 usdc, get 2 ibUsdc back
     * 2. BOB add 10 weth collateral, borrow 1 weth
     * 3. time past 1 second, weth pending interest increase to 0.01 weth
     *    - BOB borrow 1 weth with 0.01 ether interest per second
     *    - pending interest = rate * timePast * debtValue = 0.01 ether * 1 * 1 ether = 0.01 ether
     * 4. ALICE withdraw 0.2 ibUsdc (10% of vault), get 0.201 usdc back (principal + interest)
     */
    MockInterestModel _interestModel = new MockInterestModel(0.01 ether);
    adminFacet.setInterestModel(address(weth), address(_interestModel));
    adminFacet.setInterestModel(address(usdc), address(_interestModel));

    address _token = address(usdc);

    vm.prank(ALICE);
    accountManager.deposit(_token, normalizeEther(2 ether, usdcDecimal));

    vm.startPrank(BOB);
    accountManager.addCollateralFor(BOB, subAccount0, address(weth), 10 ether);
    accountManager.borrow(subAccount0, _token, normalizeEther(1 ether, usdcDecimal));
    vm.stopPrank();

    vm.warp(block.timestamp + 1);

    assertEq(viewFacet.getGlobalPendingInterest(_token), normalizeEther(0.01 ether, usdcDecimal));

    uint256 _aliceUsdcBalanceBefore = usdc.balanceOf(ALICE);

    // check ib functions
    assertEq(ibUsdc.convertToAssets(0.2 ether), 0.201 ether);
    assertEq(ibUsdc.convertToShares(0.201 ether), 0.2 ether);

    vm.prank(ALICE);
    accountManager.withdraw(address(ibUsdc), normalizeEther(0.2 ether, ibUsdcDecimal));

    // check ALICE state
    assertEq(usdc.balanceOf(ALICE) - _aliceUsdcBalanceBefore, normalizeEther(0.201 ether, usdcDecimal));

    // check mm state
    assertEq(viewFacet.getGlobalPendingInterest(_token), 0);
    assertEq(viewFacet.getDebtLastAccruedAt(_token), block.timestamp);
    assertEq(viewFacet.getTotalToken(_token), normalizeEther(1.809 ether, usdcDecimal));
    assertEq(viewFacet.getTotalTokenWithPendingInterest(_token), normalizeEther(1.809 ether, usdcDecimal));
  }

  function testCorrectness_WhenUserWithdrawETH_ShareShouldBurnedAndTransferTokenBackCorrectly() external {
    // deposit first
    vm.prank(ALICE);
    accountManager.depositETH{ value: 10 ether }();

    assertEq(wNativeToken.balanceOf(ALICE), 0 ether);
    assertEq(ALICE.balance, 990 ether);
    assertEq(wNativeToken.balanceOf(moneyMarketDiamond), 10 ether);

    assertEq(ibWNative.balanceOf(ALICE), 10 ether);

    // then withdraw 5
    vm.prank(ALICE);
    accountManager.withdrawETH(5 ether);

    assertEq(wNativeToken.balanceOf(ALICE), 0 ether);
    assertEq(ALICE.balance, 995 ether);
    assertEq(wNativeToken.balanceOf(moneyMarketDiamond), 5 ether);

    assertEq(ibWNative.balanceOf(ALICE), 5 ether);
  }
}
