// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts-4.8/proxy/ERC1967/ERC1967Proxy.sol";
import "../modular/AllegianceRegistry.sol";
import "../modular/BinderData.sol";
import "../modular/BinderLogic.sol";
import "../modular/BinderSkills.sol";
import "../modular/Book0fArts.sol";
import "../modular/Book0fLife.sol";
import "../modular/Book0fRealms.sol";
import "../modular/FusionMinter.sol";
import "../modular/ScaleOfBalance.sol";
import "../modular/scripts/InitializeGameData.sol";
import "../modular/Battle/BattleFactory.sol";
import "../modular/Battle/BattleProxy.sol";
import "../modular/supportContract/BinderMetadata.sol";
import "../modular/supportContract/CentralConsole.sol";

/// @notice Deploys and wires the initial canonical module set.
contract DeployAndWire is Script {
    struct Deployment {
        address binderData;
        address centralConsole;
        address allegianceRegistry;
        address book0fLife;
        address book0fArts;
        address book0fRealms;
        address binderSkillsImplementation;
        address binderSkillsProxy;
        address binderMetadata;
        address binderLogic;
        address fusionMinter;
        address scaleOfBalance;
        address battleImplementation;
        address battleFactory;
    }

    function run() external returns (Deployment memory deployment) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        vm.startBroadcast(deployerKey);
        deployment = _deployAndWire(
            deployer,
            vm.envAddress("ENTROPY_ADDRESS"),
            vm.envAddress("ENTROPY_PROVIDER"),
            vm.envOr("BASE_IMAGE_URI", string(""))
        );
        vm.stopBroadcast();
    }

    function _deployAndWire(address deployer, address entropy, address entropyProvider, string memory baseImageURI)
        internal
        returns (Deployment memory deployment)
    {
        _deployBase(deployment, deployer, baseImageURI);
        _configureInitialGameData(deployment);
        _deployModules(deployment, deployer, entropy, entropyProvider);
        _wire(deployment, deployer);
    }

    function _deployBase(Deployment memory deployment, address deployer, string memory baseImageURI) internal {
        deployment.binderData = address(new BinderData(deployer, baseImageURI));
        deployment.centralConsole = address(new CentralConsole(deployer, deployment.binderData));
        deployment.allegianceRegistry = address(new AllegianceRegistry(deployer));
        deployment.book0fLife = address(new Book0fLife());
        deployment.book0fArts = address(new Book0fArts(deployer));
        deployment.book0fRealms = address(new Book0fRealms(deployer));
    }

    /// @dev Populate the immutable initial class, rarity, and fusion-recipe data
    /// before canonical consumer modules are registered.
    function _configureInitialGameData(Deployment memory deployment) internal {
        BinderData binderData = BinderData(deployment.binderData);
        Book0fLife book0fLife = Book0fLife(deployment.book0fLife);
        InitializeGameData initializer = new InitializeGameData();

        binderData.grantRole(binderData.CONFIG_ROLE(), address(initializer));
        book0fLife.grantRole(book0fLife.CONFIG_ROLE(), address(initializer));
        initializer.setup(deployment.book0fLife, deployment.binderData, deployment.allegianceRegistry);
        binderData.revokeRole(binderData.CONFIG_ROLE(), address(initializer));
        book0fLife.revokeRole(book0fLife.CONFIG_ROLE(), address(initializer));
    }

    function _deployModules(Deployment memory deployment, address deployer, address entropy, address entropyProvider)
        internal
    {
        deployment.binderSkillsImplementation = address(new BinderSkills());
        deployment.binderSkillsProxy = address(
            new ERC1967Proxy(
                deployment.binderSkillsImplementation,
                abi.encodeCall(BinderSkills.initialize, (deployer, deployment.binderData, deployment.centralConsole))
            )
        );
        deployment.binderMetadata = address(
            new BinderMetadata(
                deployment.binderData,
                deployment.binderSkillsProxy,
                deployment.book0fLife,
                deployment.book0fArts,
                deployer
            )
        );
        deployment.binderLogic = address(
            new BinderLogic(
                entropy,
                entropyProvider,
                deployment.binderData,
                deployment.book0fLife,
                deployment.allegianceRegistry,
                deployer
            )
        );
        deployment.fusionMinter =
            address(new FusionMinter(deployment.binderData, deployment.book0fLife, entropy, entropyProvider, deployer));
        deployment.scaleOfBalance = address(new ScaleOfBalance(deployment.binderData, deployment.book0fLife));
        deployment.battleImplementation = address(new BattleProxy());
        deployment.battleFactory =
            address(new BattleFactory(deployer, deployment.centralConsole, deployment.battleImplementation));
    }

    function _wire(Deployment memory deployment, address deployer) internal {
        BinderData binderData = BinderData(deployment.binderData);
        Book0fLife book0fLife = Book0fLife(deployment.book0fLife);
        BinderLogic binderLogic = BinderLogic(deployment.binderLogic);
        CentralConsole centralConsole = CentralConsole(deployment.centralConsole);

        binderData.grantRole(binderData.CONFIG_ROLE(), deployment.centralConsole);
        book0fLife.grantRole(book0fLife.CONFIG_ROLE(), deployment.centralConsole);
        binderLogic.grantRole(binderLogic.CONFIG_ROLE(), deployment.centralConsole);

        centralConsole.setBook0fLife(deployment.book0fLife);
        centralConsole.setBook0fArts(deployment.book0fArts);
        centralConsole.setBook0fRealms(deployment.book0fRealms);
        centralConsole.setBinderSkills(deployment.binderSkillsProxy);
        centralConsole.setBinderMetadata(deployment.binderMetadata);
        centralConsole.setAllegianceRegistry(deployment.allegianceRegistry);
        centralConsole.setBinderLogic(deployment.binderLogic);
        centralConsole.setFusionMinter(deployment.fusionMinter);
        centralConsole.setScaleOfBalance(deployment.scaleOfBalance);
        centralConsole.setBattleFactory(deployment.battleFactory, 1);
        require(centralConsole.isFullyWired(), "Incomplete canonical wiring");

        binderData.revokeRole(binderData.MINTER_ROLE(), deployer);
        binderData.revokeRole(binderData.FUSION_ROLE(), deployer);
        book0fLife.revokeRole(book0fLife.FUSION_MINTER(), deployer);
    }
}
