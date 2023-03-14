// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

import "../BaseScript.sol";

import { InterestBearingToken } from "solidity/contracts/money-market/InterestBearingToken.sol";
import { DebtToken } from "../../contracts/money-market/DebtToken.sol";
import { LibConstant } from "solidity/contracts/money-market/libraries/LibConstant.sol";
import { MockAlpacaV2Oracle } from "solidity/tests/mocks/MockAlpacaV2Oracle.sol";
import { FixedInterestRateModel } from "solidity/contracts/money-market/interest-models/FixedInterestRateModel.sol";
import { TripleSlopeModel6 } from "solidity/contracts/money-market/interest-models/TripleSlopeModel6.sol";
import { TripleSlopeModel7 } from "solidity/contracts/money-market/interest-models/TripleSlopeModel7.sol";

contract SetUpMMForTestScript is BaseScript {
  using stdJson for string;

  function run() public {
    _loadAddresses();

    _startDeployerBroadcast();

    // //---- setup mock token ----//
    // address mock6DecimalsToken = _setUpMockToken("MOCK6", 6);
    // _writeJson(vm.toString(mock6DecimalsToken), ".tokens.mock6DecimalsToken");

    // //---- setup mock oracle ----//
    // MockAlpacaV2Oracle mockOracle = new MockAlpacaV2Oracle();
    // mockOracle.setTokenPrice(wbnb, 300 ether);
    // mockOracle.setTokenPrice(busd, 1 ether);
    // mockOracle.setTokenPrice(dodo, 0.13 ether);
    // mockOracle.setTokenPrice(pstake, 0.12 ether);
    // mockOracle.setTokenPrice(mock6DecimalsToken, 666 ether);

    // moneyMarket.setOracle(address(mockOracle));

    //---- setup mm configs ----//
    moneyMarket.setMinDebtSize(0.1 ether);
    moneyMarket.setMaxNumOfToken(10, 10, 10);

    moneyMarket.setIbTokenImplementation(address(new InterestBearingToken()));
    moneyMarket.setDebtTokenImplementation(address(new DebtToken()));

    address irm1 = address(new FixedInterestRateModel(18));
    address irm2 = address(new TripleSlopeModel6());
    address irm3 = address(new TripleSlopeModel7());

    moneyMarket.setInterestModel(busd, irm1);
    moneyMarket.setInterestModel(wbnb, irm2);
    moneyMarket.setInterestModel(pstake, irm2);
    moneyMarket.setInterestModel(dodo, irm3);

    //---- open markets ----//
    // avoid stack too deep
    {
      IAdminFacet.TokenConfigInput memory tokenConfigInput = IAdminFacet.TokenConfigInput({
        tier: LibConstant.AssetTier.COLLATERAL,
        collateralFactor: 0,
        borrowingFactor: 9000,
        maxBorrow: 1_000_000 ether,
        maxCollateral: 0
      });
      IAdminFacet.TokenConfigInput memory ibTokenConfigInput = IAdminFacet.TokenConfigInput({
        tier: LibConstant.AssetTier.COLLATERAL,
        collateralFactor: 9000,
        borrowingFactor: 9000,
        maxBorrow: 0,
        maxCollateral: 1_000_000 ether
      });
      address ibBusd = moneyMarket.openMarket(busd, tokenConfigInput, ibTokenConfigInput);

      // // IbMock 6
      // tokenConfigInput.maxBorrow = 1_000_000 * 1e6;
      // ibTokenConfigInput.maxCollateral = 1_000_000 * 1e6;
      // address ibMock6 = moneyMarket.openMarket(mock6DecimalsToken, tokenConfigInput, ibTokenConfigInput);

      // DODO
      tokenConfigInput.tier = LibConstant.AssetTier.CROSS;
      tokenConfigInput.borrowingFactor = 8500;
      tokenConfigInput.maxBorrow = 1_000_000 ether;

      ibTokenConfigInput.tier = LibConstant.AssetTier.CROSS;
      ibTokenConfigInput.collateralFactor = 0;
      ibTokenConfigInput.maxCollateral = 0;
      address ibDodo = moneyMarket.openMarket(dodo, tokenConfigInput, ibTokenConfigInput);

      // PSTAKE
      tokenConfigInput.tier = LibConstant.AssetTier.ISOLATE;
      tokenConfigInput.borrowingFactor = 8000;
      tokenConfigInput.maxBorrow = 1_000_000 ether;

      ibTokenConfigInput.tier = LibConstant.AssetTier.ISOLATE;
      ibTokenConfigInput.collateralFactor = 0;
      ibTokenConfigInput.maxCollateral = 0;
      address ibPstake = moneyMarket.openMarket(pstake, tokenConfigInput, ibTokenConfigInput);

      _writeJson(vm.toString(ibBusd), ".ibTokens.ibBusd");
      _writeJson(vm.toString(ibDodo), ".ibTokens.ibDodo");
      _writeJson(vm.toString(ibPstake), ".ibTokens.ibPstake");
      // _writeJson(vm.toString(ibMock6), ".ibTokens.ibMock6");
    }

    _stopBroadcast();

    //---- setup user positions ----//

    _startUserBroadcast();

    // MockERC20(mock6DecimalsToken).mint(userAddress, 100e6);

    MockERC20(wbnb).approve(address(accountManager), type(uint256).max);
    MockERC20(busd).approve(address(accountManager), type(uint256).max);
    MockERC20(dodo).approve(address(accountManager), type(uint256).max);
    MockERC20(pstake).approve(address(accountManager), type(uint256).max);
    // MockERC20(mock6DecimalsToken).approve(address(accountManager), type(uint256).max);

    // seed money market
    accountManager.deposit(dodo, 10 ether);
    accountManager.deposit(pstake, 10 ether);
    // accountManager.deposit(mock6DecimalsToken, 10e6);

    // subAccount 0
    accountManager.depositAndAddCollateral(0, wbnb, 78.09 ether);
    accountManager.depositAndAddCollateral(0, busd, 12.2831207 ether);

    // accountManager.borrow(0, dodo, 3.14159 ether);
    // accountManager.borrow(0, mock6DecimalsToken, 1.2e6);

    // subAccount 1
    // accountManager.depositAndAddCollateral(1, mock6DecimalsToken, 10e6);
    accountManager.depositAndAddCollateral(1, busd, 10 ether);

    // accountManager.borrow(1, pstake, 2.34 ether);

    _stopBroadcast();
  }
}
