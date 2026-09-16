// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract VaultDRT is ERC20, AccessControl {
    bytes32 public constant ALLOWED_TO_OPERATE_TOKEN_ROLE =
        keccak256("ALLOWED_TO_OPERATE_TOKEN_ROLE");

    address public immutable vault;

    event VaultSet(address indexed vault);

    constructor(address _vault, string memory _name)
        ERC20(string(abi.encodePacked(_name, " DRT")), "DRT")
    {
        require(_vault != address(0), "Invalid vault");
        vault = _vault;
        _grantRole(DEFAULT_ADMIN_ROLE, _vault);
        _grantRole(ALLOWED_TO_OPERATE_TOKEN_ROLE, _vault);
        emit VaultSet(_vault);
    }

    function mint(address to, uint256 amount)
        external onlyRole(ALLOWED_TO_OPERATE_TOKEN_ROLE)
    {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount)
        external onlyRole(ALLOWED_TO_OPERATE_TOKEN_ROLE)
    {
        _burn(from, amount);
    }

    function transfer(address to, uint256 amount)
        public override onlyRole(ALLOWED_TO_OPERATE_TOKEN_ROLE) returns (bool)
    {
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount)
        public override onlyRole(ALLOWED_TO_OPERATE_TOKEN_ROLE) returns (bool)
    {
        return super.transferFrom(from, to, amount);
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert("Approve Disabled");
    }
}
