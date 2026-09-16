// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RedeemVault} from "../RedeemVault.sol";

contract RedeemVaultDeployer {
    function deploy(
        address vault,
        address vaultStore,
        address vaultConfig
    ) external returns (address redeemVault) {
        redeemVault = address(new RedeemVault(vault, vaultStore, vaultConfig));
    }
}
