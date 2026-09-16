// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EpochManager} from "../EpochManager.sol";
import {EpochManagerStore} from "../EpochManagerStore.sol";

contract EpochArtifactsDeployer {
    function deploy(
        address factoryAdmin
    ) external returns (address epochManagerStore, address epochManager) {
        EpochManagerStore store = new EpochManagerStore(factoryAdmin);
        epochManagerStore = address(store);
        epochManager = address(new EpochManager(epochManagerStore, factoryAdmin));
    }
}
