// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../modular/BinderData.sol";
import "../modular/Book0fLife.sol";
import "../modular/Book0fArts.sol";
import "../modular/Book0fRealms.sol";
import "../modular/supportContract/CentralConsole.sol";
import "../modular/supportContract/binderStructs.sol";

contract BooksMigrationTest is Test {
    Book0fLife internal lifeV1;
    Book0fArts internal arts;
    Book0fRealms internal realms;

    function setUp() public {
        lifeV1 = new Book0fLife();
        arts = new Book0fArts(address(this));
        realms = new Book0fRealms(address(this));
    }

    function testBook0fLifePaginatesVersionsDeprecatesSafelyAndMigrates() public {
        binderStructs.ClassConfig memory v1Config = _classConfig(1, 2, 4);
        binderStructs.ClassConfig memory v2Config = _classConfig(2, 4, 7);
        lifeV1.registerRarity(1, "Common");
        lifeV1.registerRarity(2, "Rare");
        lifeV1.addNewClass(1, "Knight", 1, v1Config, 1);
        lifeV1.addNewClass(2, "Mage", 2, v1Config, 1);
        lifeV1.upgradeClassConfig(1, v2Config.totalPoints, v2Config.minStats, v2Config.maxStats, 10, 10, 2);
        lifeV1.setClassAcquisitionFlags(1, lifeV1.ACQ_NORMAL_MINT() | lifeV1.ACQ_FUSION());
        lifeV1.assignClassToNation(1, 0);

        uint256[] memory outcomes = new uint256[](1);
        uint16[] memory weights = new uint16[](1);
        outcomes[0] = 2;
        weights[0] = 10_000;
        lifeV1.setFusionRecipe(1, 2, outcomes, weights, 8_000);

        assertEq(lifeV1.getRarityCount(), 2);
        assertEq(lifeV1.getRarityIds(1, 3)[0], 2);
        assertEq(lifeV1.getClassCount(), 2);
        assertEq(lifeV1.getClassIds(1, 3)[0], 2);
        assertEq(lifeV1.getClassVersionCount(1), 2);
        assertEq(lifeV1.getClassVersions(1, 1, 3)[0], 2);
        assertEq(lifeV1.getFusionPairCount(), 1);

        lifeV1.removeClass(2);
        assertFalse(lifeV1.isClassEnabled(2));
        assertEq(lifeV1.getClassName(2), "Mage");
        assertFalse(lifeV1.hasClassAcquisition(2, lifeV1.ACQ_FUSION()));
        lifeV1.setClassEnabled(2, true);

        Book0fLife lifeV2 = new Book0fLife();
        uint8[] memory rarityIds = new uint8[](2);
        string[] memory rarityNames = new string[](2);
        rarityIds[0] = 1;
        rarityIds[1] = 2;
        rarityNames[0] = "Common";
        rarityNames[1] = "Rare";
        lifeV2.importRarities(rarityIds, rarityNames);

        Book0fLife.ClassImport[] memory classes = new Book0fLife.ClassImport[](2);
        classes[0] = Book0fLife.ClassImport({
            classId: 1,
            name: "Knight",
            rarityId: 1,
            config: v1Config,
            version: 1,
            enabled: true,
            acquisitionFlags: lifeV1.getClassAcquisitionFlags(1)
        });
        classes[1] = Book0fLife.ClassImport({
            classId: 2,
            name: "Mage",
            rarityId: 2,
            config: v1Config,
            version: 1,
            enabled: true,
            acquisitionFlags: 0
        });
        lifeV2.importClasses(classes);

        uint16[] memory versions = new uint16[](1);
        binderStructs.ClassConfig[] memory configs = new binderStructs.ClassConfig[](1);
        versions[0] = 2;
        configs[0] = v2Config;
        lifeV2.importClassVersions(1, versions, configs);

        uint256[] memory classIds = new uint256[](1);
        uint8[][] memory memberships = new uint8[][](1);
        classIds[0] = 1;
        memberships[0] = new uint8[](1);
        memberships[0][0] = 0;
        lifeV2.importClassNationMemberships(classIds, memberships);

        Book0fLife.FusionRecipeImport[] memory recipes = new Book0fLife.FusionRecipeImport[](1);
        recipes[0] = Book0fLife.FusionRecipeImport({
            class1: 1,
            class2: 2,
            outcomeClassIds: outcomes,
            outcomeWeights: weights,
            successChance: 8_000
        });
        lifeV2.importFusionRecipes(recipes);

        assertEq(lifeV2.getClassCount(), lifeV1.getClassCount());
        assertEq(lifeV2.getClassConfigAtVersion(1, 2).totalPoints, v2Config.totalPoints);
        assertEq(lifeV2.getClassesByNationRarity(0, 1)[0], 1);
        assertEq(lifeV2.getFusionRecipe(1, 2).successChance, 8_000);
        assertEq(_lifeHash(lifeV1, 1), _lifeHash(lifeV2, 1));

        BinderData binderData = new BinderData(address(this), "");
        CentralConsole centralConsole = new CentralConsole(address(this), address(binderData));
        binderData.grantRole(binderData.CONFIG_ROLE(), address(centralConsole));
        centralConsole.setBook0fLife(address(lifeV1));
        centralConsole.setBook0fLife(address(lifeV2));
        assertEq(centralConsole.book0fLife(), address(lifeV2));
        assertEq(lifeV1.getClassName(1), "Knight");
    }

    function testBook0fArtsVersionsEligibilityAndDisable() public {
        binderStructs.ArtDefinition memory definition = _artDefinition(101, 1, true, "Firebolt");
        uint256[] memory eligibility = new uint256[](2);
        eligibility[0] = 1;
        eligibility[1] = 2;
        arts.addArt(definition, eligibility);

        assertEq(arts.getArtCount(), 1);
        assertEq(arts.getArtIds(0, 10)[0], 101);
        assertTrue(arts.isArtEnabled(101));
        assertTrue(arts.isClassEligible(101, 1, 1));
        assertFalse(arts.isClassEligible(101, 1, 3));
        assertEq(arts.getArtDefinitionAtVersion(101, 1).primaryFormula.terms[0].coefficientBps, 7_000);

        definition.version = 2;
        definition.name = "Firebolt+";
        eligibility = new uint256[](1);
        eligibility[0] = 2;
        arts.updateArt(definition, eligibility);
        arts.setArtEnabled(101, false, 3);

        assertEq(arts.getArtVersionCount(101), 3);
        assertEq(arts.getArtVersions(101, 1, 3)[0], 2);
        assertEq(arts.getArtDefinitionAtVersion(101, 1).name, "Firebolt");
        assertEq(arts.getArtDefinitionAtVersion(101, 2).name, "Firebolt+");
        assertFalse(arts.isArtEnabled(101));
        assertTrue(arts.isClassEligible(101, 3, 2));
    }

    function testBook0fRealmsVersionedTilesCoordinatesAndCastleBinding() public {
        binderStructs.MapDefinition memory mapV1 =
            binderStructs.MapDefinition({mapId: 7, name: "Libeli Keep", width: 2, height: 2, version: 1, enabled: true});
        binderStructs.TileDefinition[] memory v1Tiles = _tiles(2);
        realms.addMap(mapV1, v1Tiles);
        realms.setCastleMap(77, 7);

        (uint16 internalX, uint16 internalY, int16 internalZ) = realms.getInternalCoordinates(7, 1, 1);
        assertEq(internalX, 0);
        assertEq(internalY, 0);
        assertEq(internalZ, 2);
        (uint16 displayX, uint16 displayY, int16 displayZ) = realms.getDisplayCoordinates(7, 1, 1);
        assertEq(displayX, 1);
        assertEq(displayY, 1);
        assertEq(displayZ, 2);
        assertFalse(realms.isWalkable(7, 1, 2));
        assertEq(realms.getTiles(7, 1, 2, 8).length, 2);
        assertEq(realms.getCastleMap(77), 7);

        binderStructs.MapDefinition memory mapV2 = mapV1;
        mapV2.version = 2;
        mapV2.name = "Libeli Keep Rebuilt";
        binderStructs.TileDefinition[] memory v2Tiles = _tiles(5);
        realms.updateMapVersion(mapV2, v2Tiles);
        realms.setMapEnabled(7, false);

        assertEq(realms.getMapVersionCount(7), 2);
        assertEq(realms.getMapAtVersion(7, 1).name, "Libeli Keep");
        assertEq(realms.getTile(7, 1, 1).elevation, 2);
        assertEq(realms.getTile(7, 2, 1).elevation, 5);
        assertFalse(realms.getMap(7).enabled);
        assertTrue(realms.getMapAtVersion(7, 2).enabled);

        Book0fRealms realmsV2 = new Book0fRealms(address(this));
        binderStructs.MapDefinition[] memory maps = new binderStructs.MapDefinition[](1);
        binderStructs.TileDefinition[][] memory mapTiles = new binderStructs.TileDefinition[][](1);
        maps[0] =
            binderStructs.MapDefinition({mapId: 7, name: "Libeli Keep", width: 2, height: 2, version: 1, enabled: true});
        mapTiles[0] = v1Tiles;
        realmsV2.importMapVersions(maps, mapTiles);
        assertEq(realmsV2.getMapCount(), 1);
        assertEq(realmsV2.getTile(7, 1, 1).elevation, 2);
    }

    function _classConfig(uint8 minValue, uint8 maxValue, uint16 totalPoints)
        internal
        pure
        returns (binderStructs.ClassConfig memory config)
    {
        uint8[8] memory minStats = [minValue, minValue, minValue, minValue, minValue, minValue, minValue, minValue];
        uint8[8] memory maxStats = [maxValue, maxValue, maxValue, maxValue, maxValue, maxValue, maxValue, maxValue];
        config = binderStructs.ClassConfig({
            minStats: minStats,
            maxStats: maxStats,
            totalPoints: totalPoints,
            hpPerVit: 10,
            mpPerWis: 10
        });
    }

    function _artDefinition(uint32 artId, uint16 version, bool enabled, string memory name)
        internal
        pure
        returns (binderStructs.ArtDefinition memory definition)
    {
        definition.artId = artId;
        definition.name = name;
        definition.artTypeId = 2;
        definition.mpCost = 5;
        definition.effectTypeId = 1;
        definition.patternTypeId = 1;
        definition.range = 3;
        definition.primaryFormula.formulaTypeId = 1;
        definition.primaryFormula.termCount = 1;
        definition.primaryFormula.terms[0] = binderStructs.FormulaTerm({sourceId: 1, statId: 1, coefficientBps: 7_000});
        definition.version = version;
        definition.enabled = enabled;
    }

    function _tiles(int16 elevation) internal pure returns (binderStructs.TileDefinition[] memory tiles) {
        tiles = new binderStructs.TileDefinition[](4);
        tiles[0] = binderStructs.TileDefinition({
            tileId: 1,
            elevation: elevation,
            terrainTypeId: 1,
            terrainFlags: 0,
            walkable: true,
            movementCost: 1
        });
        tiles[1] = binderStructs.TileDefinition({
            tileId: 2,
            elevation: elevation,
            terrainTypeId: 2,
            terrainFlags: 1,
            walkable: false,
            movementCost: 0
        });
        tiles[2] = binderStructs.TileDefinition({
            tileId: 3,
            elevation: elevation,
            terrainTypeId: 1,
            terrainFlags: 0,
            walkable: true,
            movementCost: 2
        });
        tiles[3] = binderStructs.TileDefinition({
            tileId: 4,
            elevation: elevation,
            terrainTypeId: 1,
            terrainFlags: 0,
            walkable: true,
            movementCost: 1
        });
    }

    function _lifeHash(Book0fLife book, uint256 classId) internal view returns (bytes32) {
        binderStructs.ClassConfig memory config = book.getClassConfig(classId);
        return keccak256(
            abi.encode(
                classId,
                book.getClassName(classId),
                book.getClassRarityId(classId),
                config.minStats,
                config.maxStats,
                config.totalPoints,
                config.hpPerVit,
                config.mpPerWis,
                book.getClassVersion(classId),
                book.getClassAcquisitionFlags(classId)
            )
        );
    }
}
