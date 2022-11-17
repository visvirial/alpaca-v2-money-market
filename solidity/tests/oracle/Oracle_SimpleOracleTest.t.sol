// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { BaseTest, console, MockERC20 } from "../base/BaseTest.sol";

import { SimplePriceOracle, IPriceOracle } from "../../contracts/oracle/SimplePriceOracle.sol";
import { IAggregatorV3 } from "../../contracts/oracle/interfaces/IAggregatorV3.sol";
import { MockChainLinkAggregator } from "../mocks/MockChainLinkAggregator.sol";

contract Oracle_SimpleOracleTest is BaseTest {
  address feeder;

  function setUp() public virtual {
    feeder = EVE;

    SimplePriceOracle simplePriceOracle = new SimplePriceOracle();
    simplePriceOracle.initialize(feeder);
    address oldOwner = simplePriceOracle.owner();
    vm.prank(oldOwner);
    simplePriceOracle.transferOwnership(DEPLOYER);

    oracle = IPriceOracle(simplePriceOracle);
  }

  function testCorrectness_NotOwner_setPrices_shouldRevertCallerIsNotOwner() external {
    address[] memory t0 = new address[](1);
    t0[0] = address(weth);

    address[] memory t1 = new address[](1);
    t1[0] = address(usd);

    uint256[] memory prices = new uint256[](1);
    prices[0] = 1500 ether;

    vm.expectRevert(abi.encodeWithSelector(SimplePriceOracle.SimplePriceOracle_UnAuthorized.selector, ALICE));
    vm.prank(ALICE);
    SimplePriceOracle(address(oracle)).setPrices(t0, t1, prices);
  }

  function testCorrectness_setPrices_shouldPass() external {
    address[] memory t0 = new address[](2);
    t0[0] = address(weth);
    t0[1] = address(usdc);

    address[] memory t1 = new address[](2);
    t1[0] = address(usdc);
    t1[1] = address(usd);

    uint256[] memory prices = new uint256[](2);
    prices[0] = 1500 ether;
    prices[1] = 1 ether;

    vm.prank(feeder);
    SimplePriceOracle(address(oracle)).setPrices(t0, t1, prices);

    (uint192 price, uint64 ts) = SimplePriceOracle(address(oracle)).store(address(weth), address(usdc));
    assertEq(price, 1500 ether);
    assertEq(ts, 1);
  }

  function testCorrectness_getPriceBeforeSet_shouldRevertBadPriceData() external {
    vm.expectRevert(
      abi.encodeWithSelector(SimplePriceOracle.SimplePriceOracle_BadPriceData.selector, address(weth), address(usdc))
    );
    SimplePriceOracle(address(oracle)).getPrice(address(weth), address(usdc));
  }

  function testCorrectness_getPrices_shouldPass() external {
    address[] memory t0 = new address[](2);
    t0[0] = address(weth);
    t0[1] = address(usdc);

    address[] memory t1 = new address[](2);
    t1[0] = address(usdc);
    t1[1] = address(usd);

    uint256[] memory prices = new uint256[](2);
    prices[0] = 1500 ether;
    prices[1] = 1 ether;

    vm.prank(feeder);
    SimplePriceOracle(address(oracle)).setPrices(t0, t1, prices);

    (uint256 price, uint256 ts) = oracle.getPrice(address(weth), address(usdc));
    assertEq(price, 1500 ether);
    assertEq(ts, 1);
  }
}