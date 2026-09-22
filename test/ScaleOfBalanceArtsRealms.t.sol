// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../modular/BinderData.sol";
import "../modular/shelf/Book0fArts.sol";
import "../modular/shelf/Book0fLife.sol";
import "../modular/shelf/Book0fRealms.sol";
import "../modular/ScaleOfBalance.sol";
import "../modular/supportContract/binderStructs.sol";

contract ScaleOfBalanceArtsRealmsTest is Test {
    Book0fArts internal arts;
    Book0fRealms internal realms;
    ScaleOfBalance internal scale;

    function setUp() public {
        BinderData data = new BinderData(address(this), "");
        scale = new ScaleOfBalance(address(data), address(new Book0fLife()));
        arts = new Book0fArts(address(this));
        realms = new Book0fRealms(address(this));
        arts.setScaleOfBalanceAuthority(address(0), address(scale));
        realms.setScaleOfBalanceAuthority(address(0), address(scale));
        scale.setBook0fArts(address(arts));
        scale.setBook0fRealms(address(realms));
    }

    function testScaleVersionsArtBalanceWithoutConfigAuthority() public {
        binderStructs.ArtDefinition memory art = _art(1);
        uint256[] memory eligibility = new uint256[](1);
        eligibility[0] = 1;
        arts.addArt(art, eligibility);

        art.hpCost = 9;
        scale.updateArtBalance(art, eligibility);

        assertTrue(arts.hasRole(arts.BALANCE_ROLE(), address(scale)));
        assertFalse(arts.hasRole(arts.CONFIG_ROLE(), address(scale)));
        assertEq(arts.getArtDefinitionAtVersion(1, 1).hpCost, 5);
        assertEq(arts.getArtDefinition(1).version, 2);
        assertEq(arts.getArtDefinition(1).hpCost, 9);

        vm.expectRevert(abi.encodeWithSelector(Book0fArts.NoArtBalanceChange.selector, uint32(1)));
        scale.updateArtBalance(art, eligibility);
    }

    function testScaleVersionsTerrainBalanceButRejectsElevationEdits() public {
        binderStructs.MapDefinition memory map =
            binderStructs.MapDefinition({mapId: 1, name: "Arena", width: 2, height: 1, version: 1, enabled: true});
        binderStructs.TileDefinition[] memory tiles = _tiles();
        realms.addMap(map, tiles);

        tiles[0].movementCost = 3;
        scale.updateMapBalance(1, true, tiles);

        assertTrue(realms.hasRole(realms.BALANCE_ROLE(), address(scale)));
        assertFalse(realms.hasRole(realms.CONFIG_ROLE(), address(scale)));
        assertEq(realms.getTile(1, 1, 1).movementCost, 1);
        assertEq(realms.getMap(1).version, 2);
        assertEq(realms.getTile(1, 2, 1).movementCost, 3);

        tiles[0].elevation = 1;
        vm.expectRevert(abi.encodeWithSelector(Book0fRealms.StructuralMapChange.selector, uint32(1)));
        scale.updateMapBalance(1, true, tiles);
    }

    function _art(uint32 artId) private pure returns (binderStructs.ArtDefinition memory art) {
        art.artId = artId;
        art.name = "Slash";
        art.artTypeId = 2;
        art.hpCost = 5;
        art.effectTypeId = 1;
        art.patternTypeId = 1;
        art.range = 1;
        art.primaryFormula.formulaTypeId = 1;
        art.version = 1;
        art.enabled = true;
    }

    function _tiles() private pure returns (binderStructs.TileDefinition[] memory tiles) {
        tiles = new binderStructs.TileDefinition[](2);
        tiles[0] = binderStructs.TileDefinition({
            tileId: 1,
            elevation: 0,
            terrainTypeId: 1,
            terrainFlags: 0,
            walkable: true,
            movementCost: 1
        });
        tiles[1] = binderStructs.TileDefinition({
            tileId: 2,
            elevation: 0,
            terrainTypeId: 1,
            terrainFlags: 0,
            walkable: true,
            movementCost: 1
        });
    }
}
