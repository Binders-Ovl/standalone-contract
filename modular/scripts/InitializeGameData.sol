// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../Book0fLife.sol";
import "../BinderData.sol";
import "../supportContract/binderStructs.sol";

contract InitializeGameData {
    function setup(address bookAddr, address binderAddr) external {
        Book0fLife book0fLife = Book0fLife(bookAddr);
        BinderData binderData = BinderData(binderAddr);

        // === Classes ===
        _addClass(book0fLife, binderData, 1, "Villager", "Common", [5,5,5,5,5,5,5,5], [10,10,10,10,10,10,10,10], 26, 10, 8);
        _addClass(book0fLife, binderData, 2, "Squire", "Uncommon", [8,5,7,6,8,5,6,7], [15,10,12,11,15,10,11,12], 29, 12, 8);
        _addClass(book0fLife, binderData, 3, "Scout", "Uncommon", [5,7,10,10,6,7,10,7], [10,12,18,18,11,12,18,12], 32, 10, 10);
        _addClass(book0fLife, binderData, 4, "Knight", "Rare", [12,6,8,8,12,6,8,10], [20,12,15,15,20,12,15,18], 38, 15, 8);
        _addClass(book0fLife, binderData, 5, "PathFinder", "Rare", [8,10,12,12,8,10,12,8], [15,18,20,20,15,18,20,15], 40, 12, 12);
        _addClass(book0fLife, binderData, 6, "Ranger", "Rare", [8,8,12,12,8,10,12,10], [15,15,20,20,15,18,20,18], 40, 12, 12);

        // === Fusion Recipes ===
        // Recipe: (1,1) -> [2,3] with chances [8000,2000]  
        // Villager + Villager → 80% Squire, 20% Scout
        uint256[] memory outputs = new uint256[](2);
        uint16[] memory chances = new uint16[](2);
        outputs[0] = 2; outputs[1] = 3;
        chances[0] = 8000; chances[1] = 2000;
        _setRecipe(book0fLife, 1, 1, outputs, chances, 7000);

        // Recipe: (2,2) -> [4]
        // Squire + Squire → 100% Knight
        outputs = new uint256[](1);
        chances = new uint16[](1);
        outputs[0] = 4;
        chances[0] = 10000;
        _setRecipe(book0fLife, 2, 2, outputs, chances, 6500);

        // Recipe: (3,3) -> [6]
        // Scout + Scout → 100% Ranger
        outputs = new uint256[](1);
        chances = new uint16[](1);
        outputs[0] = 6;
        chances[0] = 10000;
        _setRecipe(book0fLife, 3, 3, outputs, chances, 6500);

        // Recipe: (2,3) -> [5]
        // Squire + Scout → 100% PathFinder
        outputs = new uint256[](1);
        chances = new uint16[](1);
        outputs[0] = 5;
        chances[0] = 10000;
        _setRecipe(book0fLife, 2, 3, outputs, chances, 6500);
        
    }


    //  === Externals Call Functions ===
    // Extermals Call function for class Addition and Fusion Recipe both gonna interect with Book0fLife and BinderData
    function _addClass(
        Book0fLife book,
        BinderData binder,
        uint256 classId,
        string memory name,
        string memory rarity,
        uint8[8] memory minStats,
        uint8[8] memory maxStats,
        uint16 totalPoints,
        uint16 hpPerVit,
        uint16 mpPerWis
    ) internal {
        binderStructs.ClassConfig memory config = binderStructs.ClassConfig({
            minStats: minStats,
            maxStats: maxStats,
            totalPoints: totalPoints,
            hpPerVit: hpPerVit,
            mpPerWis: mpPerWis
        });
        book.addNewClass(classId, name, rarity, config, 1);
        binder.setClassVersion(classId, 1);
    }

    function _setRecipe(
        Book0fLife book,
        uint256 class1,
        uint256 class2,
        uint256[] memory classIds,
        uint16[] memory multiProbChance,
        uint16 successChance
    ) internal {
        require(
            classIds.length == multiProbChance.length, "Mismatch: output and multiProbChance lengths must match"
        );
        uint256 totalProb = 0;
        for (uint256 i = 0; i < multiProbChance.length; i++) {
            totalProb += multiProbChance[i];
        }
        require(totalProb == 10000, "Invalid: totalProb must be less than or equal to 10000");
        book.setFusionRecipe(class1, class2, classIds, multiProbChance, successChance);
    }
}

/**
    // === Fusion Recipes ===
        _setRecipe(book0fLife, 1, 1, _cr8Outputs([2, 3]), _cr8MultiProbChances([8000, 2000]), 7000);
        _setRecipe(book0fLife, 2, 2, _cr8Outputs([4]), _cr8MultiProbChances([10000]), 6500);
        _setRecipe(book0fLife, 3, 3, _cr8Outputs([6]), _cr8MultiProbChances([10000]), 6500);
        _setRecipe(book0fLife, 2, 3, _cr8Outputs([5]), _cr8MultiProbChances([10000]), 6500);

  // === Internal Helper Functions ===
    // _cr8Outputs and _cr8MultiProbChances are internal helper functions for setting up the fusion recipes. 

    function _cr8Outputs(uint256[] memory input) internal pure returns (uint256[] memory) {
        return input;
    }

    function _cr8MultiProbChances(uint16[] memory input) internal pure returns (uint16[] memory) {
        return input;
    }

 // === Depracated Code Fusion Recipes ===
        { // 1.  Vilalger build Recipe | Villager + Villager → 80% Squire, 20% Scout
            uint256 ;
            uint16 ;
            outputClasses[0] = 2; outputClasses[1] = 3;
            mpc[0] = 8000; mpc[1] = 2000;
            _setRecipe(book0fLife, 1, 1, outputClasses, mpc, 7000);
        }

        { // 2. Squire build Recipe | Squire + Squire → 100% Knight
            uint256 ;
            uint16 ;
            outputClasses[0] = 4;
            mpc[0] = 10000;
            _setRecipe(book0fLife, 2, 2, outputClasses, mpc, 6500);
        }

        { // 3. Scout build Recipe | Scout + Scout → 100% Ranger
            uint256 ;
            uint16 ;
            outputClasses[0] = 6;
            mpc[0] = 10000;
            _setRecipe(book0fLife, 3, 3, outputClasses, mpc, 6500);
        }

        { // 4. Squire x Scout build Recipe | Squire + Scout → 100% PathFinder
            uint256 ;
            uint16 ;
            outputClasses[0] = 5;
            mpc[0] = 10000;
            _setRecipe(book0fLife, 2, 3, outputClasses, mpc, 6500);
        }
    }
*/