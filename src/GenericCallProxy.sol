// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

/// @title GenericCallProxy
/// @notice Minimal proxy that executes an arbitrary call and returns the raw bytes,
///         with convenience facades that decode invitee address(es) for the parent module.
/// @dev Deployed by a single parent module which is then the only authorized caller.
///      Expects inputs encoded as `abi.encode(address target, bytes callData)`.
contract GenericCallProxy {
    /*//////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/

    /// @dev Thrown when a caller other than the parent module invokes a restricted function.
    error OnlyModule();

    /// @dev Thrown when the returned data from the generic call does not match the expected ABI shape/length.
    error GenericCallInvalidEncoding();

    /// @dev Thrown when the low-level call to `target` reverts; bubbles up the original revert data.
    /// @param revertData The raw revert payload returned by the target call.
    error GenericCallReverted(bytes revertData);

    /*//////////////////////////////////////////////////////////////
                                Immutables
    //////////////////////////////////////////////////////////////*/

    /// @notice The parent module that deployed this proxy and is authorized to use it.
    /// @dev Set once in the constructor to `msg.sender`.
    address internal immutable PARENT_MODULE;

    /*//////////////////////////////////////////////////////////////
                                 Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts function access to the parent module only.
    /// @dev Reverts with {OnlyModule} if `msg.sender` is not `PARENT_MODULE`.
    modifier onlyModule() {
        if (msg.sender != PARENT_MODULE) revert OnlyModule();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               Constructor
    //////////////////////////////////////////////////////////////*/

    /// @notice Records the deploying parent module as the sole authorized caller.
    /// @dev `PARENT_MODULE` is set to `msg.sender`.
    constructor() {
        PARENT_MODULE = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                         External: Module Facade
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a generic call and decodes a single invitee address from the return data.
    /// @dev
    /// - Input must be `abi.encode(address target, bytes callData)`.
    /// - The target’s return data must be exactly 32 bytes (ABI-encoded `address`).
    /// - Reverts with {GenericCallInvalidEncoding} if the returned length is not 32.
    /// - Reverts with {GenericCallReverted} if the target call fails.
    /// @param data Encoded `(target, callData)` payload.
    /// @return invitee The decoded `address` returned by the target.
    function proxyGenericCallReturnInvitee(bytes memory data) external onlyModule returns (address invitee) {
        data = genericCall(data);
        if (data.length != 32) revert GenericCallInvalidEncoding();
        invitee = abi.decode(data, (address));
    }

    /// @notice Executes a generic call and decodes an array of invitee addresses from the return data.
    /// @dev
    /// - Input must be `abi.encode(address target, bytes callData)`.
    /// - The target’s return data must be a dynamic `address[]` whose ABI-encoded length is `(numberOfInvitees + 2) * 32`
    ///   (32 bytes offset + 32 bytes array length + `n * 32` bytes elements).
    /// - Reverts with {GenericCallInvalidEncoding} if the returned length does not match the expected size.
    /// - Reverts with {GenericCallReverted} if the target call fails.
    /// @param data Encoded `(target, callData)` payload.
    /// @param numberOfInvitees The expected number of addresses; used to sanity-check the ABI payload size.
    /// @return invitees The decoded `address[]` returned by the target.
    function proxyGenericCallReturnInvitees(bytes memory data, uint256 numberOfInvitees)
        external
        onlyModule
        returns (address[] memory invitees)
    {
        data = genericCall(data);
        if (data.length != (numberOfInvitees + 2) * 32) revert GenericCallInvalidEncoding();
        invitees = abi.decode(data, (address[]));
    }

    /*//////////////////////////////////////////////////////////////
                      Internal: Generic Call Primitive
    //////////////////////////////////////////////////////////////*/

    /// @notice Performs a low-level call to a target and returns the raw bytes.
    /// @dev
    /// - `data` must be `abi.encode(address target, bytes callData)`.
    /// - Returns the raw `returnedData` from `target.call(callData)`.
    /// - Reverts with {GenericCallReverted} and bubbles the target's revert payload on failure.
    /// @param data Encoded tuple `(target, callData)` for execution.
    /// @return returnedData The raw bytes returned by the target call.
    function genericCall(bytes memory data) internal returns (bytes memory returnedData) {
        // expected encoding:
        // bytes memory data = abi.encode(address(target), abi.encodeWithSelector(bytes4, arg));
        // decodes into:
        (address target, bytes memory callData) = abi.decode(data, (address, bytes));
        bool success;
        (success, returnedData) = target.call(callData);
        if (!success) revert GenericCallReverted(returnedData);
    }
}
