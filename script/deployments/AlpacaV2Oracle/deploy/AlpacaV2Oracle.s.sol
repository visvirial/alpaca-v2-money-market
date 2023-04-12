// SPDX-License-Identifier: BUSL
pragma solidity 0.8.19;

import "../../../BaseScript.sol";

import { AlpacaV2Oracle } from "solidity/contracts/oracle/AlpacaV2Oracle.sol";
import { IAlpacaV2Oracle } from "solidity/contracts/oracle/interfaces/IAlpacaV2Oracle.sol";

contract DeployAlpacaV2OracleScript is BaseScript {
  using stdJson for string;

  function run() public {
    _loadAddresses();

    _startDeployerBroadcast();

    alpacaV2Oracle = new AlpacaV2Oracle(oracleMedianizer, busd, usdPlaceholder);

    // set mm oracle
    moneyMarket.setOracle(address(alpacaV2Oracle));

    _stopBroadcast();

    _writeJson(vm.toString(address(alpacaV2Oracle)), ".alpacaV2Oracle");
  }
}