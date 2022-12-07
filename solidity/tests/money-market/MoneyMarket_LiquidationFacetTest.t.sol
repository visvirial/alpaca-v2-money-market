// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { MoneyMarket_BaseTest, MockERC20, console } from "./MoneyMarket_BaseTest.t.sol";

// libs
import { LibMoneyMarket01 } from "../../contracts/money-market/libraries/LibMoneyMarket01.sol";

// interfaces
import { IBorrowFacet, LibDoublyLinkedList } from "../../contracts/money-market/facets/BorrowFacet.sol";
import { ILiquidationFacet } from "../../contracts/money-market/facets/LiquidationFacet.sol";
import { IAdminFacet } from "../../contracts/money-market/facets/AdminFacet.sol";
import { TripleSlopeModel6, IInterestRateModel } from "../../contracts/money-market/interest-models/TripleSlopeModel6.sol";

// mocks
import { MockLPToken } from "../mocks/MockLPToken.sol";
import { MockRouter } from "../mocks/MockRouter.sol";
import { MockLiquidationStrategy } from "../mocks/MockLiquidationStrategy.sol";
import { MockBadLiquidationStrategy } from "../mocks/MockBadLiquidationStrategy.sol";

struct CacheState {
  uint256 collat;
  uint256 subAccountCollat;
  uint256 debtShare;
  uint256 debtValue;
  uint256 subAccountDebtShare;
}

contract MoneyMarket_LiquidationFacetTest is MoneyMarket_BaseTest {
  using LibDoublyLinkedList for LibDoublyLinkedList.List;
  uint256 _subAccountId = 0;
  address _aliceSubAccount0 = LibMoneyMarket01.getSubAccount(ALICE, _subAccountId);
  MockLiquidationStrategy internal mockLiquidationStrategy;
  MockBadLiquidationStrategy internal mockBadLiquidationStrategy;
  address treasury;

  function setUp() public override {
    super.setUp();

    TripleSlopeModel6 tripleSlope6 = new TripleSlopeModel6();
    adminFacet.setInterestModel(address(weth), address(tripleSlope6));
    adminFacet.setInterestModel(address(btc), address(tripleSlope6));
    adminFacet.setInterestModel(address(usdc), address(tripleSlope6));

    // setup liquidationStrategy
    mockLiquidationStrategy = new MockLiquidationStrategy(address(chainLinkOracle));
    usdc.mint(address(mockLiquidationStrategy), 1000 ether);
    mockBadLiquidationStrategy = new MockBadLiquidationStrategy();
    usdc.mint(address(mockBadLiquidationStrategy), 1000 ether);

    address[] memory _liquidationStrats = new address[](2);
    _liquidationStrats[0] = address(mockLiquidationStrategy);
    _liquidationStrats[1] = address(mockBadLiquidationStrategy);
    adminFacet.setLiquidationStratsOk(_liquidationStrats, true);

    address[] memory _liquidationCallers = new address[](2);
    _liquidationCallers[0] = BOB;
    _liquidationCallers[1] = address(this);
    adminFacet.setLiquidationCallersOk(_liquidationCallers, true);

    vm.startPrank(DEPLOYER);
    chainLinkOracle.add(address(btc), address(usd), 10 ether, block.timestamp);
    vm.stopPrank();

    // bob deposit 100 usdc and 10 btc
    vm.startPrank(BOB);
    lendFacet.deposit(address(usdc), 100 ether);
    lendFacet.deposit(address(btc), 10 ether);
    vm.stopPrank();

    vm.startPrank(ALICE);
    collateralFacet.addCollateral(ALICE, 0, address(weth), 40 ether);
    // alice added collat 40 ether
    // given collateralFactor = 9000, weth price = 1
    // then alice got power = 40 * 1 * 9000 / 10000 = 36 ether USD
    // alice borrowed 30% of vault then interest should be 0.0617647058676 per year
    // interest per day = 0.00016921837224
    borrowFacet.borrow(0, address(usdc), 30 ether);
    vm.stopPrank();

    treasury = address(this);
  }

  // Repurchase tests

  function testCorrectness_ShouldRepurchasePassed_TransferTokenCorrectly() external {
    // criteria
    address _debtToken = address(usdc);
    address _collatToken = address(weth);

    uint256 _bobUsdcBalanceBefore = usdc.balanceOf(BOB);
    uint256 _bobWethBalanceBefore = weth.balanceOf(BOB);

    // collat amount should be = 40
    // collat debt value should be = 30
    // collat debt share should be = 30
    CacheState memory _stateBefore = CacheState({
      collat: collateralFacet.collats(_collatToken),
      subAccountCollat: collateralFacet.subAccountCollatAmount(_aliceSubAccount0, _collatToken),
      debtShare: borrowFacet.debtShares(_debtToken),
      debtValue: borrowFacet.debtValues(_debtToken),
      subAccountDebtShare: 0
    });
    (_stateBefore.subAccountDebtShare, ) = borrowFacet.getDebt(ALICE, 0, _debtToken);

    // add time 1 day
    // then total debt value should increase by 0.00016921837224 * 30 = 0.0050765511672
    vm.warp(1 days + 1);

    // set price to weth from 1 to 0.8 ether USD
    // then alice borrowing power = 40 * 0.8 * 9000 / 10000 = 28.8 ether USD
    vm.prank(DEPLOYER);
    chainLinkOracle.add(address(weth), address(usd), 8e17, block.timestamp);
    chainLinkOracle.add(address(usdc), address(usd), 1 ether, block.timestamp);
    chainLinkOracle.add(address(btc), address(usd), 10 ether, block.timestamp);
    vm.stopPrank();

    // bob try repurchase with 15 usdc
    // eth price = 0.8 USD
    // usdc price = 1 USD
    // reward = 1%
    // timestamp increased by 1 day, debt value should increased to 30.0050765511672
    vm.prank(BOB);
    liquidationFacet.repurchase(ALICE, _subAccountId, _debtToken, _collatToken, 15 ether);

    // repay value = 15 * 1 = 1 USD
    // reward amount = 15 * 1.01 = 15.15 USD
    // converted weth amount = 15.15 / 0.8 = 18.9375

    uint256 _bobUsdcBalanceAfter = usdc.balanceOf(BOB);
    uint256 _bobWethBalanceAfter = weth.balanceOf(BOB);

    // check bob balance
    assertEq(_bobUsdcBalanceBefore - _bobUsdcBalanceAfter, 15 ether); // pay 15 usdc
    assertEq(_bobWethBalanceAfter - _bobWethBalanceBefore, 18.9375 ether); // get 18.9375 weth

    CacheState memory _stateAfter = CacheState({
      collat: collateralFacet.collats(_collatToken),
      subAccountCollat: collateralFacet.subAccountCollatAmount(_aliceSubAccount0, _collatToken),
      debtShare: borrowFacet.debtShares(_debtToken),
      debtValue: borrowFacet.debtValues(_debtToken),
      subAccountDebtShare: 0
    });
    (_stateAfter.subAccountDebtShare, ) = borrowFacet.getDebt(ALICE, 0, _debtToken);

    // check state
    // note: before repurchase state should be like these
    // collat amount should be = 40
    // collat debt value should be = 30.0050765511672 (0.0050765511672 is fixed interest increased)
    // collat debt share should be = 30
    // then after repurchase
    // collat amount should be = 40 - (_collatAmountOut) = 40 - 18.9375 = 21.0625
    // collat debt value should be = 30.0050765511672 - (_repayAmount) = 30.0050765511672 - 15 = 15.0050765511672
    // _repayShare = _repayAmount * totalDebtShare / totalDebtValue = 15 * 30 / 30.0050765511672 = 14.997462153866591690
    // collat debt share should be = 30 - (_repayShare) = 30 - 14.997462153866591690 = 15.00253784613340831
    assertEq(_stateAfter.collat, 21.0625 ether);
    assertEq(_stateAfter.subAccountCollat, 21.0625 ether);
    assertEq(_stateAfter.debtValue, 15.0050765511672 ether);
    assertEq(_stateAfter.debtShare, 15.00253784613340831 ether);
    assertEq(_stateAfter.subAccountDebtShare, 15.00253784613340831 ether);
    vm.stopPrank();
  }

  function testCorrectness_ShouldRepurchasePassedWithMoreThan50PercentOfDebtToken_TransferTokenCorrectly() external {
    // alice add more collateral
    vm.startPrank(ALICE);
    collateralFacet.addCollateral(ALICE, 0, address(weth), 40 ether);
    // alice borrow more btc token as 30% of vault = 3 btc
    borrowFacet.borrow(0, address(btc), 3 ether);
    vm.stopPrank();

    // criteria
    address _debtToken = address(usdc);
    address _collatToken = address(weth);

    uint256 _bobUsdcBalanceBefore = usdc.balanceOf(BOB);
    uint256 _bobWethBalanceBefore = weth.balanceOf(BOB);

    // collat amount should be = 80 on weth
    // collat debt value should be | usdc: 30 | btc: 3 |
    // collat debt share should be | usdc: 30 | btc: 3 |
    CacheState memory _stateBefore = CacheState({
      collat: collateralFacet.collats(_collatToken),
      subAccountCollat: collateralFacet.subAccountCollatAmount(_aliceSubAccount0, _collatToken),
      debtShare: borrowFacet.debtShares(_debtToken),
      debtValue: borrowFacet.debtValues(_debtToken),
      subAccountDebtShare: 0
    });
    (_stateBefore.subAccountDebtShare, ) = borrowFacet.getDebt(ALICE, 0, _debtToken);

    // add time 1 day
    // 0.00016921837224 is interest rate per day of (30% condition slope)
    // then total debt value of usdc should increase by 0.00016921837224 * 30 = 0.0050765511672
    // then total debt value of btc should increase by 0.00016921837224 * 3 = 0.00050765511672
    vm.warp(1 days + 1);

    // set price to weth from 1 to 0.8 ether USD
    // then alice borrowing power = 40 * 0.8 * 9000 / 10000 = 28.8 ether USD
    vm.prank(DEPLOYER);
    chainLinkOracle.add(address(weth), address(usd), 8e17, block.timestamp);
    chainLinkOracle.add(address(usdc), address(usd), 1 ether, block.timestamp);
    chainLinkOracle.add(address(btc), address(usd), 10 ether, block.timestamp);
    vm.stopPrank();

    // bob try repurchase with 20 usdc
    // eth price = 0.8 USD
    // usdc price = 1 USD
    // reward = 1%
    // timestamp increased by 1 day, usdc debt value should increased to 30.0050765511672
    // timestamp increased by 1 day, btc value should increased to 3.00050765511672
    vm.prank(BOB);
    liquidationFacet.repurchase(ALICE, _subAccountId, _debtToken, _collatToken, 20 ether);

    // repay value = 20 * 1 = 1 USD
    // reward amount = 20 * 1.01 = 20.20 USD
    // converted weth amount = 20.20 / 0.8 = 25.25

    uint256 _bobUsdcBalanceAfter = usdc.balanceOf(BOB);
    uint256 _bobWethBalanceAfter = weth.balanceOf(BOB);

    // check bob balance
    assertEq(_bobUsdcBalanceBefore - _bobUsdcBalanceAfter, 20 ether); // pay 20 usdc
    assertEq(_bobWethBalanceAfter - _bobWethBalanceBefore, 25.25 ether); // get 25.25 weth

    CacheState memory _stateAfter = CacheState({
      collat: collateralFacet.collats(_collatToken),
      subAccountCollat: collateralFacet.subAccountCollatAmount(_aliceSubAccount0, _collatToken),
      debtShare: borrowFacet.debtShares(_debtToken),
      debtValue: borrowFacet.debtValues(_debtToken),
      subAccountDebtShare: 0
    });
    (_stateAfter.subAccountDebtShare, ) = borrowFacet.getDebt(ALICE, 0, _debtToken);

    // check state
    // note: before repurchase state should be like these
    // collat amount should be = 80 on weth
    // collat debt value should be | usdc: 30.0050765511672 | btc: 3.00050765511672 | after accure interest
    // collat debt share should be | usdc: 30 | btc: 3 |
    // then after repurchase
    // collat amount should be = 80 - (_collatAmountOut) = 80 - 25.25 = 54.75
    // collat debt value should be = 30.0050765511672 - (_repayAmount) = 30.0050765511672 - 20 = 10.0050765511672
    // _repayShare = _repayAmount * totalDebtShare / totalDebtValue = 20 * 30 / 30.0050765511672 = 19.996616205155455587
    // collat debt share should be = 30 - (_repayShare) = 30 - 19.996616205155455587 = 10.003383794844544413
    assertEq(_stateAfter.collat, 54.75 ether);
    assertEq(_stateAfter.subAccountCollat, 54.75 ether);
    assertEq(_stateAfter.debtValue, 10.0050765511672 ether);
    assertEq(_stateAfter.debtShare, 10.003383794844544413 ether);
    assertEq(_stateAfter.subAccountDebtShare, 10.003383794844544413 ether);

    // check state for btc should not be changed
    CacheState memory _btcState = CacheState({
      collat: collateralFacet.collats(address(btc)),
      subAccountCollat: collateralFacet.subAccountCollatAmount(_aliceSubAccount0, address(btc)),
      debtShare: borrowFacet.debtShares(address(btc)),
      debtValue: borrowFacet.debtValues(address(btc)),
      subAccountDebtShare: 0
    });
    (_stateAfter.subAccountDebtShare, ) = borrowFacet.getDebt(ALICE, 0, address(btc));
    assertEq(_btcState.collat, 0 ether);
    assertEq(_btcState.subAccountCollat, 0 ether);
    assertEq(_btcState.debtValue, 3.00050765511672 ether);
    assertEq(_btcState.debtShare, 3 ether);
  }

  function testCorrectness_ShouldRepurchasePassedWithMoreThanDebtTokenAmount_TransferTokenCorrectly() external {
    // alice add more collateral
    vm.startPrank(ALICE);
    collateralFacet.addCollateral(ALICE, 0, address(weth), 60 ether);
    // alice borrow more btc token as 50% of vault = 5 btc
    borrowFacet.borrow(0, address(btc), 5 ether);
    vm.stopPrank();

    // criteria
    address _debtToken = address(usdc);
    address _collatToken = address(weth);

    uint256 _bobUsdcBalanceBefore = usdc.balanceOf(BOB);
    uint256 _bobWethBalanceBefore = weth.balanceOf(BOB);

    // collat amount should be = 100 on weth
    // collat debt value should be | usdc: 30 | btc: 5 |
    // collat debt share should be | usdc: 30 | btc: 5 |
    CacheState memory _stateBefore = CacheState({
      collat: collateralFacet.collats(_collatToken),
      subAccountCollat: collateralFacet.subAccountCollatAmount(_aliceSubAccount0, _collatToken),
      debtShare: borrowFacet.debtShares(_debtToken),
      debtValue: borrowFacet.debtValues(_debtToken),
      subAccountDebtShare: 0
    });
    (_stateBefore.subAccountDebtShare, ) = borrowFacet.getDebt(ALICE, 0, _debtToken);

    // set price to weth from 1 to 0.8 ether USD
    // then alice borrowing power = 80 * 0.8 * 9000 / 10000 = 57.6 ether USD
    vm.prank(DEPLOYER);
    chainLinkOracle.add(address(weth), address(usd), 8e17, block.timestamp);

    // add time 1 day
    // 0.00016921837224 is interest rate per day of (30% condition slope)
    // 0.0002820306204288 is interest rate per day of (50% condition slope)
    // then total debt value of usdc should increase by 0.00016921837224 * 30 = 0.0050765511672
    // then total debt value of btc should increase by 0.0002820306204288 * 5 = 0.001410153102144
    vm.warp(1 days + 1);

    // set price to weth from 1 to 0.8 ether USD
    // then alice borrowing power = 40 * 0.8 * 9000 / 10000 = 28.8 ether USD
    vm.prank(DEPLOYER);
    chainLinkOracle.add(address(weth), address(usd), 8e17, block.timestamp);
    chainLinkOracle.add(address(usdc), address(usd), 1 ether, block.timestamp);
    chainLinkOracle.add(address(btc), address(usd), 10 ether, block.timestamp);
    vm.stopPrank();

    // bob try repurchase with 40 usdc
    // eth price = 0.8 USD
    // usdc price = 1 USD
    // reward = 0.01%
    // timestamp increased by 1 day, usdc debt value should increased to 30.0050765511672
    // timestamp increased by 1 day, btc value should increased to 5.001410153102144
    vm.prank(BOB);
    liquidationFacet.repurchase(ALICE, _subAccountId, _debtToken, _collatToken, 40 ether);

    // alice just have usdc debt 30.0050765511672 (with interest)
    // repay value = 30.0050765511672 * 1 = 1 USD
    // reward amount = 30.0050765511672 * 1.01 = 30.305127316678872 USD
    // converted weth amount = 30.305127316678872 / 0.8 = 37.88140914584859

    uint256 _bobUsdcBalanceAfter = usdc.balanceOf(BOB);
    uint256 _bobWethBalanceAfter = weth.balanceOf(BOB);

    // check bob balance
    assertEq(_bobUsdcBalanceBefore - _bobUsdcBalanceAfter, 30.0050765511672 ether); // pay 30.0050765511672 usdc
    assertEq(_bobWethBalanceAfter - _bobWethBalanceBefore, 37.88140914584859 ether); // get 37.88140914584859 weth

    CacheState memory _stateAfter = CacheState({
      collat: collateralFacet.collats(_collatToken),
      subAccountCollat: collateralFacet.subAccountCollatAmount(_aliceSubAccount0, _collatToken),
      debtShare: borrowFacet.debtShares(_debtToken),
      debtValue: borrowFacet.debtValues(_debtToken),
      subAccountDebtShare: 0
    });
    (_stateAfter.subAccountDebtShare, ) = borrowFacet.getDebt(ALICE, 0, _debtToken);

    // check state
    // note: before repurchase state should be like these
    // collat amount should be = 100 on weth
    // collat debt value should be | usdc: 30.0050765511672 | btc: 5.001410153102144 | after accure interest
    // collat debt share should be | usdc: 30 | btc: 5 |
    // then after repurchase
    // collat amount should be = 100 - (_collatAmountOut) = 100 - 37.88140914584859 = 62.11859085415141
    // collat debt value should be = 30.0050765511672 - (_repayAmount) = 30.0050765511672 - 30.305127316678872 = 0
    // _repayShare = _repayAmount * totalDebtShare / totalDebtValue = 30.305127316678872 * 30 / 30.305127316678872 = 30
    // collat debt share should be = 30 - (_repayShare) = 30 - 30 = 0
    assertEq(_stateAfter.collat, 62.11859085415141 ether);
    assertEq(_stateAfter.subAccountCollat, 62.11859085415141 ether);
    assertEq(_stateAfter.debtValue, 0 ether);
    assertEq(_stateAfter.debtShare, 0 ether);
    assertEq(_stateAfter.subAccountDebtShare, 0 ether);

    // check state for btc should not be changed
    CacheState memory _btcState = CacheState({
      collat: collateralFacet.collats(address(btc)),
      subAccountCollat: collateralFacet.subAccountCollatAmount(_aliceSubAccount0, address(btc)),
      debtShare: borrowFacet.debtShares(address(btc)),
      debtValue: borrowFacet.debtValues(address(btc)),
      subAccountDebtShare: 0
    });
    (_stateAfter.subAccountDebtShare, ) = borrowFacet.getDebt(ALICE, 0, address(btc));
    assertEq(_btcState.collat, 0 ether);
    assertEq(_btcState.subAccountCollat, 0 ether);
    assertEq(_btcState.debtValue, 5.001410153102144 ether);
    assertEq(_btcState.debtShare, 5 ether);
  }

  function testRevert_ShouldRevertIfSubAccountIsHealthy() external {
    // criteria
    address _debtToken = address(usdc);
    address _collatToken = address(weth);

    vm.startPrank(BOB);
    vm.expectRevert(abi.encodeWithSelector(ILiquidationFacet.LiquidationFacet_Healthy.selector));
    // bob try repurchase with 2 usdc
    liquidationFacet.repurchase(ALICE, _subAccountId, _debtToken, _collatToken, 2 ether);
    vm.stopPrank();
  }

  function testRevert_ShouldRevertRepurchaserIsNotOK() external {
    // criteria
    address _debtToken = address(usdc);
    address _collatToken = address(weth);

    vm.startPrank(CAT);
    vm.expectRevert(abi.encodeWithSelector(ILiquidationFacet.LiquidationFacet_Unauthorized.selector));
    // bob try repurchase with 2 usdc
    liquidationFacet.repurchase(ALICE, _subAccountId, _debtToken, _collatToken, 2 ether);
    vm.stopPrank();
  }

  function testRevert_shouldRevertIfRepayIsTooHigh() external {
    // criteria
    address _debtToken = address(usdc);
    address _collatToken = address(weth);

    // collat amount should be = 40
    // collat debt value should be = 30
    // collat debt share should be = 30
    CacheState memory _stateBefore = CacheState({
      collat: collateralFacet.collats(_collatToken),
      subAccountCollat: collateralFacet.subAccountCollatAmount(_aliceSubAccount0, _collatToken),
      debtShare: borrowFacet.debtShares(_debtToken),
      debtValue: borrowFacet.debtValues(_debtToken),
      subAccountDebtShare: 0
    });
    (_stateBefore.subAccountDebtShare, ) = borrowFacet.getDebt(ALICE, 0, _debtToken);

    // add time 1 day
    // then total debt value should increase by 0.00016921837224 * 30 = 0.0050765511672
    vm.warp(1 days + 1);

    // set price to weth from 1 to 0.8 ether USD
    // then alice borrowing power = 40 * 0.8 * 9000 / 10000 = 28.8 ether USD
    vm.prank(DEPLOYER);
    chainLinkOracle.add(address(weth), address(usd), 8e17, block.timestamp);
    chainLinkOracle.add(address(usdc), address(usd), 1 ether, block.timestamp);
    chainLinkOracle.add(address(btc), address(usd), 10 ether, block.timestamp);
    vm.stopPrank();

    // bob try repurchase with 2 usdc
    // eth price = 0.8 USD
    // usdc price = 1 USD
    // reward = 0.01%
    // timestamp increased by 1 day, debt value should increased to 30.0050765511672
    vm.startPrank(BOB);
    vm.expectRevert(abi.encodeWithSelector(ILiquidationFacet.LiquidationFacet_RepayDebtValueTooHigh.selector));
    // bob try repurchase with 20 usdc but borrowed value is 30.0050765511672 / 2 = 15.0025382755836,
    // so bob can't pay more than 15.0025382755836 followed by condition (!> 50% of borrowed value)
    liquidationFacet.repurchase(ALICE, _subAccountId, _debtToken, _collatToken, 20 ether);
    vm.stopPrank();
  }

  function testRevert_ShouldRevertIfInsufficientCollateralAmount() external {
    vm.startPrank(ALICE);
    // alice has 36 ether USD power from eth
    // alice add more collateral in other assets
    // then borrowing power will be increased by 100 * 10 * 9000 / 10000 = 900 ether USD
    // total borrowing power is 936 ether USD
    collateralFacet.addCollateral(ALICE, 0, address(btc), 100 ether);
    // alice borrow more usdc token more 50% of vault = 50 usdc
    // alice used borrowed value is ~80
    borrowFacet.borrow(0, address(usdc), 50 ether);
    vm.stopPrank();

    // criteria
    address _debtToken = address(usdc);
    address _collatToken = address(weth);

    // add time 1 day
    // 0.0004512489926688 is interest rate per day of (80% condition slope)
    // then total debt value of usdc should increase by 0.0004512489926688 * 80 = 0.036099919413504
    vm.warp(1 days + 1);

    // set price to btc from 10 to 0.1 ether USD
    // then alice borrowing power from btc = 100 * 0.1 * 9000 / 10000 = 9 ether USD
    // total borrowing power is 36 + 9 = 45 ether USD
    vm.prank(DEPLOYER);
    chainLinkOracle.add(address(btc), address(usd), 1e17, block.timestamp);
    chainLinkOracle.add(address(weth), address(usd), 1 ether, block.timestamp);
    chainLinkOracle.add(address(usdc), address(usd), 1 ether, block.timestamp);
    vm.stopPrank();

    // bob try repurchase with 40 usdc
    // eth price = 0.2 USD
    // usdc price = 1 USD
    // reward = 0.01%
    // timestamp increased by 1 day, usdc debt value should increased to 80.036099919413504
    vm.startPrank(BOB);

    // repay value = 40 * 1 = 40 USD
    // reward amount = 40 * 1.01 = 40.40 USD
    // converted weth amount = 40.40 / 1 = 40.40
    // should revert because alice has eth collat just 40
    vm.expectRevert(abi.encodeWithSelector(ILiquidationFacet.LiquidationFacet_InsufficientAmount.selector));
    liquidationFacet.repurchase(ALICE, _subAccountId, _debtToken, _collatToken, 40 ether);
    vm.stopPrank();
  }

  // Liquidation tests

  function testCorrectness_WhenPartialLiquidate_ShouldWork() external {
    /**
     * scenario:
     *
     * 1. 1 usdc/weth, ALICE post 40 weth as collateral, borrow 30 usdc
     *    - ALICE borrowing power = 40 * 1 * 9000 / 10000 = 36 usd
     *
     * 2. 1 day passesd, debt accrued, weth price drops to 0.8 usdc/weth, position become liquidatable
     *    - usdc debt has increased to 30.0050765511672 usdc
     *    - ALICE borrowing power = 40 * 0.8 * 9000 / 10000 = 28.8 usd
     *
     * 3. try to liquidate 15 usdc with weth collateral
     *
     * 4. should be able to liquidate with 15 usdc repaid and 18.9375 weth reduced from collateral
     *    - remaining collateral = 40 - 18.9375 = 21.0625 weth
     *      - 15 usdc = 18.75 weth is liquidated
     *      - 18.75 * 1% = 0.1875 weth is taken to treasury as liquidation fee
     *    - remaining debt value = 30.0050765511672 - 15 = 15.0050765511672 usdc
     *    - remaining debt share = 30 - 14.997462153866591690 = 15.00253784613340831 shares
     *      - repaid debt shares = amountRepaid * totalDebtShare / totalDebtValue = 15 * 30 / 30.0050765511672 = 14.997462153866591690
     */

    address _debtToken = address(usdc);
    address _collatToken = address(weth);

    vm.warp(1 days + 1);

    // LiquidationFacet need these to function
    chainLinkOracle.add(address(weth), address(usd), 8e17, block.timestamp);
    chainLinkOracle.add(address(usdc), address(usd), 1 ether, block.timestamp);
    // MockLiquidationStrategy need these to function
    chainLinkOracle.add(address(weth), address(usdc), 8e17, block.timestamp);

    uint256 _treasuryFeeBefore = MockERC20(_debtToken).balanceOf(treasury);

    liquidationFacet.liquidationCall(
      address(mockLiquidationStrategy),
      ALICE,
      _subAccountId,
      _debtToken,
      _collatToken,
      15 ether
    );

    CacheState memory _stateAfter = CacheState({
      collat: collateralFacet.collats(_collatToken),
      subAccountCollat: collateralFacet.subAccountCollatAmount(_aliceSubAccount0, _collatToken),
      debtShare: borrowFacet.debtShares(_debtToken),
      debtValue: borrowFacet.debtValues(_debtToken),
      subAccountDebtShare: 0
    });
    (_stateAfter.subAccountDebtShare, ) = borrowFacet.getDebt(ALICE, 0, _debtToken);

    assertEq(_stateAfter.collat, 21.0625 ether);
    assertEq(_stateAfter.subAccountCollat, 21.0625 ether);
    assertEq(_stateAfter.debtValue, 15.0050765511672 ether);
    assertEq(_stateAfter.debtShare, 15.00253784613340831 ether);
    assertEq(_stateAfter.subAccountDebtShare, 15.00253784613340831 ether);

    assertEq(MockERC20(_debtToken).balanceOf(treasury) - _treasuryFeeBefore, 0.15 ether);
  }

  function testCorrectness_WhenLiquidateMoreThanDebt_ShouldLiquidateAllDebtOnThatToken() external {
    /**
     * scenario:
     *
     * 1. 1 usdc/weth, ALICE post 40 weth as collateral, borrow 30 usdc
     *    - ALICE borrowing power = 40 * 1 * 9000 / 10000 = 36 usd
     *
     * 2. 1 day passesd, debt accrued, weth price drops to 0.8 usdc/weth, position become liquidatable
     *    - usdc debt has increased to 30.0050765511672 usdc
     *    - ALICE borrowing power = 40 * 0.8 * 9000 / 10000 = 28.8 usd
     *
     * 3. try to liquidate 40 usdc with weth collateral
     *
     * 4. should be able to liquidate with 30.0050765511672 usdc repaid, 37.88140914584859 weth reduced from collateral and 0.300050765511672 usdc to treasury
     *    - remaining collateral = 40 - 37.88140914584859 = 2.11859085415141 weth
     *      - @0.8 usdc/weth 30.0050765511672 usdc = 37.506345688959 weth is liquidated
     *      - 30.0050765511672 * 1% = 0.300050765511672 usdc is taken to treasury as liquidation fee
     *      - total weth liquidated = 37.506345688959 + 0.300050765511672 = 37.88140914584859
     *    - remaining debt value = 0
     *    - remaining debt share = 0
     */

    address _debtToken = address(usdc);
    address _collatToken = address(weth);
    uint256 _repayAmount = 40 ether;

    vm.warp(1 days + 1);

    // LiquidationFacet need these to function
    chainLinkOracle.add(address(weth), address(usd), 8e17, block.timestamp);
    chainLinkOracle.add(address(usdc), address(usd), 1 ether, block.timestamp);
    // MockLiquidationStrategy need these to function
    chainLinkOracle.add(address(weth), address(usdc), 8e17, block.timestamp);

    uint256 _treasuryFeeBefore = MockERC20(_debtToken).balanceOf(treasury);

    liquidationFacet.liquidationCall(
      address(mockLiquidationStrategy),
      ALICE,
      _subAccountId,
      _debtToken,
      _collatToken,
      _repayAmount
    );

    CacheState memory _stateAfter = CacheState({
      collat: collateralFacet.collats(_collatToken),
      subAccountCollat: collateralFacet.subAccountCollatAmount(_aliceSubAccount0, _collatToken),
      debtShare: borrowFacet.debtShares(_debtToken),
      debtValue: borrowFacet.debtValues(_debtToken),
      subAccountDebtShare: 0
    });
    (_stateAfter.subAccountDebtShare, ) = borrowFacet.getDebt(ALICE, 0, _debtToken);

    assertEq(_stateAfter.collat, 2.11859085415141 ether); // 40 - 37.88140914584859 = 2.11859085415141 weth remaining
    assertEq(_stateAfter.subAccountCollat, 2.11859085415141 ether); // same as collat
    // entire positon got liquidated, everything = 0
    assertEq(_stateAfter.debtValue, 0);
    assertEq(_stateAfter.debtShare, 0);
    assertEq(_stateAfter.subAccountDebtShare, 0);

    assertEq(MockERC20(_debtToken).balanceOf(treasury) - _treasuryFeeBefore, 0.300050765511672 ether);
  }

  function testCorrectness_WhenLiquidateAllCollateral_ShouldWorkButTreasuryReceiveNoFee() external {
    /**
     * scenario:
     *
     * 1. 1 usdc/weth, 10 usdc/btc, ALICE post 40 weth and 100 btc as collateral, borrow 80 usdc
     *    - borrowing power = 40 * 1 * 9000 / 10000 + 100 * 10 * 9000 / 10000 = 936 usd
     *
     * 2. 1 day passed, debt accrued, btc price drops to 0.1 usd/btc, position become liquidatable
     *    - usdc debt has increased to 80.036099919413504 usdc
     *      - 0.0004512489926688 is interest rate per day of (80% condition slope)
     *      - total debt value of usdc should increase by 0.0004512489926688 * 80 = 0.036099919413504
     *    - borrowing power = 40 * 1 * 9000 / 10000 + 100 * 0.1 * 9000 / 10000 = 45 usd
     *
     * 3. try to liquidate usdc debt with 40 weth
     *
     * 4. should be able to liquidate with 39.6 usdc repaid and 40 weth liquidated
     *    - remaining collateral = 0 weth
     *      - @1 usdc/weth 39.6 usdc = 39.6 weth is liquidated
     *      - 40 * 1% = 0.4 weth fee to treasury
     *    - remaining debt value = 80.036099919413504 - 39.6 = 40.436099919413504 usdc
     *    - remaining debt share = 80 - 39.981958181645606 ~= 40.41786140017084973 shares
     *      - repaid debt shares = amountRepaid * totalDebtShare / totalDebtValue = 39.6 * 80 / 80.036099919413504 = 39.582138599829150270272757155067956377008065689156955144328424412...
     */

    vm.startPrank(ALICE);
    collateralFacet.addCollateral(ALICE, 0, address(btc), 100 ether);
    borrowFacet.borrow(0, address(usdc), 50 ether);
    vm.stopPrank();

    address _debtToken = address(usdc);
    address _collatToken = address(weth);

    vm.warp(1 days + 1);

    chainLinkOracle.add(address(btc), address(usd), 1e17, block.timestamp);
    chainLinkOracle.add(address(weth), address(usd), 1 ether, block.timestamp);
    chainLinkOracle.add(address(weth), address(usdc), 1 ether, block.timestamp);
    chainLinkOracle.add(address(usdc), address(usd), 1 ether, block.timestamp);

    liquidationFacet.liquidationCall(
      address(mockLiquidationStrategy),
      ALICE,
      _subAccountId,
      _debtToken,
      _collatToken,
      40 ether
    );

    CacheState memory _stateAfter = CacheState({
      collat: collateralFacet.collats(_collatToken),
      subAccountCollat: collateralFacet.subAccountCollatAmount(_aliceSubAccount0, _collatToken),
      debtShare: borrowFacet.debtShares(_debtToken),
      debtValue: borrowFacet.debtValues(_debtToken),
      subAccountDebtShare: 0
    });
    (_stateAfter.subAccountDebtShare, ) = borrowFacet.getDebt(ALICE, 0, _debtToken);

    assertEq(_stateAfter.collat, 0);
    assertEq(_stateAfter.subAccountCollat, 0);
    assertEq(_stateAfter.debtValue, 40.436099919413504 ether);
    assertEq(_stateAfter.debtShare, 40.41786140017084973 ether);
    assertEq(_stateAfter.subAccountDebtShare, 40.41786140017084973 ether);

    assertEq(MockERC20(_debtToken).balanceOf(treasury), 0.4 ether);
  }

  function testCorrectness_WhenLiquidationStrategyReturnRepayTokenLessThanExpected_AndNoCollatIsReturned_ShouldCauseBadDebt()
    external
  {
    address _debtToken = address(usdc);
    address _collatToken = address(weth);

    vm.warp(1 days + 1);

    // LiquidationFacet need these to function
    chainLinkOracle.add(address(weth), address(usd), 8e17, block.timestamp);
    chainLinkOracle.add(address(usdc), address(usd), 1 ether, block.timestamp);
    // MockLiquidationStrategy need these to function
    chainLinkOracle.add(address(weth), address(usdc), 8e17, block.timestamp);

    uint256 _treasuryFeeBefore = MockERC20(_debtToken).balanceOf(treasury);

    liquidationFacet.liquidationCall(
      address(mockBadLiquidationStrategy), // this strategy return repayToken repayAmount - 1 and doesn't return collateral
      ALICE,
      _subAccountId,
      _debtToken,
      _collatToken,
      30 ether
    );

    CacheState memory _stateAfter = CacheState({
      collat: collateralFacet.collats(_collatToken),
      subAccountCollat: collateralFacet.subAccountCollatAmount(_aliceSubAccount0, _collatToken),
      debtShare: borrowFacet.debtShares(_debtToken),
      debtValue: borrowFacet.debtValues(_debtToken),
      subAccountDebtShare: 0
    });
    (_stateAfter.subAccountDebtShare, ) = borrowFacet.getDebt(ALICE, 0, _debtToken);

    // strategy doesn't return collat
    assertEq(_stateAfter.collat, 0);
    assertEq(_stateAfter.subAccountCollat, 0);
    // bad debt (0 collat with remaining debt)
    assertEq(_stateAfter.debtValue, 0.005076551167200001 ether); // 30.0050765511672 ether - (30 ether - 1 wei) because collat is enough to cover both debt and fee
    assertEq(_stateAfter.debtShare, 0.005075692266816620 ether); // wolfram: 30-(30-0.000000000000000001)*Divide[30,30.0050765511672]
    assertEq(_stateAfter.subAccountDebtShare, 0.005075692266816620 ether);

    assertEq(MockERC20(_debtToken).balanceOf(treasury) - _treasuryFeeBefore, 0.3 ether);
  }

  function testRevert_WhenLiquidateWhileSubAccountIsHealthy() external {
    vm.expectRevert(abi.encodeWithSelector(ILiquidationFacet.LiquidationFacet_Healthy.selector));
    liquidationFacet.liquidationCall(
      address(mockLiquidationStrategy),
      ALICE,
      _subAccountId,
      address(usdc),
      address(weth),
      1 ether
    );
  }

  function testRevert_WhenLiquidationStrategyIsNotOk() external {
    vm.expectRevert(abi.encodeWithSelector(ILiquidationFacet.LiquidationFacet_Unauthorized.selector));
    liquidationFacet.liquidationCall(address(0), ALICE, _subAccountId, address(usdc), address(weth), 1 ether);
  }

  function testRevert_WhenLiquidationCallerIsNotOk() external {
    vm.expectRevert(abi.encodeWithSelector(ILiquidationFacet.LiquidationFacet_Unauthorized.selector));
    vm.prank(EVE);
    liquidationFacet.liquidationCall(address(0), ALICE, _subAccountId, address(usdc), address(weth), 1 ether);
  }

  // ib liquidation tests

  function testCorrectness_WhenPartialLiquidateIbCollateral_ShouldRedeemUnderlyingToPayDebtCorrectly() external {
    // add ib as collat
    vm.startPrank(ALICE);
    lendFacet.deposit(address(weth), 40 ether);
    collateralFacet.addCollateral(ALICE, 0, address(ibWeth), 40 ether);
    collateralFacet.removeCollateral(_subAccountId, address(weth), 40 ether);
    vm.stopPrank();

    // criteria
    address _debtToken = address(usdc);
    address _collatToken = address(ibWeth);

    // add time 1 day
    // then total debt value should increase by 0.00016921837224 * 30 = 0.0050765511672
    vm.warp(1 days + 1);

    // increase shareValue of ibWeth by 2.5%
    // would need 18.2926829268... ibWeth to redeem 18.75 weth to repay debt
    weth.mint(address(moneyMarketDiamond), 1 ether);

    // mm state before
    uint256 _totalSupplyIbWethBefore = ibWeth.totalSupply();
    uint256 _totalWethInMMBefore = weth.balanceOf(address(moneyMarketDiamond));
    uint256 _treasuryFeeBefore = MockERC20(_debtToken).balanceOf(treasury);

    chainLinkOracle.add(address(weth), address(usd), 8e17, block.timestamp);
    chainLinkOracle.add(address(weth), address(usdc), 8e17, block.timestamp); // MockLiquidationStrategy need this to function
    chainLinkOracle.add(address(usdc), address(usd), 1 ether, block.timestamp);

    liquidationFacet.liquidationCall(
      address(mockLiquidationStrategy),
      ALICE,
      _subAccountId,
      _debtToken,
      _collatToken,
      15 ether
    );

    CacheState memory _stateAfter = CacheState({
      collat: collateralFacet.collats(_collatToken),
      subAccountCollat: collateralFacet.subAccountCollatAmount(_aliceSubAccount0, _collatToken),
      debtShare: borrowFacet.debtShares(_debtToken),
      debtValue: borrowFacet.debtValues(_debtToken),
      subAccountDebtShare: 0
    });
    (_stateAfter.subAccountDebtShare, ) = borrowFacet.getDebt(ALICE, 0, _debtToken);

    assertEq(_stateAfter.collat, 21.524390243902439025 ether); // 21.5243902439024 repeating
    assertEq(_stateAfter.subAccountCollat, 21.524390243902439025 ether); // 21.5243902439024 repeating
    assertEq(_stateAfter.debtValue, 15.0050765511672 ether); // same as other cases
    assertEq(_stateAfter.debtShare, 15.00253784613340831 ether);
    assertEq(_stateAfter.subAccountDebtShare, 15.00253784613340831 ether);

    // check mm state after
    assertEq(_totalSupplyIbWethBefore - ibWeth.totalSupply(), 18.475609756097560975 ether); // ibWeth repaid + liquidation fee
    assertEq(_totalWethInMMBefore - weth.balanceOf(address(moneyMarketDiamond)), 18.9375 ether); // weth repaid + liquidation fee

    assertEq(MockERC20(_debtToken).balanceOf(treasury) - _treasuryFeeBefore, 0.15 ether); // fee 0.15 usdc = 0.1875 weth
  }

  function testCorrectness_WhenLiquidateIbMoreThanDebt_ShouldLiquidateAllDebtOnThatToken() external {
    /**
     * scenario:
     *
     * 1. 1 usdc/weth, ALICE post 40 ibWeth (value 40 weth) as collateral, borrow 30 usdc
     *    - ALICE borrowing power = 40 * 1 * 9000 / 10000 = 36 usd
     *
     * 2. 1 day passesd, debt accrued, weth price drops to 0.8 usdc/weth, increase shareValue of ibWeth by 2.5%, position become liquidatable
     *    - usdc debt has increased to 30.0050765511672 usdc
     *    - now 1 ibWeth = 1.025 weth
     *    - ALICE borrowing power = 41 * 0.8 * 9000 / 10000 = 29.52 usd
     *
     * 3. try to liquidate 40 usdc with ibWeth collateral
     *    - entire 30.0050765511672 usdc position should be liquidated
     *
     * 4. should be able to liquidate with 30.0050765511672 usdc repaid and 36.957472337413258535 ibWeth reduced from collateral
     *    - remaining collateral = 41 - 36.957472337413258535 = 3.042527662586741465 ibWeth
     *      - 30.0050765511672 usdc = 37.506345688959 weth = 36.5915567697160975... ibWeth is liquidated
     *      - 30.0050765511672 * 1% = 0.300050765511672 usdc is taken to treasury as liquidation fee
     *    - remaining debt value = 0 usdc
     *    - remaining debt share = 0 shares
     */

    // add ib as collat
    vm.startPrank(ALICE);
    lendFacet.deposit(address(weth), 40 ether);
    collateralFacet.addCollateral(ALICE, 0, address(ibWeth), 40 ether);
    collateralFacet.removeCollateral(_subAccountId, address(weth), 40 ether);
    vm.stopPrank();

    address _debtToken = address(usdc);
    address _collatToken = address(ibWeth);
    uint256 _repayAmount = 40 ether;

    vm.warp(1 days + 1);

    // increase shareValue of ibWeth by 2.5%
    // would need 36.5915567697161341463414634... ibWeth to redeem 37.506345688959 weth to repay debt
    weth.mint(address(moneyMarketDiamond), 1 ether);

    // mm state before
    uint256 _totalSupplyIbWethBefore = ibWeth.totalSupply();
    uint256 _totalWethInMMBefore = weth.balanceOf(address(moneyMarketDiamond));
    uint256 _treasuryFeeBefore = MockERC20(_debtToken).balanceOf(treasury);

    // set price to weth from 1 to 0.8 ether USD
    // then alice borrowing power = 41 * 0.8 * 9000 / 10000 = 29.52 ether USD
    chainLinkOracle.add(address(weth), address(usd), 8e17, block.timestamp);
    chainLinkOracle.add(address(weth), address(usdc), 8e17, block.timestamp); // MockLiquidationStrategy need this to function
    chainLinkOracle.add(address(usdc), address(usd), 1 ether, block.timestamp);
    chainLinkOracle.add(address(btc), address(usd), 10 ether, block.timestamp);

    liquidationFacet.liquidationCall(
      address(mockLiquidationStrategy),
      ALICE,
      _subAccountId,
      _debtToken,
      _collatToken,
      _repayAmount
    );

    CacheState memory _stateAfter = CacheState({
      collat: collateralFacet.collats(_collatToken),
      subAccountCollat: collateralFacet.subAccountCollatAmount(_aliceSubAccount0, _collatToken),
      debtShare: borrowFacet.debtShares(_debtToken),
      debtValue: borrowFacet.debtValues(_debtToken),
      subAccountDebtShare: 0
    });
    (_stateAfter.subAccountDebtShare, ) = borrowFacet.getDebt(ALICE, 0, _debtToken);

    assertEq(_stateAfter.collat, 3.042527662586741464 ether); // 3.04252766258674146341... repeat 46341
    assertEq(_stateAfter.subAccountCollat, 3.042527662586741464 ether); // 3.04252766258674146341... repeat 46341
    assertEq(_stateAfter.debtValue, 0);
    assertEq(_stateAfter.debtShare, 0);
    assertEq(_stateAfter.subAccountDebtShare, 0);

    // check mm state after
    assertEq(_totalSupplyIbWethBefore - ibWeth.totalSupply(), 36.957472337413258536 ether); // ibWeth repaid + liquidation fee
    assertEq(_totalWethInMMBefore - weth.balanceOf(address(moneyMarketDiamond)), 37.88140914584859 ether); // weth repaid + liquidation fee

    assertEq(MockERC20(_debtToken).balanceOf(treasury) - _treasuryFeeBefore, 0.300050765511672 ether);
  }

  function testRevert_WhenLiquidateButMMDoesNotHaveEnoughUnderlyingForLiquidation() external {
    vm.startPrank(ALICE);
    lendFacet.deposit(address(weth), 40 ether);
    collateralFacet.addCollateral(ALICE, 0, address(ibWeth), 40 ether);
    collateralFacet.removeCollateral(_subAccountId, address(weth), 40 ether);
    vm.stopPrank();

    vm.warp(1 days + 1);

    chainLinkOracle.add(address(weth), address(usd), 1 ether, block.timestamp);
    chainLinkOracle.add(address(usdc), address(usd), 1 ether, block.timestamp);
    vm.startPrank(BOB);
    collateralFacet.addCollateral(BOB, 0, address(usdc), 100 ether);
    borrowFacet.borrow(0, address(weth), 30 ether);
    vm.stopPrank();

    weth.mint(address(moneyMarketDiamond), 1 ether);

    chainLinkOracle.add(address(weth), address(usd), 8e17, block.timestamp);
    chainLinkOracle.add(address(weth), address(usdc), 8e17, block.timestamp); // MockLiquidationStrategy need this to function

    // should fail because 11 weth left in mm not enough to liquidate 15 usdc debt
    // but it will fail during withdraw after executeLiquidation
    // because we will try to send all underlying of subAccount to liquidate anyway
    vm.expectRevert("ERC20: transfer amount exceeds balance");
    liquidationFacet.liquidationCall(
      address(mockLiquidationStrategy),
      ALICE,
      _subAccountId,
      address(usdc),
      address(ibWeth),
      15 ether
    );
  }

  function testRevert_WhenLiquidateIbWhileSubAccountIsHealthy() external {
    // add ib as collat
    vm.startPrank(ALICE);
    lendFacet.deposit(address(weth), 40 ether);
    collateralFacet.addCollateral(ALICE, 0, address(ibWeth), 40 ether);
    collateralFacet.removeCollateral(_subAccountId, address(weth), 40 ether);
    vm.stopPrank();

    // increase shareValue of ibWeth by 2.5%
    // wouldn need 18.475609756097... ibWeth to redeem 18.9375 weth to repay debt
    weth.mint(address(moneyMarketDiamond), 4 ether);

    // set price to weth from 1 to 0.8 ether USD
    // since ibWeth collat value increase, alice borrowing power = 44 * 0.8 * 9000 / 10000 = 31.68 ether USD
    chainLinkOracle.add(address(weth), address(usd), 8e17, block.timestamp);
    chainLinkOracle.add(address(weth), address(usdc), 8e17, block.timestamp); // MockLiquidationStrategy need this to function
    chainLinkOracle.add(address(usdc), address(usd), 1 ether, block.timestamp);
    chainLinkOracle.add(address(btc), address(usd), 10 ether, block.timestamp);

    vm.expectRevert(abi.encodeWithSelector(ILiquidationFacet.LiquidationFacet_Healthy.selector));
    liquidationFacet.liquidationCall(
      address(mockLiquidationStrategy),
      ALICE,
      _subAccountId,
      address(usdc),
      address(ibWeth),
      1 ether
    );
  }

  function testCorrectness_WhenRepurchaseDebtAndTakeIbTokenAsCollateral_ShouldWork() external {
    // criteria
    address _debtToken = address(usdc);
    address _collatToken = address(ibWeth);

    weth.mint(ALICE, 40 ether);
    vm.startPrank(ALICE);
    // withdraw weth and add ibWeth as collateral for simpler calculation
    lendFacet.deposit(address(weth), 40 ether);
    ibWeth.approve(moneyMarketDiamond, type(uint256).max);
    collateralFacet.addCollateral(ALICE, _subAccountId, address(ibWeth), 40 ether);
    collateralFacet.removeCollateral(_subAccountId, address(weth), 40 ether);
    vm.stopPrank();

    // now 1 ibWeth = 1 weth
    // make 1 ibWeth = 2 weth by inflating MM with 40 weth
    weth.mint(moneyMarketDiamond, 40 ether);

    // ALICE borrow another 30 USDC = 60 USDC in debt
    vm.prank(ALICE);
    borrowFacet.borrow(0, address(usdc), 30 ether);

    uint256 _bobUsdcBalanceBefore = usdc.balanceOf(BOB);
    uint256 _bobIbWethBalanceBefore = ibWeth.balanceOf(BOB);

    // collat amount should be = 40 ibWEth
    // collat debt value should be = 60
    // collat debt share should be = 60
    CacheState memory _stateBefore = CacheState({
      collat: collateralFacet.collats(_collatToken),
      subAccountCollat: collateralFacet.subAccountCollatAmount(_aliceSubAccount0, _collatToken),
      debtShare: borrowFacet.debtShares(_debtToken),
      debtValue: borrowFacet.debtValues(_debtToken),
      subAccountDebtShare: 0
    });
    (_stateBefore.subAccountDebtShare, ) = borrowFacet.getDebt(ALICE, 0, _debtToken);

    // add time 1 day
    // then total debt value should increase by 0.0033843674448 * 60 = 0.20306204668800000
    vm.warp(block.timestamp + 1 days);

    // set price to weth from 1 to 0.8 ether USD
    // 1 ibwETH = 2 weth, ibWeth prie = 1.6 USD
    // then alice borrowing power = 40 * 0.8 * 2 * 9000 / 10000 = 57.6 ether USD
    vm.prank(DEPLOYER);
    chainLinkOracle.add(address(weth), address(usd), 8e17, block.timestamp);
    chainLinkOracle.add(address(usdc), address(usd), 1 ether, block.timestamp);
    vm.stopPrank();

    // bob try repurchase with 15 usdc
    // eth price = 0.8 USD, ibWeth price = 1.6 USD
    // usdc price = 1 USD
    // reward = 1%
    // timestamp increased by 1 day, debt value should increased to 60.20306204668800000
    vm.prank(BOB);
    liquidationFacet.repurchase(ALICE, _subAccountId, _debtToken, _collatToken, 15 ether);

    // repay value = 15 * 1 = 1 USD
    // reward amount = 15 * 1.01 = 15.15 USD
    // converted weth amount = 15.15 / 1.6 = 9.46875

    uint256 _bobUsdcBalanceAfter = usdc.balanceOf(BOB);
    uint256 _bobIbWethBalanceAfter = ibWeth.balanceOf(BOB);

    // // check bob balance
    assertEq(_bobUsdcBalanceBefore - _bobUsdcBalanceAfter, 15 ether); // pay 15 usdc
    assertEq(_bobIbWethBalanceAfter - _bobIbWethBalanceBefore, 9.46875 ether); // get 9.46875 weth

    CacheState memory _stateAfter = CacheState({
      collat: collateralFacet.collats(_collatToken),
      subAccountCollat: collateralFacet.subAccountCollatAmount(_aliceSubAccount0, _collatToken),
      debtShare: borrowFacet.debtShares(_debtToken),
      debtValue: borrowFacet.debtValues(_debtToken),
      subAccountDebtShare: 0
    });
    (_stateAfter.subAccountDebtShare, ) = borrowFacet.getDebt(ALICE, 0, _debtToken);

    // check state
    // note: before repurchase state should be like these
    // collat amount should be = 40
    // collat debt value should be = 60.020306204668800000
    // collat debt share should be = 60
    // then after repurchase
    // collat amount should be = 40 - (_collatAmountOut) = 40 - 9.46875 = 30.53125
    // collat debt value should be = 60.020306204668800000 - (_repayAmount) = 60.020306204668800000 - 15 = 45.020306204668800000
    // _repayShare = _repayAmount * totalDebtShare / totalDebtValue = 15 * 60 / 60.020306204668800000 = 14.994925166342981658
    // collat debt share should be = 60 - (_repayShare) = 60 - 14.994925166342981658 = 45.005074833657018342
    assertEq(_stateAfter.collat, 30.53125 ether);
    assertEq(_stateAfter.subAccountCollat, 30.53125 ether);
    assertEq(_stateAfter.debtValue, 45.020306204668800000 ether);
    assertEq(_stateAfter.debtShare, 45.005074833657018342 ether);
    assertEq(_stateAfter.subAccountDebtShare, 45.005074833657018342 ether);
    vm.stopPrank();
  }
}