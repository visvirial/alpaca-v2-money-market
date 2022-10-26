// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { LibMoneyMarket01 } from "../libraries/LibMoneyMarket01.sol";

import { IAdminFacet } from "../interfaces/IAdminFacet.sol";

contract AdminFacet is IAdminFacet {
  // TODO: validate role
  function setTokenToIbTokens(IbPair[] memory _ibPair) external {
    LibMoneyMarket01.MoneyMarketDiamondStorage
      storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    uint256 _ibPairLength = _ibPair.length;
    for (uint8 _i; _i < _ibPairLength; ) {
      moneyMarketDs.tokenToIbTokens[_ibPair[_i].token] = _ibPair[_i].ibToken;
      moneyMarketDs.ibTokenToTokens[_ibPair[_i].ibToken] = _ibPair[_i].token;
      unchecked {
        _i++;
      }
    }
  }

  // TODO: validate role
  function setTokenConfigs(TokenConfigInput[] memory _tokenConfigs) external {
    LibMoneyMarket01.MoneyMarketDiamondStorage
      storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    uint256 _inputLength = _tokenConfigs.length;
    for (uint8 _i; _i < _inputLength; ) {
      LibMoneyMarket01.TokenConfig memory _tokenConfig = LibMoneyMarket01
        .TokenConfig({
          tier: _tokenConfigs[_i].tier,
          collateralFactor: _tokenConfigs[_i].collateralFactor,
          borrowingFactor: _tokenConfigs[_i].borrowingFactor
        });

      moneyMarketDs.tokenConfigs[_tokenConfigs[_i].token] = _tokenConfig;

      unchecked {
        _i++;
      }
    }
  }

  function tokenToIbTokens(address _token) external view returns (address) {
    LibMoneyMarket01.MoneyMarketDiamondStorage
      storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    return moneyMarketDs.tokenToIbTokens[_token];
  }

  function ibTokenToTokens(address _ibToken) external view returns (address) {
    LibMoneyMarket01.MoneyMarketDiamondStorage
      storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    return moneyMarketDs.ibTokenToTokens[_ibToken];
  }

  function tokenConfigs(address _token)
    external
    view
    returns (LibMoneyMarket01.TokenConfig memory)
  {
    LibMoneyMarket01.MoneyMarketDiamondStorage
      storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    return moneyMarketDs.tokenConfigs[_token];
  }
}