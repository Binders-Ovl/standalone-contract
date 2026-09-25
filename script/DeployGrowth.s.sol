// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {CentralConsole} from "../modular/supportContract/CentralConsole.sol";
import {Book0fGrowth} from "../modular/shelf/Book0fGrowth.sol";
import {BinderGrowth} from "../modular/growth/BinderGrowth.sol";
import {ActivityEscrow} from "../modular/growth/ActivityEscrow.sol";
import {Training} from "../modular/growth/Training.sol";
import {Quest} from "../modular/growth/Quest.sol";
import {InitializeGrowth} from "../initiate/InitializeGrowth.sol";

/// @notice Deploy only the growth layer onto an already wired CP5.1a graph.
/// No live addresses, private keys or production balance values are embedded.
abstract contract GrowthDeploymentBase {
    struct GrowthDeployment {
        Book0fGrowth book;
        BinderGrowth ledger;
        Training training;
        Quest quest;
    }

    function _deployGrowth(CentralConsole control, address entropy, address provider, address treasury)
        internal
        returns (GrowthDeployment memory deployed)
    {
        deployed.book = new Book0fGrowth(address(control), control.scaleOfBalance());
        deployed.ledger = new BinderGrowth(address(control), control.binderData(), control.binderInventory());
        ActivityEscrow.Dependencies memory deps = ActivityEscrow.Dependencies({
            console: address(control),
            data: control.binderData(),
            book: address(deployed.book),
            growth: address(deployed.ledger),
            skills: control.binderSkills(),
            arts: control.book0fArts(),
            entropy: entropy,
            provider: provider,
            treasury: treasury
        });
        deployed.training = new Training(deps);
        deployed.quest = new Quest(deps);
        control.configureGrowthSystem(
            address(deployed.book), address(deployed.ledger), address(deployed.training), address(deployed.quest)
        );
        require(control.isGrowthWired(), "Incomplete growth wiring");
    }
}

contract DeployGrowth is Script, GrowthDeploymentBase {
    function run() external returns (GrowthDeployment memory deployed) {
        uint256 key = vm.envUint("PRIVATE_KEY");
        CentralConsole control = CentralConsole(vm.envAddress("CENTRAL_CONSOLE"));
        address entropy = vm.envAddress("ENTROPY_ADDRESS");
        address provider = vm.envAddress("ENTROPY_PROVIDER");
        address treasury = vm.envAddress("GROWTH_TREASURY");
        bool seedSimulation = vm.envOr("SEED_SIMULATION_GROWTH", false);
        vm.startBroadcast(key);
        deployed = _deployGrowth(control, entropy, provider, treasury);
        if (seedSimulation) InitializeGrowth.seed(control);
        vm.stopBroadcast();
    }
}
