// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IInvitationFarm} from "src/interfaces/IInvitationFarm.sol";

/// @title InvitationBot
/// @notice Minimal invitation bot used by an Invitation Farm to interact with the Circles Hub
///         and receive its own CRC tokens.
/// @dev
/// - Privileged calls are allowed only from the Invitation Farm and its Module.
/// - Accepts ERC-1155 callbacks only of its own CRC id.
/// - `isModuleEnabled` is provided for compatibility with Safe-style module checks
///   and always returns `true` for this bot.
/// - The low-level executor forwards all remaining gas and returns raw returndata.
contract InvitationBot {
    /*//////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a function restricted to the Invitation Farm or its Module
    ///         is called by any other address.
    error OnlyFarmOrModule();

    /// @notice Thrown when a function restricted to the Circles Hub is called by
    ///         any other address.
    error OnlyHub();

    /// @notice Thrown when the received ERC-1155 token id does not match
    ///         `uint256(uint160(address(this)))`.
    error InvalidCRCId();

    /*//////////////////////////////////////////////////////////////
                              Constants & Immutables
    //////////////////////////////////////////////////////////////*/

    /// @notice Circles v2 Hub address that is authorized to invoke ERC-1155 callbacks.
    address internal constant HUB = address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8);

    /// @notice Invitation Farm that deployed and owns this bot instance.
    /// @dev Set once during construction to the deployer (`msg.sender`) and never changed.
    address internal immutable INVITATION_FARM;

    /*//////////////////////////////////////////////////////////////
                                 Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts execution to either the Invitation Farm or its Invitation Module.
    /// @dev The module address is resolved via `IInvitationFarm(INVITATION_FARM).invitationModule()`.
    ///      Reverts with {OnlyFarmOrModule} if the caller is not authorized.
    modifier onlyFarmOrModule() {
        if (msg.sender != INVITATION_FARM && msg.sender != IInvitationFarm(INVITATION_FARM).invitationModule()) {
            revert OnlyFarmOrModule();
        }
        _;
    }

    /// @notice Restricts execution to the Circles v2 Hub.
    /// @dev Reverts with {OnlyHub} if `msg.sender` is not `HUB`.
    modifier onlyHub() {
        if (msg.sender != HUB) revert OnlyHub();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               Constructor
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the bot and binds it to the deploying Invitation Farm.
    /// @dev Sets {INVITATION_FARM} to `msg.sender`.
    constructor() {
        INVITATION_FARM = msg.sender;
    }

    /// @notice Reports whether a module is enabled for this bot.
    /// @dev Exists for Safe-compatible interfaces; always returns `true`.
    /// @return Always `true`.
    function isModuleEnabled(address) external pure returns (bool) {
        return true;
    }

    /// @notice Executes a low-level call and returns the success flag and raw returndata.
    /// @dev
    /// - Callable only by the Invitation Farm or its Module (see {onlyFarmOrModule}).
    /// - Forwards all remaining gas to the target.
    /// - Uses inline assembly to bubble up returndata without decoding.
    /// - The `uint8` parameter is accepted for interface compatibility and is unused.
    /// @param to The target contract address to call.
    /// @param value The amount of ETH (in wei) to forward with the call.
    /// @param data ABI-encoded calldata to send to the target.
    /// @return success `true` if the call did not revert, `false` otherwise.
    /// @return returnData The raw bytes returned by the target call (empty if none).
    function execTransactionFromModuleReturnData(address to, uint256 value, bytes memory data, uint8)
        external
        onlyFarmOrModule
        returns (bool success, bytes memory returnData)
    {
        assembly {
            success := call(gas(), to, value, add(data, 0x20), mload(data), 0, 0)
            // Load free memory location
            let ptr := mload(0x40)
            // Allocate memory for the return data (length slot + data)
            mstore(0x40, add(ptr, add(returndatasize(), 0x20)))
            // Store the length
            mstore(ptr, returndatasize())
            // Copy returndata
            returndatacopy(add(ptr, 0x20), 0, returndatasize())
            // Set return pointer
            returnData := ptr
        }
    }

    /// @notice ERC-1155 single token reception hook.
    /// @dev
    /// - Only the Circles v2 Hub may invoke this function (see {onlyHub}).
    /// - Accepts the token transfer only if `id == uint256(uint160(address(this)))`.
    /// - Returns the function selector to signal acceptance.
    /// @param id The ERC-1155 token id being received; must equal this bot's CRC id.
    /// @return The selector `IERC1155Receiver.onERC1155Received.selector` to accept the transfer.
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
