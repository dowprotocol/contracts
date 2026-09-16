//SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

contract TimeLock is TimelockController, AccessControlEnumerable {
  uint256 public immutable MIN_DELAY = 6 hours;
    error BelowMiniDelay();
  constructor(
    address[] memory proposers,
    address[] memory executors,
    address admin,
    uint256 minDelay
  ) TimelockController(minDelay, proposers, executors, admin) {
        if (minDelay < MIN_DELAY) {
            revert BelowMiniDelay();
        }
  }

  function getMinDelay() public view override returns (uint256) {
    return MIN_DELAY > super.getMinDelay() ? MIN_DELAY : super.getMinDelay();
  }

  function supportsInterface(
    bytes4 interfaceId
  ) public view virtual override(TimelockController, AccessControlEnumerable) returns (bool) {
    return TimelockController.supportsInterface(interfaceId) || AccessControlEnumerable.supportsInterface(interfaceId);
  }

  function _revokeRole(
    bytes32 role,
    address account
  ) internal virtual override(AccessControl, AccessControlEnumerable) returns (bool) {
    return AccessControlEnumerable._revokeRole(role, account);
  }

  function _grantRole(
    bytes32 role,
    address account
  ) internal virtual override(AccessControl, AccessControlEnumerable) returns (bool) {
    return AccessControlEnumerable._grantRole(role, account);
  }
}