// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

interface IJBPriceFeed {
  function currentPrice(uint256 _targetDecimals) external view returns (uint256);
}
