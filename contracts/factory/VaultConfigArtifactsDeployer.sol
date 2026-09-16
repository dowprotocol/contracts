// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultConfig} from "../VaultConfig.sol";
import {VaultConfigStore} from "../VaultConfigStore.sol";

contract VaultConfigArtifactsDeployer {
    function deploy(
        address factoryAdmin
    ) external returns (address vaultConfigStore, address vaultConfig) {
        VaultConfigStore store = new VaultConfigStore(factoryAdmin);
        vaultConfigStore = address(store);
        vaultConfig = address(new VaultConfig(vaultConfigStore, factoryAdmin));
    }
}
