// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { MoneyMarket_BaseTest, MockERC20, console } from "./MoneyMarket_BaseTest.t.sol";

// interfaces
import { IBorrowFacet, LibDoublyLinkedList } from "../../contracts/money-market/facets/BorrowFacet.sol";
import { IAdminFacet } from "../../contracts/money-market/facets/AdminFacet.sol";
import { FixedInterestRateModel, IInterestRateModel } from "../../contracts/money-market/interest-models/FixedInterestRateModel.sol";
import { TripleSlopeModel6, IInterestRateModel } from "../../contracts/money-market/interest-models/TripleSlopeModel6.sol";
import { TripleSlopeModel7 } from "../../contracts/money-market/interest-models/TripleSlopeModel7.sol";

contract MoneyMarket_AccrueInterestTest is MoneyMarket_BaseTest {
  MockERC20 mockToken;

  function setUp() public override {
    super.setUp();

    mockToken = deployMockErc20("Mock token", "MOCK", 18);
    mockToken.mint(ALICE, 1000 ether);

    FixedInterestRateModel model = new FixedInterestRateModel();
    TripleSlopeModel6 tripleSlope6 = new TripleSlopeModel6();
    TripleSlopeModel7 tripleSlope7 = new TripleSlopeModel7();
    adminFacet.setInterestModel(address(weth), address(model));
    adminFacet.setInterestModel(address(usdc), address(tripleSlope6));
    adminFacet.setInterestModel(address(isolateToken), address(model));

    // non collat
    adminFacet.setNonCollatBorrower(ALICE, true);
    adminFacet.setNonCollatBorrower(BOB, true);

    adminFacet.setNonCollatInterestModel(ALICE, address(weth), address(model));
    adminFacet.setNonCollatInterestModel(ALICE, address(btc), address(tripleSlope6));
    adminFacet.setNonCollatInterestModel(BOB, address(weth), address(model));
    adminFacet.setNonCollatInterestModel(BOB, address(btc), address(tripleSlope7));

    IAdminFacet.NonCollatBorrowLimitInput[] memory _limitInputs = new IAdminFacet.NonCollatBorrowLimitInput[](2);
    _limitInputs[0] = IAdminFacet.NonCollatBorrowLimitInput({ account: ALICE, limit: 1e30 });
    _limitInputs[1] = IAdminFacet.NonCollatBorrowLimitInput({ account: BOB, limit: 1e30 });
    adminFacet.setNonCollatBorrowLimitUSDValues(_limitInputs);

    vm.startPrank(ALICE);
    lendFacet.deposit(address(weth), 50 ether);
    lendFacet.deposit(address(btc), 100 ether);
    lendFacet.deposit(address(usdc), 20 ether);
    lendFacet.deposit(address(isolateToken), 20 ether);
    vm.stopPrank();
  }

  function testCorrectness_WhenUserBorrowTokenFromMM_ShouldBeCorrectPendingInterest() external {
    uint256 _actualInterest = borrowFacet.pendingInterest(address(weth));
    assertEq(_actualInterest, 0);

    uint256 _borrowAmount = 10 ether;

    vm.startPrank(BOB);
    collateralFacet.addCollateral(BOB, subAccount0, address(weth), _borrowAmount * 2);

    uint256 _bobBalanceBefore = weth.balanceOf(BOB);
    borrowFacet.borrow(subAccount0, address(weth), _borrowAmount);
    vm.stopPrank();

    uint256 _bobBalanceAfter = weth.balanceOf(BOB);

    assertEq(_bobBalanceAfter - _bobBalanceBefore, _borrowAmount);

    uint256 _debtAmount;
    (, _debtAmount) = borrowFacet.getDebt(BOB, subAccount0, address(weth));
    assertEq(_debtAmount, _borrowAmount);

    vm.warp(block.timestamp + 10);

    uint256 _expectedDebtAmount = 1e18 + _borrowAmount;

    uint256 _actualInterestAfter = borrowFacet.pendingInterest(address(weth));
    assertEq(_actualInterestAfter, 1e18);
    borrowFacet.accrueInterest(address(weth));
    (, uint256 _actualDebtAmount) = borrowFacet.getDebt(BOB, subAccount0, address(weth));
    assertEq(_actualDebtAmount, _expectedDebtAmount);

    uint256 _actualAccrueTime = borrowFacet.debtLastAccrueTime(address(weth));
    assertEq(_actualAccrueTime, block.timestamp);
  }

  function testCorrectness_WhenAddCollateralAndUserBorrow_ShouldNotGetInterest() external {
    uint256 _balanceAliceBefore = weth.balanceOf(ALICE);
    uint256 _balanceMMDiamondBefore = weth.balanceOf(moneyMarketDiamond);
    uint256 _aliceCollateralAmount = 10 ether;

    vm.startPrank(ALICE);
    weth.approve(moneyMarketDiamond, _aliceCollateralAmount);
    collateralFacet.addCollateral(ALICE, 0, address(weth), _aliceCollateralAmount);
    vm.stopPrank();

    assertEq(weth.balanceOf(ALICE), _balanceAliceBefore - _aliceCollateralAmount);
    assertEq(weth.balanceOf(moneyMarketDiamond), _balanceMMDiamondBefore + _aliceCollateralAmount);

    vm.warp(block.timestamp + 10);

    //when someone borrow
    uint256 _bobBorrowAmount = 10 ether;
    vm.startPrank(BOB);
    collateralFacet.addCollateral(BOB, subAccount0, address(weth), _bobBorrowAmount * 2);

    uint256 _bobBalanceBeforeBorrow = weth.balanceOf(BOB);
    borrowFacet.borrow(subAccount0, address(weth), _bobBorrowAmount);

    (, uint256 _actualBobDebtAmountBeforeWarp) = borrowFacet.getDebt(BOB, subAccount0, address(weth));
    assertEq(_actualBobDebtAmountBeforeWarp, _bobBorrowAmount);
    vm.stopPrank();

    uint256 _bobBalanceAfterBorrow = weth.balanceOf(BOB);

    assertEq(_bobBalanceAfterBorrow - _bobBalanceBeforeBorrow, _bobBorrowAmount);
    vm.warp(block.timestamp + 10);

    borrowFacet.accrueInterest(address(weth));
    (, uint256 _actualBobDebtAmountAfter) = borrowFacet.getDebt(BOB, subAccount0, address(weth));

    assertEq(_actualBobDebtAmountAfter - _actualBobDebtAmountBeforeWarp, 1 ether);

    uint256 wethAliceBeforeWithdraw = weth.balanceOf(ALICE);
    vm.prank(ALICE);
    collateralFacet.removeCollateral(0, address(weth), 10 ether);
    uint256 wethAliceAfterWithdraw = weth.balanceOf(ALICE);
    assertEq(wethAliceAfterWithdraw - wethAliceBeforeWithdraw, 10 ether);
    LibDoublyLinkedList.Node[] memory collats = collateralFacet.getCollaterals(ALICE, 0);
    assertEq(collats.length, 0);
  }

  /* 2 borrower 1 depositors
    alice deposit
    bob borrow
  */
  function testCorrectness_WhenMultipleUserBorrow_ShouldaccrueInterestCorrectly() external {
    // BOB add ALICE add collateral
    uint256 _actualInterest = borrowFacet.pendingInterest(address(weth));
    assertEq(_actualInterest, 0);

    uint256 _borrowAmount = 10 ether;

    vm.prank(BOB);
    collateralFacet.addCollateral(BOB, subAccount0, address(weth), _borrowAmount * 2);

    vm.prank(ALICE);
    collateralFacet.addCollateral(ALICE, subAccount0, address(weth), _borrowAmount * 2);

    // BOB borrow
    vm.startPrank(BOB);
    uint256 _bobBalanceBefore = weth.balanceOf(BOB);
    borrowFacet.borrow(subAccount0, address(weth), _borrowAmount);
    vm.stopPrank();

    uint256 _bobBalanceAfter = weth.balanceOf(BOB);

    assertEq(_bobBalanceAfter - _bobBalanceBefore, _borrowAmount);
    vm.stopPrank();

    // time past
    vm.warp(block.timestamp + 10);

    // ALICE borrow and bob's interest accrue
    vm.startPrank(ALICE);
    uint256 _aliceBalanceBefore = weth.balanceOf(ALICE);
    borrowFacet.borrow(subAccount0, address(weth), _borrowAmount);
    vm.stopPrank();

    uint256 _aliceBalanceAfter = weth.balanceOf(ALICE);

    assertEq(_aliceBalanceAfter - _aliceBalanceBefore, _borrowAmount);
    assertEq(borrowFacet.debtLastAccrueTime(address(weth)), block.timestamp);

    // assert BOB
    (, uint256 _bobActualDebtAmount) = borrowFacet.getDebt(BOB, subAccount0, address(weth));
    // bob borrow 10 with 0.1 interest rate per sec
    // precision loss
    // 10 second passed _bobExpectedDebtAmount = 10 + (10*0.1) ~ 11 = 10999999999999999999
    uint256 _bobExpectedDebtAmount = 10.999999999999999999 ether;
    assertEq(_bobActualDebtAmount, _bobExpectedDebtAmount);

    // assert ALICE
    (, uint256 _aliceActualDebtAmount) = borrowFacet.getDebt(ALICE, subAccount0, address(weth));
    // _aliceExpectedDebtAmount should be 10 ether
    // so _aliceExpectedDebtAmount = 10 ether
    uint256 _aliceExpectedDebtAmount = 10 ether;
    assertEq(_aliceActualDebtAmount, _aliceExpectedDebtAmount, "Alice debtAmount missmatch");

    // assert Global
    // from BOB 10 + 1, Alice 10
    assertEq(borrowFacet.debtValues(address(weth)), 21 ether, "Global debtValues missmatch");

    // assert IB exchange rate change
    // alice wthdraw 10 ibWeth, totalToken = 51, totalSupply = 50
    // alice should get = 10 * 51 / 50 = 10.2 eth
    uint256 _expectdAmount = 10.2 ether;
    _aliceBalanceBefore = weth.balanceOf(ALICE);
    vm.prank(ALICE);
    lendFacet.withdraw(address(ibWeth), _borrowAmount);
    _aliceBalanceAfter = weth.balanceOf(ALICE);

    assertEq(_aliceBalanceAfter - _aliceBalanceBefore, _expectdAmount, "ALICE weth balance missmatch");
  }

  function testCorrectness_WhenUserCallDeposit_InterestShouldAccrue() external {
    uint256 _timeStampBefore = block.timestamp;
    uint256 _secondPassed = 10;
    assertEq(borrowFacet.debtLastAccrueTime(address(weth)), _timeStampBefore);

    vm.warp(block.timestamp + _secondPassed);

    vm.startPrank(ALICE);
    weth.approve(moneyMarketDiamond, 10 ether);
    lendFacet.deposit(address(weth), 10 ether);
    vm.stopPrank();

    assertEq(borrowFacet.debtLastAccrueTime(address(weth)), _timeStampBefore + _secondPassed);
  }

  function testCorrectness_WhenUserCallWithdraw_InterestShouldAccrue() external {
    uint256 _timeStampBefore = block.timestamp;
    uint256 _secondPassed = 10;

    vm.prank(ALICE);
    lendFacet.deposit(address(weth), 10 ether);

    assertEq(borrowFacet.debtLastAccrueTime(address(weth)), _timeStampBefore);

    vm.warp(block.timestamp + _secondPassed);

    vm.prank(ALICE);
    lendFacet.withdraw(address(ibWeth), 10 ether);

    assertEq(borrowFacet.debtLastAccrueTime(address(weth)), _timeStampBefore + _secondPassed);
  }

  function testCorrectness_WhenMMUseTripleSlopeInterestModel_InterestShouldAccrueCorrectly() external {
    // BOB add ALICE add collateral
    uint256 _actualInterest = borrowFacet.pendingInterest(address(usdc));
    assertEq(_actualInterest, 0);

    uint256 _borrowAmount = 10 ether;

    vm.prank(BOB);
    collateralFacet.addCollateral(BOB, subAccount0, address(usdc), _borrowAmount * 2);

    vm.prank(ALICE);
    collateralFacet.addCollateral(ALICE, subAccount0, address(usdc), _borrowAmount * 2);

    // BOB borrow
    vm.startPrank(BOB);
    uint256 _bobBalanceBefore = usdc.balanceOf(BOB);
    borrowFacet.borrow(subAccount0, address(usdc), _borrowAmount);
    vm.stopPrank();

    uint256 _bobBalanceAfter = usdc.balanceOf(BOB);

    assertEq(_bobBalanceAfter - _bobBalanceBefore, _borrowAmount);
    vm.stopPrank();

    // time past
    uint256 _secondPassed = 1 days;
    vm.warp(block.timestamp + _secondPassed);

    // ALICE borrow and bob's interest accrue
    vm.startPrank(ALICE);
    uint256 _aliceBalanceBefore = usdc.balanceOf(ALICE);
    borrowFacet.borrow(subAccount0, address(usdc), _borrowAmount);
    vm.stopPrank();

    uint256 _aliceBalanceAfter = usdc.balanceOf(ALICE);

    assertEq(_aliceBalanceAfter - _aliceBalanceBefore, _borrowAmount);
    assertEq(borrowFacet.debtLastAccrueTime(address(usdc)), block.timestamp);

    // assert BOB
    (, uint256 _bobActualDebtAmount) = borrowFacet.getDebt(BOB, subAccount0, address(usdc));
    // bob borrow 10 usdc, pool has 20 usdc, utilization = 50%
    // interest rate = 10.2941176456512000% per year
    // 1 day passed _bobExpectedDebtAmount = debtAmount + (debtAmount * seconedPass * ratePerSec)
    // = 10 + (10 * 1 * 0.102941176456512000/365) ~ 10.002820306204288000 = 10.002820306204287999
    uint256 _bobExpectedDebtAmount = 10.002820306204287999 ether;
    assertEq(_bobActualDebtAmount, _bobExpectedDebtAmount);

    // assert ALICE
    (, uint256 _aliceActualDebtAmount) = borrowFacet.getDebt(ALICE, subAccount0, address(usdc));
    // _aliceExpectedDebtAmount should be 10 ether
    // so _aliceExpectedDebtAmount = 10 ether
    uint256 _aliceExpectedDebtAmount = 10 ether;
    assertEq(_aliceActualDebtAmount, _aliceExpectedDebtAmount, "Alice debtAmount missmatch");

    // assert Global
    // from BOB 10 + 0.002820306204288 =, Alice 10 = 20.002820306204288
    assertEq(borrowFacet.debtValues(address(usdc)), 20.002820306204288 ether, "Global debtValues missmatch");

    // assert IB exchange rate change
    // alice wthdraw 10 ibUSDC, totalToken = 20.002820306204288, totalSupply = 20
    // alice should get = 10 * 20.002820306204288 / 20 = 10.2 eth
    uint256 _expectdAmount = 10.001410153102144 ether;
    _aliceBalanceBefore = usdc.balanceOf(ALICE);
    vm.prank(ALICE);
    lendFacet.withdraw(address(ibUsdc), _borrowAmount);
    _aliceBalanceAfter = usdc.balanceOf(ALICE);

    assertEq(_aliceBalanceAfter - _aliceBalanceBefore, _expectdAmount, "ALICE weth balance missmatch");
  }

  function testCorrectness_WhenUserBorrowBothOverCollatAndNonCollat_ShouldaccrueInterestCorrectly() external {
    uint256 _actualInterest = borrowFacet.pendingInterest(address(weth));
    assertEq(_actualInterest, 0);

    uint256 _borrowAmount = 10 ether;
    uint256 _nonCollatBorrowAmount = 10 ether;

    vm.startPrank(BOB);
    collateralFacet.addCollateral(BOB, subAccount0, address(weth), _borrowAmount * 2);

    uint256 _bobBalanceBefore = weth.balanceOf(BOB);
    // bob borrow
    borrowFacet.borrow(subAccount0, address(weth), _borrowAmount);
    //bob non collat borrow
    nonCollatBorrowFacet.nonCollatBorrow(address(weth), _nonCollatBorrowAmount);
    vm.stopPrank();

    uint256 _bobBalanceAfter = weth.balanceOf(BOB);

    assertEq(_bobBalanceAfter - _bobBalanceBefore, _borrowAmount + _nonCollatBorrowAmount);

    uint256 _debtAmount;
    (, _debtAmount) = borrowFacet.getDebt(BOB, subAccount0, address(weth));
    uint256 _nonCollatDebtAmount = nonCollatBorrowFacet.nonCollatGetDebt(BOB, address(weth));
    assertEq(_debtAmount, _borrowAmount);
    assertEq(_nonCollatDebtAmount, _nonCollatBorrowAmount);

    vm.warp(block.timestamp + 10);

    uint256 _expectedDebtAmount = 2e18 + _borrowAmount;
    uint256 _expectedNonDebtAmount = 2e18 + _nonCollatBorrowAmount;

    uint256 _actualInterestAfter = borrowFacet.pendingInterest(address(weth));
    assertEq(_actualInterestAfter, 4e18);
    borrowFacet.accrueInterest(address(weth));
    (, uint256 _actualDebtAmount) = borrowFacet.getDebt(BOB, subAccount0, address(weth));
    assertEq(_actualDebtAmount, _expectedDebtAmount);
    uint256 _bobNonCollatDebt = nonCollatBorrowFacet.nonCollatGetDebt(BOB, address(weth));
    uint256 _tokenCollatDebt = nonCollatBorrowFacet.nonCollatGetTokenDebt(address(weth));
    assertEq(_bobNonCollatDebt, _expectedNonDebtAmount);
    assertEq(_tokenCollatDebt, _expectedNonDebtAmount);

    uint256 _actualAccrueTime = borrowFacet.debtLastAccrueTime(address(weth));
    assertEq(_actualAccrueTime, block.timestamp);
  }

  function testCorrectness_WhenAccrueInterestAndThereIsLendingFee_ProtocolShouldGetRevenue() external {
    // set lending fee to 100 bps
    adminFacet.setFees(100, 0, 0, 0);
    uint256 _actualInterest = borrowFacet.pendingInterest(address(weth));
    assertEq(_actualInterest, 0);

    uint256 _borrowAmount = 10 ether;
    uint256 _nonCollatBorrowAmount = 10 ether;

    vm.startPrank(BOB);
    collateralFacet.addCollateral(BOB, subAccount0, address(weth), _borrowAmount * 2);

    uint256 _bobBalanceBefore = weth.balanceOf(BOB);
    // bob borrow
    borrowFacet.borrow(subAccount0, address(weth), _borrowAmount);
    //bob non collat borrow
    nonCollatBorrowFacet.nonCollatBorrow(address(weth), _nonCollatBorrowAmount);
    vm.stopPrank();

    uint256 _bobBalanceAfter = weth.balanceOf(BOB);

    assertEq(_bobBalanceAfter - _bobBalanceBefore, _borrowAmount + _nonCollatBorrowAmount);

    uint256 _debtAmount;
    (, _debtAmount) = borrowFacet.getDebt(BOB, subAccount0, address(weth));
    uint256 _nonCollatDebtAmount = nonCollatBorrowFacet.nonCollatGetDebt(BOB, address(weth));
    assertEq(_debtAmount, _borrowAmount);
    assertEq(_nonCollatDebtAmount, _nonCollatBorrowAmount);

    vm.warp(block.timestamp + 10);

    uint256 _expectedDebtAmount = 2e18 + _borrowAmount;
    uint256 _expectedNonDebtAmount = 2e18 + _nonCollatBorrowAmount;

    uint256 _actualInterestAfter = borrowFacet.pendingInterest(address(weth));
    assertEq(_actualInterestAfter, 4e18);
    borrowFacet.accrueInterest(address(weth));
    (, uint256 _actualDebtAmount) = borrowFacet.getDebt(BOB, subAccount0, address(weth));
    assertEq(_actualDebtAmount, _expectedDebtAmount);
    uint256 _bobNonCollatDebt = nonCollatBorrowFacet.nonCollatGetDebt(BOB, address(weth));
    uint256 _tokenCollatDebt = nonCollatBorrowFacet.nonCollatGetTokenDebt(address(weth));
    assertEq(_bobNonCollatDebt, _expectedNonDebtAmount);
    assertEq(_tokenCollatDebt, _expectedNonDebtAmount);

    uint256 _actualAccrueTime = borrowFacet.debtLastAccrueTime(address(weth));
    assertEq(_actualAccrueTime, block.timestamp);

    // total token without lending fee = 54000000000000000000
    // 100 bps for lending fee on interest = (4e18 * 100 / 10000) = 4 e16
    // total token =  54 e18 - 4e16 = 5396e16
    assertEq(lendFacet.getTotalToken(address(weth)), 5396e16);
    assertEq(adminFacet.getReservePool(address(weth)), 4e16);

    // test withdrawing reserve
    vm.expectRevert(IAdminFacet.AdminFacet_ReserveTooLow.selector);
    adminFacet.withdrawReserve(address(weth), address(this), 5e16);

    vm.prank(ALICE);
    vm.expectRevert("LibDiamond: Must be contract owner");
    adminFacet.withdrawReserve(address(weth), address(this), 4e16);

    adminFacet.withdrawReserve(address(weth), address(this), 4e16);
    assertEq(adminFacet.getReservePool(address(weth)), 0);
    assertEq(lendFacet.getTotalToken(address(weth)), 5396e16);
  }

  function testCorrectness_WhenUsersBorrowSameTokenButDifferentInterestModel_ShouldaccrueInterestCorrectly() external {
    uint256 _aliceBorrowAmount = 15 ether;
    uint256 _bobBorrowAmount = 15 ether;

    vm.prank(ALICE);
    collateralFacet.addCollateral(ALICE, subAccount0, address(btc), _aliceBorrowAmount * 2);

    vm.prank(BOB);
    collateralFacet.addCollateral(BOB, subAccount0, address(btc), _bobBorrowAmount * 2);

    uint256 _aliceBalanceBefore = btc.balanceOf(ALICE);
    uint256 _bobBalanceBefore = btc.balanceOf(BOB);

    vm.prank(ALICE);
    nonCollatBorrowFacet.nonCollatBorrow(address(btc), _aliceBorrowAmount);

    assertEq(btc.balanceOf(ALICE) - _aliceBalanceBefore, _aliceBorrowAmount);

    vm.prank(BOB);
    nonCollatBorrowFacet.nonCollatBorrow(address(btc), _bobBorrowAmount);

    assertEq(btc.balanceOf(BOB) - _bobBalanceBefore, _bobBorrowAmount);

    uint256 _secondPassed = 1 days;
    vm.warp(block.timestamp + _secondPassed);

    borrowFacet.accrueInterest(address(btc));

    // alice and bob both borrowed 15 on each, total is 30, pool has 100 btc, utilization = 30%
    // for alice has interest rate = 6.1764705867600000% per year
    // for bob has interest rate = 8.5714285713120000% per year
    // 1 day passed _bobExpectedDebtAmount = debtAmount + (debtAmount * seconedPass * ratePerSec)
    // alice = 15 + (15 * 1 * 0.061764705867600000/365) = 15.002538275583600000
    // bob = 15 + (15 * 1 * 0.085714285713120000/365) = 15.003522504892320000
    uint256 _aliceDebt = nonCollatBorrowFacet.nonCollatGetDebt(ALICE, address(btc));
    assertEq(_aliceDebt, 15.002538275583600000 ether, "Alice debtAmount mismatch");
    uint256 _bobDebt = nonCollatBorrowFacet.nonCollatGetDebt(BOB, address(btc));
    assertEq(_bobDebt, 15.003522504892320000 ether, "Bob debtAmount mismatch");

    // assert Global
    // from Alice 15.002538275583600000, Bob 15.003522504892320000 = 15.002538275583600000 + 15.003522504892320000 = 30.006060780475920000
    assertEq(
      nonCollatBorrowFacet.nonCollatGetTokenDebt(address(btc)),
      30.006060780475920000 ether,
      "Global debtValues missmatch"
    );
  }

  function testCorrectness_WhenUserBorrowMultipleTokenAndRemoveCollateral_ShouldaccrueInterestForAllBorrowedToken()
    external
  {
    // ALICE add collateral
    uint256 _borrowAmount = 10 ether;

    vm.startPrank(ALICE);
    collateralFacet.addCollateral(ALICE, subAccount0, address(weth), _borrowAmount * 2);
    collateralFacet.addCollateral(ALICE, subAccount0, address(usdc), _borrowAmount * 2);
    vm.stopPrank();

    // BOB borrow
    vm.startPrank(ALICE);
    borrowFacet.borrow(subAccount0, address(weth), _borrowAmount);
    borrowFacet.borrow(subAccount0, address(usdc), _borrowAmount);
    vm.stopPrank();

    // time past
    vm.warp(block.timestamp + 10);

    vm.startPrank(ALICE);
    // remove collateral will trigger accrue interest on all borrowed token
    collateralFacet.removeCollateral(subAccount0, address(weth), 0);
    vm.stopPrank();

    // assert ALICE
    (, uint256 _aliceActualWethDebtAmount) = borrowFacet.getDebt(ALICE, subAccount0, address(weth));
    (, uint256 _aliceActualUSDCDebtAmount) = borrowFacet.getDebt(ALICE, subAccount0, address(usdc));

    assertGt(_aliceActualWethDebtAmount, _borrowAmount);
    assertGt(_aliceActualUSDCDebtAmount, _borrowAmount);

    //assert Global
    assertGt(borrowFacet.debtValues(address(weth)), _borrowAmount);
    assertGt(borrowFacet.debtValues(address(usdc)), _borrowAmount);
  }

  function testCorrectness_WhenUserBorrowMultipleTokenAndTransferCollateral_ShouldaccrueInterestForAllBorrowedToken()
    external
  {
    // ALICE add collateral
    uint256 _borrowAmount = 10 ether;

    vm.startPrank(ALICE);
    collateralFacet.addCollateral(ALICE, subAccount0, address(weth), _borrowAmount * 2);
    collateralFacet.addCollateral(ALICE, subAccount0, address(usdc), _borrowAmount * 2);
    vm.stopPrank();

    // BOB borrow
    vm.startPrank(ALICE);
    borrowFacet.borrow(subAccount0, address(weth), _borrowAmount);
    borrowFacet.borrow(subAccount0, address(usdc), _borrowAmount);
    vm.stopPrank();

    // time past
    vm.warp(block.timestamp + 10);

    vm.startPrank(ALICE);
    // transfer collateral will trigger accrue interest on all borrowed token
    collateralFacet.transferCollateral(0, 1, address(weth), 0);
    vm.stopPrank();

    // assert ALICE
    (, uint256 _aliceActualWethDebtAmount) = borrowFacet.getDebt(ALICE, subAccount0, address(weth));
    (, uint256 _aliceActualUSDCDebtAmount) = borrowFacet.getDebt(ALICE, subAccount0, address(usdc));

    assertGt(_aliceActualWethDebtAmount, _borrowAmount);
    assertGt(_aliceActualUSDCDebtAmount, _borrowAmount);

    //assert Global
    assertGt(borrowFacet.debtValues(address(weth)), _borrowAmount);
    assertGt(borrowFacet.debtValues(address(usdc)), _borrowAmount);
  }
}