// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vault} from "../Vault.sol";

contract VaultLogicDeployer {
    function deploy(
        address vaultStore,
        address vaultConfig
    ) external returns (address vault) {
        vault = address(new Vault(vaultStore, vaultConfig));
    }
}
