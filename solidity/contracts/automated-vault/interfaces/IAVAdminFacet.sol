// SPDX-License-Identifier: BUSL
pragma solidity 0.8.19;

import { LibAVConstant } from "../libraries/LibAVConstant.sol";

interface IAVAdminFacet {
  error AVTradeFacet_InvalidToken(address _token);
  error AVAdminFacet_InvalidShareToken(address _token);
  error AVAdminFacet_InvalidHandler();
  error AVAdminFacet_InvalidParams();
  error AVAdminFacet_InvalidAddress();

  struct ShareTokenPairs {
    address token;
    address vaultToken;
  }

  struct VaultConfigInput {
    address vaultToken;
    address lpToken;
    address stableToken;
    address assetToken;
    address stableTokenInterestModel;
    address assetTokenInterestModel;
    uint8 leverageLevel;
    uint16 managementFeePerSec;
  }

  struct TokenConfigInput {
    LibAVConstant.AssetTier tier;
    address token;
  }

  function openVault(
    address _lpToken,
    address _stableToken,
    address _assetToken,
    address _handler,
    uint8 _leverageLevel,
    uint16 _managementFeePerSec,
    address _stableTokenInterestModel,
    address _assetTokenInterestModel
  ) external returns (address _newShareToken);

  function setTokenConfigs(TokenConfigInput[] calldata configs) external;

  function setMoneyMarket(address _newMoneyMarket) external;

  function setOracle(address _oracle) external;

  function setTreasury(address _treasury) external;

  function setManagementFeePerSec(address _vaultToken, uint16 _newManagementFeePerSec) external;

  function setInterestRateModels(
    address _vaultToken,
    address _newStableTokenInterestRateModel,
    address _newAssetTokenInterestRateModel
  ) external;

  function setRepurchaseRewardBps(uint16 _newBps) external;

  function setOperatorsOk(address[] calldata _operators, bool _isOk) external;

  function setRepurchasersOk(address[] calldata _repurchasers, bool _isOk) external;
}
