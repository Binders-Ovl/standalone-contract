// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../modular/BinderData.sol";
import "../modular/Book0fLife.sol";
import "../modular/ScaleOfBalance.sol";
import "../modular/supportContract/CentralConsole.sol";
import "../modular/supportContract/Errors.sol";
import "../modular/supportContract/binderStructs.sol";

contract ScaleOfBalanceClassCreationTest is Test {
    BinderData internal binderData;
    Book0fLife internal book0fLife;
    ScaleOfBalance internal scale;
    CentralConsole internal centralConsole;

    function setUp() public {
        binderData = new BinderData(address(this), "");
        book0fLife = new Book0fLife();
        scale = new ScaleOfBalance(address(binderData), address(book0fLife));
        binderData.grantRole(binderData.CONFIG_ROLE(), address(scale));
        book0fLife.grantRole(book0fLife.CONFIG_ROLE(), address(scale));
        book0fLife.registerRarity(1, "Common");
    }

    function testNewClassStartsAtVersionOneAndSynchronizesBinderData() public {
        scale.addNewClass(1, "Sentinel", 1, _validConfig());

        assertTrue(book0fLife.classExists(1));
        assertEq(book0fLife.getClassVersion(1), 1);
        assertEq(binderData.classVersion(1), 1);
    }

    function testDuplicateAndUnknownRarityAreRejected() public {
        scale.addNewClass(1, "Sentinel", 1, _validConfig());

        vm.expectRevert(bytes("Class already exists"));
        scale.addNewClass(1, "Duplicate", 1, _validConfig());

        vm.expectRevert(abi.encodeWithSelector(Book0fLife.RarityNotRegistered.selector, uint8(2)));
        scale.addNewClass(2, "Unknown Rarity", 2, _validConfig());
    }

    function testBookRejectsInvalidRangesAndCapacityWithoutScale() public {
        binderStructs.ClassConfig memory invalidRange = _validConfig();
        invalidRange.minStats[0] = 21;
        vm.expectRevert(bytes("Invalid stat range"));
        book0fLife.addNewClass(1, "Invalid Range", 1, invalidRange, 1);

        binderStructs.ClassConfig memory invalidCapacity = _validConfig();
        invalidCapacity.totalPoints = 81;
        vm.expectRevert(bytes("Points exceed stat capacity"));
        book0fLife.addNewClass(2, "Invalid Capacity", 1, invalidCapacity, 1);
    }

    function testConsoleScaleCutoverMovesBothTargetRolesAndLeavesConsoleConfigured() public {
        centralConsole = new CentralConsole(address(this), address(binderData));
        binderData.grantRole(binderData.CONFIG_ROLE(), address(centralConsole));
        book0fLife.grantRole(book0fLife.CONFIG_ROLE(), address(centralConsole));
        centralConsole.setBook0fLife(address(book0fLife));
        centralConsole.setScaleOfBalance(address(scale));

        ScaleOfBalance replacement = new ScaleOfBalance(address(binderData), address(book0fLife));
        centralConsole.setScaleOfBalance(address(replacement));

        assertEq(centralConsole.scaleOfBalance(), address(replacement));
        assertTrue(binderData.hasRole(binderData.CONFIG_ROLE(), address(replacement)));
        assertTrue(book0fLife.hasRole(book0fLife.CONFIG_ROLE(), address(replacement)));
        assertFalse(binderData.hasRole(binderData.CONFIG_ROLE(), address(scale)));
        assertFalse(book0fLife.hasRole(book0fLife.CONFIG_ROLE(), address(scale)));
        assertTrue(binderData.hasRole(binderData.CONFIG_ROLE(), address(centralConsole)));
        assertTrue(book0fLife.hasRole(book0fLife.CONFIG_ROLE(), address(centralConsole)));

        replacement.addNewClass(1, "Console Sentinel", 1, _validConfig());
        assertEq(binderData.classVersion(1), 1);
        vm.expectRevert();
        scale.addNewClass(2, "Retired Scale", 1, _validConfig());
    }

    function testConsoleScaleCutoverRevertLeavesRegistryAndRolesUntouched() public {
        centralConsole = new CentralConsole(address(this), address(binderData));
        binderData.grantRole(binderData.CONFIG_ROLE(), address(centralConsole));
        book0fLife.grantRole(book0fLife.CONFIG_ROLE(), address(centralConsole));
        centralConsole.setBook0fLife(address(book0fLife));
        centralConsole.setScaleOfBalance(address(scale));

        BinderData foreignData = new BinderData(address(this), "");
        ScaleOfBalance incompatible = new ScaleOfBalance(address(foreignData), address(book0fLife));
        vm.expectRevert(
            abi.encodeWithSelector(CanonicalPairMismatch.selector, address(binderData), address(foreignData))
        );
        centralConsole.setScaleOfBalance(address(incompatible));

        assertEq(centralConsole.scaleOfBalance(), address(scale));
        assertTrue(binderData.hasRole(binderData.CONFIG_ROLE(), address(scale)));
        assertTrue(book0fLife.hasRole(book0fLife.CONFIG_ROLE(), address(scale)));
    }

    function _validConfig() internal pure returns (binderStructs.ClassConfig memory config) {
        uint8[8] memory minStats = [uint8(10), 10, 10, 10, 10, 10, 10, 10];
        uint8[8] memory maxStats = [uint8(20), 20, 20, 20, 20, 20, 20, 20];
        config = binderStructs.ClassConfig({
            minStats: minStats,
            maxStats: maxStats,
            totalPoints: 20,
            hpPerVit: 10,
            mpPerWis: 5
        });
    }
}
