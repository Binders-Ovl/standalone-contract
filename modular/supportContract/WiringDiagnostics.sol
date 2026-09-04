// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/ICentralConsole.sol";

/// @notice Stateless, read-only safe probe for CentralConsole wiring.
/// @dev Optional dependencies are probed with bounded staticcalls so a bad
/// address reports `false` instead of making diagnostics revert.
contract WiringDiagnostics {
    struct WiringInput {
        address console;
        address binderData;
        address binderSkills;
        address binderMetadata;
        address book0fLife;
        address book0fArts;
        address book0fRealms;
        address binderLogic;
        address fusionMinter;
        address scaleOfBalance;
        address battleFactory;
        uint32 battleFactoryVersion;
        address allegianceRegistry;
    }

    bytes32 private constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 private constant METADATA_REFRESH_ROLE = keccak256("METADATA_REFRESH_ROLE");
    bytes4 private constant BINDER_DATA = bytes4(keccak256("binderData()"));
    bytes4 private constant CENTRAL_CONSOLE = bytes4(keccak256("centralConsole()"));
    bytes4 private constant BINDER_SKILLS = bytes4(keccak256("binderSkills()"));
    bytes4 private constant BOOK_LIFE = bytes4(keccak256("book0fLife()"));
    bytes4 private constant BOOK_ARTS = bytes4(keccak256("book0fArts()"));
    bytes4 private constant METADATA = bytes4(keccak256("binderMetadataAddress()"));
    bytes4 private constant GRAVEYARD = bytes4(keccak256("binderGraveyard()"));
    bytes4 private constant BATTLE_IMPLEMENTATION = bytes4(keccak256("battleImplementation()"));
    bytes4 private constant AUTHORIZED_BATTLE = bytes4(keccak256("authorizedBattleFactory(address)"));
    bytes4 private constant AUTHORIZED_FUSION = bytes4(keccak256("authorizedFusionMinter(address)"));
    bytes4 private constant AUTHORIZED_LOGIC = bytes4(keccak256("authorizedBinderLogic(address)"));
    bytes4 private constant ACTIVITY_CONTROLLER = bytes4(keccak256("getActivityController(uint8)"));
    bytes4 private constant ACCEPTING_REQUESTS = bytes4(keccak256("acceptingRequests()"));
    bytes4 private constant ALLEGIANCE = bytes4(keccak256("allegianceRegistry()"));
    bytes4 private constant HAS_ROLE = bytes4(keccak256("hasRole(bytes32,address)"));

    function collect(WiringInput calldata input) external view returns (ICentralConsole.WiringStatus memory status) {
        _metadata(status, input);
        _bookLife(status, input);
        _battle(status, input);
        _fusionAndLogic(status, input);
        _scaleAndAllegiance(status, input);
    }

    function isFullyWired(ICentralConsole.WiringStatus memory status) external pure returns (bool) {
        return status.binderDataMetadataMatch && status.binderSkillsPairMatch && status.metadataDependenciesMatch
            && status.metadataRefreshAuthorityMatch && status.bookLifeDependenciesMatch && status.book0fRealmsConfigured
            && status.battleFactoryMatch && status.battleFactoryDependenciesMatch && status.battleActivityControllerMatch
            && status.fusionDependenciesMatch && status.fusionActivityControllerMatch
            && status.binderLogicCanonicalAndAccepting && status.scaleDependenciesAndAuthorityMatch
            && status.allegianceDependenciesMatch && status.graveyardConfigured && status.consoleAuthorityMatch;
    }

    function _metadata(ICentralConsole.WiringStatus memory status, WiringInput calldata input) private view {
        status.binderDataMetadataMatch =
            input.binderMetadata != address(0) && _addressMatches(input.binderData, METADATA, input.binderMetadata);
        status.binderSkillsPairMatch = input.binderSkills != address(0)
            && _addressMatches(input.binderSkills, BINDER_DATA, input.binderData)
            && _addressMatches(input.binderSkills, CENTRAL_CONSOLE, input.console);
        status.metadataDependenciesMatch = _metadataDependenciesMatch(input);
        status.metadataRefreshAuthorityMatch = _hasRole(input.binderData, METADATA_REFRESH_ROLE, input.binderSkills);
    }

    function _metadataDependenciesMatch(WiringInput calldata input) private view returns (bool) {
        if (input.binderMetadata == address(0)) return false;
        return _addressMatches(input.binderMetadata, BINDER_DATA, input.binderData)
            && _addressMatches(input.binderMetadata, BINDER_SKILLS, input.binderSkills)
            && _addressMatches(input.binderMetadata, BOOK_LIFE, input.book0fLife)
            && _addressMatches(input.binderMetadata, BOOK_ARTS, input.book0fArts);
    }

    function _bookLife(ICentralConsole.WiringStatus memory status, WiringInput calldata input) private view {
        status.book0fRealmsConfigured = input.book0fRealms.code.length != 0;
        status.bookLifeDependenciesMatch = input.book0fLife != address(0)
            && _optionalAddress(input.fusionMinter, BOOK_LIFE, input.book0fLife)
            && _optionalAddress(input.scaleOfBalance, BOOK_LIFE, input.book0fLife)
            && _optionalAddress(input.binderLogic, BOOK_LIFE, input.book0fLife);
    }

    function _battle(ICentralConsole.WiringStatus memory status, WiringInput calldata input) private view {
        status.battleFactoryMatch =
            input.battleFactory != address(0) && _boolAddress(input.binderData, AUTHORIZED_BATTLE, input.battleFactory);
        (address factoryConsole, bool factoryConsoleOk) = _address(input.battleFactory, CENTRAL_CONSOLE);
        (address implementation, bool implementationOk) = _address(input.battleFactory, BATTLE_IMPLEMENTATION);
        status.battleFactoryDependenciesMatch = input.battleFactory != address(0) && input.battleFactoryVersion != 0
            && factoryConsoleOk && implementationOk && factoryConsole == input.console && implementation.code.length != 0;
        status.battleActivityControllerMatch = input.battleFactory != address(0)
            && _addressUint8(input.binderData, ACTIVITY_CONTROLLER, 1) == input.battleFactory;
    }

    function _fusionAndLogic(ICentralConsole.WiringStatus memory status, WiringInput calldata input) private view {
        status.fusionDependenciesMatch = input.fusionMinter != address(0)
            && _addressMatches(input.fusionMinter, BINDER_DATA, input.binderData)
            && _addressMatches(input.fusionMinter, BOOK_LIFE, input.book0fLife);
        status.fusionActivityControllerMatch = input.fusionMinter != address(0)
            && _boolAddress(input.binderData, AUTHORIZED_FUSION, input.fusionMinter)
            && _addressUint8(input.binderData, ACTIVITY_CONTROLLER, 2) == input.fusionMinter;
        status.binderLogicCanonicalAndAccepting = input.binderLogic != address(0)
            && _boolAddress(input.binderData, AUTHORIZED_LOGIC, input.binderLogic)
            && _bool(input.binderLogic, ACCEPTING_REQUESTS);
    }

    function _scaleAndAllegiance(ICentralConsole.WiringStatus memory status, WiringInput calldata input) private view {
        (address scaleData, bool scaleDataOk) = _address(input.scaleOfBalance, BINDER_DATA);
        (address scaleLife, bool scaleLifeOk) = _address(input.scaleOfBalance, BOOK_LIFE);
        status.scaleDependenciesAndAuthorityMatch = input.scaleOfBalance != address(0) && scaleDataOk && scaleLifeOk
            && scaleData == input.binderData && scaleLife == input.book0fLife
            && _hasConfig(input.binderData, input.scaleOfBalance) && _hasConfig(input.book0fLife, input.scaleOfBalance);
        status.allegianceDependenciesMatch = input.allegianceRegistry != address(0)
            && _optionalAddress(input.book0fLife, ALLEGIANCE, input.allegianceRegistry)
            && _optionalAddress(input.binderLogic, ALLEGIANCE, input.allegianceRegistry);
        (address graveyard, bool graveyardOk) = _address(input.binderData, GRAVEYARD);
        status.graveyardConfigured = graveyardOk && graveyard != address(0);
        status.consoleAuthorityMatch = _hasConfig(input.binderData, input.console)
            && _hasConfig(input.book0fLife, input.console) && _hasConfig(input.binderLogic, input.console);
    }

    function _optionalAddress(address target, bytes4 selector, address expected) private view returns (bool) {
        if (target == address(0)) return true;
        (address value, bool ok) = _address(target, selector);
        return ok && value == expected;
    }

    function _addressMatches(address target, bytes4 selector, address expected) private view returns (bool) {
        (address value, bool ok) = _address(target, selector);
        return ok && value == expected;
    }

    function _hasConfig(address target, address account) private view returns (bool) {
        return _hasRole(target, CONFIG_ROLE, account);
    }

    function _hasRole(address target, bytes32 role, address account) private view returns (bool) {
        if (target.code.length == 0) return false;
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSelector(HAS_ROLE, role, account));
        return ok && data.length >= 32 && abi.decode(data, (bool));
    }

    function _boolAddress(address target, bytes4 selector, address argument) private view returns (bool) {
        if (target.code.length == 0) return false;
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSelector(selector, argument));
        return ok && data.length >= 32 && abi.decode(data, (bool));
    }

    function _bool(address target, bytes4 selector) private view returns (bool) {
        if (target.code.length == 0) return false;
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSelector(selector));
        return ok && data.length >= 32 && abi.decode(data, (bool));
    }

    function _addressUint8(address target, bytes4 selector, uint8 argument) private view returns (address) {
        return _addressCall(target, abi.encodeWithSelector(selector, argument));
    }

    function _address(address target, bytes4 selector) private view returns (address value, bool ok) {
        if (target.code.length == 0) return (address(0), false);
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSelector(selector));
        if (!success || data.length < 32) return (address(0), false);
        return (abi.decode(data, (address)), true);
    }

    function _addressCall(address target, bytes memory callData) private view returns (address) {
        if (target.code.length == 0) return address(0);
        (bool success, bytes memory data) = target.staticcall(callData);
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }
}
