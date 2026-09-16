// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract VaultShareToken is ERC20, AccessControl {
    bytes32 public constant ALLOWED_TO_OPERATE_TOKEN_ROLE =
        keccak256("ALLOWED_TO_OPERATE_TOKEN_ROLE");

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _totalSupply,
        address _defaultAdminRole,
        address _initialMintOwner
    ) ERC20(_name, _symbol) {
        require(
            _defaultAdminRole != address(0) && _initialMintOwner != address(0),
            "Invalid Zero Address"
        );
        _grantRole(DEFAULT_ADMIN_ROLE, _defaultAdminRole);
        _grantRole(ALLOWED_TO_OPERATE_TOKEN_ROLE, _initialMintOwner);
        require(_totalSupply > 0, "Invalid Zero Amt");
        _mint(_initialMintOwner, _totalSupply);
    }

    function burn(
        address from,
        uint256 amount
    ) external onlyRole(ALLOWED_TO_OPERATE_TOKEN_ROLE) {
        _burn(from, amount);
    }

    function transfer(
        address to,
        uint256 amount
    ) public override onlyRole(ALLOWED_TO_OPERATE_TOKEN_ROLE) returns (bool) {
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override onlyRole(ALLOWED_TO_OPERATE_TOKEN_ROLE) returns (bool) {
        return super.transferFrom(from, to, amount);
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert("Approve Disabled");
    }
}
