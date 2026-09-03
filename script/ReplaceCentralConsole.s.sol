// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../modular/BinderData.sol";
import "../modular/BinderLogic.sol";
import "../modular/BinderSkills.sol";
import "../modular/Book0fLife.sol";
import "../modular/Battle/BattleFactory.sol";
import "../modular/Battle/BattleProxy.sol";
import "../modular/FusionMinter.sol";
import "../modular/ScaleOfBalance.sol";
import "../modular/supportContract/CentralConsole.sol";

/// @notice Replaces a non-UUPS CentralConsole against permanent BinderData.
/// Existing BattleProxy clones remain bound to their old Factory and can settle.
contract ReplaceCentralConsole is Script {
    struct ReplacementInput {
        address oldConsole;
        address binderData;
        address binderSkills;
        address book0fLife;
        address book0fArts;
        address book0fRealms;
        address binderMetadata;
        address binderLogic;
        address fusionMinter;
        address scaleOfBalance;
        address allegianceRegistry;
        uint32 nextBattleFactoryVersion;
    }

    function run() external returns (address newConsoleAddress, address newBattleFactoryAddress) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        (newConsoleAddress, newBattleFactoryAddress) = _replace(vm.addr(deployerKey), _loadInput());
        vm.stopBroadcast();
    }

    function _loadInput() internal returns (ReplacementInput memory input) {
        input.oldConsole = vm.envAddress("OLD_CENTRAL_CONSOLE");
        input.binderData = vm.envAddress("BINDER_DATA");
        input.binderSkills = vm.envAddress("BINDER_SKILLS");
        input.book0fLife = vm.envAddress("BOOK_OF_LIFE");
        input.book0fArts = vm.envAddress("BOOK_OF_ARTS");
        input.book0fRealms = vm.envAddress("BOOK_OF_REALMS");
        input.binderMetadata = vm.envAddress("BINDER_METADATA");
        input.binderLogic = vm.envAddress("BINDER_LOGIC");
        input.fusionMinter = vm.envAddress("FUSION_MINTER");
        input.scaleOfBalance = vm.envAddress("SCALE_OF_BALANCE");
        input.allegianceRegistry = vm.envAddress("ALLEGIANCE_REGISTRY");
        input.nextBattleFactoryVersion = uint32(vm.envUint("NEXT_BATTLE_FACTORY_VERSION"));
    }

    function _replace(address deployer, ReplacementInput memory input)
        internal
        returns (address newConsoleAddress, address newBattleFactoryAddress)
    {
        BinderData binderData = BinderData(input.binderData);
        Book0fLife life = Book0fLife(input.book0fLife);
        BinderSkills skills = BinderSkills(input.binderSkills);
        CentralConsole newConsole = new CentralConsole(deployer, input.binderData);

        _stagePermissions(binderData, life, skills, newConsole);
        _registerModules(newConsole, input);

        BattleProxy implementation = new BattleProxy();
        BattleFactory factory = new BattleFactory(deployer, address(newConsole), address(implementation));
        newConsole.setBattleFactory(address(factory), input.nextBattleFactoryVersion);
        require(newConsole.isFullyWired(), "Incomplete replacement wiring");

        _revokeOldControlPlane(binderData, life, CentralConsole(input.oldConsole), deployer);
        return (address(newConsole), address(factory));
    }

    function _stagePermissions(BinderData binderData, Book0fLife life, BinderSkills skills, CentralConsole newConsole)
        internal
    {
        binderData.grantRole(binderData.CONFIG_ROLE(), address(newConsole));
        life.grantRole(life.CONFIG_ROLE(), address(newConsole));
        skills.grantRole(skills.DEFAULT_ADMIN_ROLE(), address(newConsole));
    }

    function _registerModules(CentralConsole newConsole, ReplacementInput memory input) internal {
        newConsole.setBook0fLife(input.book0fLife);
        newConsole.setBook0fArts(input.book0fArts);
        newConsole.setBook0fRealms(input.book0fRealms);
        newConsole.setBinderSkills(input.binderSkills);
        newConsole.setBinderMetadata(input.binderMetadata);
        newConsole.setAllegianceRegistry(input.allegianceRegistry);
        newConsole.setBinderLogic(input.binderLogic);
        newConsole.setFusionMinter(input.fusionMinter);
        newConsole.setScaleOfBalance(input.scaleOfBalance);
    }

    function _revokeOldControlPlane(BinderData binderData, Book0fLife life, CentralConsole oldConsole, address deployer)
        internal
    {
        binderData.revokeRole(binderData.CONFIG_ROLE(), address(oldConsole));
        life.revokeRole(life.CONFIG_ROLE(), address(oldConsole));
        oldConsole.revokeRole(oldConsole.CONFIG_ROLE(), deployer);
    }
}
