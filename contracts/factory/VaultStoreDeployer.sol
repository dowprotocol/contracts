// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultStore} from "../VaultStore.sol";

contract VaultStoreDeployer {
    function deploy(address factoryAdmin) external returns (address vaultStore) {
        vaultStore = address(new VaultStore(factoryAdmin));
    }
}
