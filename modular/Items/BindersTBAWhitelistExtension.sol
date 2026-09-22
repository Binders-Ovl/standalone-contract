// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IERC6551Registry.sol";
import "../interfaces/IBinderData.sol";
import "../interfaces/IBindersTBA.sol";

/// @notice V5 whitelist extension that accepts only this collection's deterministic Binder TBAs.
contract BindersTBAWhitelistExtension {
    IERC6551Registry public immutable registry;
    address public immutable implementation;
    address public immutable binderData;
    bytes32 public immutable salt;

    constructor(address registryAddress, address implementationAddress, address binderDataAddress, bytes32 salt_) {
        registry = IERC6551Registry(registryAddress);
        implementation = implementationAddress;
        binderData = binderDataAddress;
        salt = salt_;
    }

    function isWhitelisted(address, address account) external view returns (bool) {
        if (account.code.length == 0) return false;
        try IBindersTBA(account).token() returns (uint256 chainId, address tokenContract, uint256 tokenId) {
            if (chainId != block.chainid || tokenContract != binderData) return false;
            try IBinderData(binderData).ownerOf(tokenId) returns (address) {}
            catch {
                return false;
            }
            return registry.account(implementation, salt, chainId, tokenContract, tokenId) == account;
        } catch {
            return false;
        }
    }
}
