// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// libs
import { LibLYF01 } from "../libraries/LibLYF01.sol";
import { LibDoublyLinkedList } from "../libraries/LibDoublyLinkedList.sol";

// interfaces
import { ILYFCollateralFacet } from "../interfaces/ILYFCollateralFacet.sol";

contract LYFCollateralFacet is ILYFCollateralFacet {
  using SafeERC20 for ERC20;
  using LibDoublyLinkedList for LibDoublyLinkedList.List;

  event LogAddCollateral(address indexed _subAccount, address indexed _token, uint256 _amount);

  event LogRemoveCollateral(address indexed _subAccount, address indexed _token, uint256 _amount);

  event LogTransferCollateral(
    address indexed _fromSubAccount,
    address indexed _toSubAccount,
    address indexed _token,
    uint256 _amount
  );

  function addCollateral(
    address _account,
    uint256 _subAccountId,
    address _token,
    uint256 _amount
  ) external {
    LibLYF01.LYFDiamondStorage storage ds = LibLYF01.lyfDiamondStorage();

    if (ds.tokenConfigs[_token].tier != LibLYF01.AssetTier.COLLATERAL) {
      revert LYFCollateralFacet_InvalidAssetTier();
    }

    if (_amount + ds.collats[_token] > ds.tokenConfigs[_token].maxCollateral) {
      revert LYFCollateralFacet_ExceedCollateralLimit();
    }

    address _subAccount = LibLYF01.getSubAccount(_account, _subAccountId);

    LibLYF01.addCollat(_subAccount, _token, _amount, ds);

    ERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

    emit LogAddCollateral(_subAccount, _token, _amount);
  }

  function removeCollateral(
    uint256 _subAccountId,
    address _token,
    uint256 _amount
  ) external {
    LibLYF01.LYFDiamondStorage storage ds = LibLYF01.lyfDiamondStorage();

    // todo: interest model
    // LibLYF01.accureInterest(_token, ds);

    address _subAccount = LibLYF01.getSubAccount(msg.sender, _subAccountId);
    uint256 _actualAmountRemoved = LibLYF01.removeCollateral(_subAccount, _token, _amount, ds);

    // violate check-effect pattern for gas optimization, will change after come up with a way that doesn't loop
    if (!LibLYF01.isSubaccountHealthy(_subAccount, ds)) {
      revert LYFCollateralFacet_BorrowingPowerTooLow();
    }

    ERC20(_token).safeTransfer(msg.sender, _actualAmountRemoved);

    emit LogRemoveCollateral(_subAccount, _token, _actualAmountRemoved);
  }

  function transferCollateral(
    uint256 _fromSubAccountId,
    uint256 _toSubAccountId,
    address _token,
    uint256 _amount
  ) external {
    LibLYF01.LYFDiamondStorage storage ds = LibLYF01.lyfDiamondStorage();

    // todo
    // LibMoneyMarket01.accureInterest(_token, ds);

    address _fromSubAccount = LibLYF01.getSubAccount(msg.sender, _fromSubAccountId);

    uint256 _actualAmountRemove = LibLYF01.removeCollateral(_fromSubAccount, _token, _amount, ds);

    if (!LibLYF01.isSubaccountHealthy(_fromSubAccount, ds)) {
      revert LYFCollateralFacet_BorrowingPowerTooLow();
    }

    address _toSubAccount = LibLYF01.getSubAccount(msg.sender, _toSubAccountId);

    LibLYF01.addCollat(_toSubAccount, _token, _actualAmountRemove, ds);

    emit LogTransferCollateral(_fromSubAccount, _toSubAccount, _token, _actualAmountRemove);
  }

  function getCollaterals(address _account, uint256 _subAccountId)
    external
    view
    returns (LibDoublyLinkedList.Node[] memory)
  {
    LibLYF01.LYFDiamondStorage storage ds = LibLYF01.lyfDiamondStorage();
    address _subAccount = LibLYF01.getSubAccount(_account, _subAccountId);
    LibDoublyLinkedList.List storage subAccountCollateralList = ds.subAccountCollats[_subAccount];
    return subAccountCollateralList.getAll();
  }

  function collats(address _token) external view returns (uint256) {
    LibLYF01.LYFDiamondStorage storage ds = LibLYF01.lyfDiamondStorage();
    return ds.collats[_token];
  }

  function subAccountCollatAmount(address _subAccount, address _token) external view returns (uint256) {
    LibLYF01.LYFDiamondStorage storage ds = LibLYF01.lyfDiamondStorage();
    return ds.subAccountCollats[_subAccount].getAmount(_token);
  }

  function _validateAddCollateral(
    address _token,
    uint256 _collateralAmount,
    LibLYF01.LYFDiamondStorage storage ds
  ) internal view {
    if (ds.tokenConfigs[_token].tier != LibLYF01.AssetTier.COLLATERAL) {
      revert LYFCollateralFacet_InvalidAssetTier();
    }

    if (_collateralAmount + ds.collats[_token] > ds.tokenConfigs[_token].maxCollateral) {
      revert LYFCollateralFacet_ExceedCollateralLimit();
    }
  }
}