// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IInvitationFarm} from "src/interfaces/IInvitationFarm.sol";

contract InvitationBot {
    /*//////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/
    error OnlyFarmOrModule();
    error OnlyHub();
    error InvalidCRCId();

    /*//////////////////////////////////////////////////////////////
                              Constants & Immutables
    //////////////////////////////////////////////////////////////*/

    /// @notice Circles v2 Hub.
    address internal HUB = address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8);
    address internal immutable INVITATION_FARM;

    /*//////////////////////////////////////////////////////////////
                                 Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts to Module calls.
    modifier onlyFarmOrModule() {
        if (msg.sender != INVITATION_FARM && msg.sender != IInvitationFarm(INVITATION_FARM).invitationModule()) {
            revert OnlyFarmOrModule();
        }
        _;
    }

    /// @notice Restricts to Hub callbacks.
    modifier onlyHub() {
        if (msg.sender != HUB) revert OnlyHub();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               Constructor
    //////////////////////////////////////////////////////////////*/

    constructor() {
        INVITATION_FARM = msg.sender;
    }

    function isModuleEnabled(address) external pure returns (bool) {
        return true;
    }

    function execTransactionFromModuleReturnData(address to, uint256 value, bytes memory data, uint8)
        external
        onlyFarmOrModule
        returns (bool success, bytes memory returnData)
    {
        assembly {
            success := call(gas(), to, value, add(data, 0x20), mload(data), 0, 0)
            // Load free memory location
            let ptr := mload(0x40)
            // We allocate memory for the return data by setting the free memory location to
            // current free memory location + data size + 32 bytes for data size value
            mstore(0x40, add(ptr, add(returndatasize(), 0x20)))
            // Store the size
            mstore(ptr, returndatasize())
            // Store the data
            returndatacopy(add(ptr, 0x20), 0, returndatasize())
            // Point the return data to the correct memory location
            returnData := ptr
        }
    }

    function onERC1155Received(address, address, uint256 id, uint256, bytes memory)
        external
        view
        onlyHub
        returns (bytes4)
    {
        if (id != uint256(uint160(address(this)))) revert InvalidCRCId();
        return this.onERC1155Received.selector;
    }
}
