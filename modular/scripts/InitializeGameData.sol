// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../AllegianceRegistry.sol";
import "../Book0fLife.sol";
import "../BinderData.sol";
import "../supportContract/binderStructs.sol";

/// @notice Development/pre-production configuration helper.
/// @dev This contract must hold Book0fLife CONFIG_ROLE and BinderData CONFIG_ROLE before setup is called.
contract InitializeGameData {
    function setup(address bookAddr, address binderAddr, address allegianceRegistryAddr) external {
        Book0fLife book0fLife = Book0fLife(bookAddr);
        BinderData binderData = BinderData(binderAddr);
        AllegianceRegistry allegianceRegistry = AllegianceRegistry(allegianceRegistryAddr);

        // AllegianceRegistry constructor creates the initial active nations. Keep the setup
        // explicit so a wrong deployment address cannot silently receive pool assignments.
        require(_same(allegianceRegistry.getNationName(1), "Weatonia"), "Nation 1 mismatch");
        require(_same(allegianceRegistry.getNationName(2), "Mitrevar"), "Nation 2 mismatch");
        require(_same(allegianceRegistry.getNationName(3), "Urtaka"), "Nation 3 mismatch");
        book0fLife.setAllegianceRegistry(allegianceRegistryAddr);

        _registerInitialRarities(book0fLife);

        // General members guarantee an unregistered wallet has one candidate per
        // enabled default rarity. The other classes demonstrate dedicated pools.
        _addClass(book0fLife, binderData, 1, "Villager", 1, [5,5,5,5,5,5,5,5], [10,10,10,10,10,10,10,10], 26, 10, 8, 0);
        _addClass(book0fLife, binderData, 2, "Squire", 2, [8,5,7,6,8,5,6,7], [15,10,12,11,15,10,11,12], 29, 12, 8, 0);
        _addClass(book0fLife, binderData, 3, "Scout", 2, [5,7,10,10,6,7,10,7], [10,12,18,18,11,12,18,12], 32, 10, 10, 2);
        _addClass(book0fLife, binderData, 4, "Knight", 3, [12,6,8,8,12,6,8,10], [20,12,15,15,20,12,15,18], 38, 15, 8, 0);
        _addClass(book0fLife, binderData, 5, "PathFinder", 3, [8,10,12,12,8,10,12,8], [15,18,20,20,15,18,20,15], 40, 12, 12, 1);
        _addClass(book0fLife, binderData, 6, "Ranger", 3, [8,8,12,12,8,10,12,10], [15,15,20,20,15,18,20,18], 40, 12, 12, 3);

        uint256[] memory outputs = new uint256[](2);
        uint16[] memory chances = new uint16[](2);
        outputs[0] = 2; outputs[1] = 3;
        chances[0] = 8000; chances[1] = 2000;
        _setRecipe(book0fLife, 1, 1, outputs, chances, 7000);

        outputs = new uint256[](1);
        chances = new uint16[](1);
        outputs[0] = 4; chances[0] = 10000;
        _setRecipe(book0fLife, 2, 2, outputs, chances, 6500);

        outputs[0] = 6;
        _setRecipe(book0fLife, 3, 3, outputs, chances, 6500);

        outputs[0] = 5;
        _setRecipe(book0fLife, 2, 3, outputs, chances, 6500);
    }

    /// @notice Performs the post-setup runtime role wiring.
    /// @dev Call only after `setup`. This helper contract must hold DEFAULT_ADMIN_ROLE
    /// on Book0fLife and BinderData; grant it that authority temporarily when using a scripted deployment.
    function configureRuntimeRoles(
        address bookAddr,
        address binderAddr,
        address binderLogicAddr,
        address fusionMinterAddr,
        address scaleOfBalanceAddr
    ) external {
        require(
            bookAddr != address(0) && binderAddr != address(0) && binderLogicAddr != address(0)
                && fusionMinterAddr != address(0) && scaleOfBalanceAddr != address(0),
            "Invalid address"
        );
        Book0fLife book0fLife = Book0fLife(bookAddr);
        BinderData binderData = BinderData(binderAddr);
        binderData.grantRole(binderData.MINTER_ROLE(), binderLogicAddr);
        binderData.grantRole(binderData.FUSION_ROLE(), fusionMinterAddr);
        binderData.grantRole(binderData.CONFIG_ROLE(), scaleOfBalanceAddr);
        book0fLife.changeFusionMinterRole(fusionMinterAddr);
        book0fLife.changeConfigRole(scaleOfBalanceAddr);
    }

    function _registerInitialRarities(Book0fLife book) internal {
        book.registerRarity(1, "Common");
        book.registerRarity(2, "Uncommon");
        book.registerRarity(3, "Rare");
        book.registerRarity(4, "Epic");
        book.registerRarity(5, "Legend");
    }

    function _addClass(
        Book0fLife book,
        BinderData binder,
        uint256 classId,
        string memory name,
        uint8 rarityId,
        uint8[8] memory minStats,
        uint8[8] memory maxStats,
        uint16 totalPoints,
        uint16 hpPerVit,
        uint16 mpPerWis,
        uint8 nationId
    ) internal {
        binderStructs.ClassConfig memory config = binderStructs.ClassConfig({
            minStats: minStats,
            maxStats: maxStats,
            totalPoints: totalPoints,
            hpPerVit: hpPerVit,
            mpPerWis: mpPerWis
        });
        book.addNewClass(classId, name, rarityId, config, 1);
        binder.setClassVersion(classId, 1);
        book.setClassAcquisitionFlags(classId, book.ACQ_NORMAL_MINT() | book.ACQ_FUSION());
        book.assignClassToNation(classId, nationId);
    }

    function _setRecipe(
        Book0fLife book,
        uint256 class1,
        uint256 class2,
        uint256[] memory classIds,
        uint16[] memory multiProbChance,
        uint16 successChance
    ) internal {
        book.setFusionRecipe(class1, class2, classIds, multiProbChance, successChance);
    }

    function _same(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
