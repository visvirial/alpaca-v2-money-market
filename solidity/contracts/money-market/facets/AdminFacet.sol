// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { LibMoneyMarket01 } from "../libraries/LibMoneyMarket01.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { LibDoublyLinkedList } from "../libraries/LibDoublyLinkedList.sol";

// interfaces
import { IAdminFacet } from "../interfaces/IAdminFacet.sol";
import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";

contract AdminFacet is IAdminFacet {
  using SafeCast for uint256;
  using LibDoublyLinkedList for LibDoublyLinkedList.List;

  event LogSetRewardDistributor(address indexed _address);
  event LogAddRewardPerSec(address indexed _rewardToken, uint256 _rewardPerSec);
  event LogUpdateRewardPerSec(address indexed _rewardToken, uint256 _rewardPerSec);
  event LogAddLendingPool(address indexed _token, address indexed _rewardToken, uint256 _allocPoint);
  event LogSetLendingPool(address indexed _token, address indexed _rewardToken, uint256 _allocPoint);
  event LogAddBorroweringPool(address indexed _token, address indexed _rewardToken, uint256 _allocPoint);
  event LogSetBorrowingPool(address indexed _token, address indexed _rewardToken, uint256 _allocPoint);

  modifier onlyOwner() {
    LibDiamond.enforceIsContractOwner();
    _;
  }

  function setTokenToIbTokens(IbPair[] memory _ibPair) external onlyOwner {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    uint256 _ibPairLength = _ibPair.length;
    for (uint8 _i; _i < _ibPairLength; ) {
      LibMoneyMarket01.setIbPair(_ibPair[_i].token, _ibPair[_i].ibToken, moneyMarketDs);
      unchecked {
        _i++;
      }
    }
  }

  function setTokenConfigs(TokenConfigInput[] memory _tokenConfigs) external onlyOwner {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    uint256 _inputLength = _tokenConfigs.length;
    for (uint8 _i; _i < _inputLength; ) {
      LibMoneyMarket01.TokenConfig memory _tokenConfig = LibMoneyMarket01.TokenConfig({
        tier: _tokenConfigs[_i].tier,
        collateralFactor: _tokenConfigs[_i].collateralFactor,
        borrowingFactor: _tokenConfigs[_i].borrowingFactor,
        maxCollateral: _tokenConfigs[_i].maxCollateral,
        maxBorrow: _tokenConfigs[_i].maxBorrow,
        maxToleranceExpiredSecond: _tokenConfigs[_i].maxToleranceExpiredSecond,
        to18ConversionFactor: LibMoneyMarket01.to18ConversionFactor(_tokenConfigs[_i].token)
      });

      LibMoneyMarket01.setTokenConfig(_tokenConfigs[_i].token, _tokenConfig, moneyMarketDs);

      unchecked {
        _i++;
      }
    }
  }

  function setNonCollatBorrower(address _borrower, bool _isOk) external onlyOwner {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    moneyMarketDs.nonCollatBorrowerOk[_borrower] = _isOk;
  }

  function tokenToIbTokens(address _token) external view returns (address) {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    return moneyMarketDs.tokenToIbTokens[_token];
  }

  function ibTokenToTokens(address _ibToken) external view returns (address) {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    return moneyMarketDs.ibTokenToTokens[_ibToken];
  }

  function tokenConfigs(address _token) external view returns (LibMoneyMarket01.TokenConfig memory) {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    return moneyMarketDs.tokenConfigs[_token];
  }

  function setInterestModel(address _token, address _model) external onlyOwner {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    moneyMarketDs.interestModels[_token] = IInterestRateModel(_model);
  }

  function setNonCollatInterestModel(
    address _account,
    address _token,
    address _model
  ) external onlyOwner {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    bytes32 _nonCollatId = LibMoneyMarket01.getNonCollatId(_account, _token);
    moneyMarketDs.nonCollatInterestModels[_nonCollatId] = IInterestRateModel(_model);
  }

  function setOracle(address _oracle) external onlyOwner {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    moneyMarketDs.oracle = IPriceOracle(_oracle);
  }

  function setRepurchasersOk(address[] memory list, bool _isOk) external onlyOwner {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    uint256 _length = list.length;
    for (uint8 _i; _i < _length; ) {
      moneyMarketDs.repurchasersOk[list[_i]] = _isOk;
      unchecked {
        _i++;
      }
    }
  }

  function setLiquidationStratsOk(address[] calldata list, bool _isOk) external onlyOwner {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    uint256 _length = list.length;
    for (uint256 _i; _i < _length; ) {
      moneyMarketDs.liquidationStratOk[list[_i]] = _isOk;
      unchecked {
        _i++;
      }
    }
  }

  function setNonCollatBorrowLimitUSDValues(NonCollatBorrowLimitInput[] memory _nonCollatBorrowLimitInputs)
    external
    onlyOwner
  {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    uint256 _length = _nonCollatBorrowLimitInputs.length;
    for (uint8 _i; _i < _length; ) {
      NonCollatBorrowLimitInput memory input = _nonCollatBorrowLimitInputs[_i];
      moneyMarketDs.nonCollatBorrowLimitUSDValues[input.account] = input.limit;
      unchecked {
        _i++;
      }
    }
  }

  function setRewardDistributor(address _addr) external onlyOwner {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    moneyMarketDs.rewardDistributor = _addr;

    emit LogSetRewardDistributor(_addr);
  }

  function getRewardPerSec(address _rewardToken) external view onlyOwner returns (uint256 _rewardPerSec) {
    _rewardPerSec = LibMoneyMarket01.moneyMarketDiamondStorage().rewardPerSecList.getAmount(_rewardToken);
  }

  function addRewardPerSec(address _rewardToken, uint256 _rewardPerSec) external onlyOwner {
    LibDoublyLinkedList.List storage rewardPerSecList = LibMoneyMarket01.moneyMarketDiamondStorage().rewardPerSecList;
    if (rewardPerSecList.getNextOf(LibDoublyLinkedList.START) == LibDoublyLinkedList.EMPTY) {
      rewardPerSecList.init();
    }
    rewardPerSecList.addOrUpdate(_rewardToken, _rewardPerSec);

    emit LogAddRewardPerSec(_rewardToken, _rewardPerSec);
  }

  function updateRewardPerSec(address _rewardToken, uint256 _rewardPerSec) external onlyOwner {
    LibDoublyLinkedList.List storage rewardPerSecList = LibMoneyMarket01.moneyMarketDiamondStorage().rewardPerSecList;
    if (rewardPerSecList.getNextOf(LibDoublyLinkedList.START) == LibDoublyLinkedList.EMPTY) {
      rewardPerSecList.init();
    }

    // todo: update all pool that has this reward

    rewardPerSecList.updateOrRemove(_rewardToken, _rewardPerSec);

    emit LogUpdateRewardPerSec(_rewardToken, _rewardPerSec);
  }

  function addLendingPool(
    address _rewardToken,
    address _token,
    uint256 _allocPoint
  ) external onlyOwner {
    if (_token == address(0)) revert AdminFacet_InvalidAddress();

    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    if (moneyMarketDs.lendingPoolInfos[_rewardToken][_token].allocPoint > 0) revert AdminFacet_PoolIsAlreadyAdded();
    moneyMarketDs.lendingPoolInfos[_rewardToken][_token] = LibMoneyMarket01.PoolInfo({
      accRewardPerShare: 0,
      lastRewardTime: block.timestamp.toUint128(),
      allocPoint: _allocPoint.toUint128()
    });
    moneyMarketDs.totalLendingPoolAllocPoints[_rewardToken] += _allocPoint;

    emit LogAddLendingPool(_token, _rewardToken, _allocPoint);
  }

  function setLendingPool(
    address _rewardToken,
    address _token,
    uint256 _newAllocPoint
  ) external onlyOwner {
    if (_token == address(0)) revert AdminFacet_InvalidAddress();

    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    LibMoneyMarket01.PoolInfo memory poolInfo = moneyMarketDs.lendingPoolInfos[_rewardToken][_token];
    uint256 _totalLendingPoolAllocPoint = moneyMarketDs.totalLendingPoolAllocPoints[_rewardToken];
    moneyMarketDs.totalLendingPoolAllocPoints[_rewardToken] +=
      _totalLendingPoolAllocPoint -
      poolInfo.allocPoint +
      _newAllocPoint;
    moneyMarketDs.lendingPoolInfos[_rewardToken][_token].allocPoint = _newAllocPoint.toUint128();

    emit LogSetLendingPool(_token, _rewardToken, _newAllocPoint);
  }

  function addBorrowingPool(
    address _rewardToken,
    address _token,
    uint256 _allocPoint
  ) external onlyOwner {
    if (_token == address(0)) revert AdminFacet_InvalidAddress();

    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    if (moneyMarketDs.borrowingPoolInfos[_rewardToken][_token].allocPoint > 0) revert AdminFacet_PoolIsAlreadyAdded();
    moneyMarketDs.borrowingPoolInfos[_rewardToken][_token] = LibMoneyMarket01.PoolInfo({
      accRewardPerShare: 0,
      lastRewardTime: block.timestamp.toUint128(),
      allocPoint: _allocPoint.toUint128()
    });
    moneyMarketDs.totalBorrowingPoolAllocPoints[_rewardToken] += _allocPoint;

    emit LogAddBorroweringPool(_token, _rewardToken, _allocPoint);
  }

  function setBorrowingPool(
    address _rewardToken,
    address _token,
    uint256 _newAllocPoint
  ) external onlyOwner {
    if (_token == address(0)) revert AdminFacet_InvalidAddress();

    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
    LibMoneyMarket01.PoolInfo memory poolInfo = moneyMarketDs.borrowingPoolInfos[_rewardToken][_token];
    uint256 _totalBorrowingPoolAllocPoint = moneyMarketDs.totalBorrowingPoolAllocPoints[_rewardToken];
    moneyMarketDs.totalBorrowingPoolAllocPoints[_rewardToken] +=
      _totalBorrowingPoolAllocPoint -
      poolInfo.allocPoint +
      _newAllocPoint;
    moneyMarketDs.borrowingPoolInfos[_rewardToken][_token].allocPoint = _newAllocPoint.toUint128();

    emit LogSetBorrowingPool(_token, _rewardToken, _newAllocPoint);
  }
}
