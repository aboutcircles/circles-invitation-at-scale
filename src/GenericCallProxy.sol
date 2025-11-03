// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

contract GenericCallProxy {
    /*//////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/
    error OnlyModule();
    error GenericCallInvalidEncoding();
    error GenericCallReverted(bytes revertData);

    /*//////////////////////////////////////////////////////////////
                                Immutables
    //////////////////////////////////////////////////////////////*/

    address internal immutable PARENT_MODULE;
    /*//////////////////////////////////////////////////////////////
                                 Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts to Module calls.
    modifier onlyModule() {
        if (msg.sender != PARENT_MODULE) revert OnlyModule();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               Constructor
    //////////////////////////////////////////////////////////////*/

    constructor() {
        PARENT_MODULE = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                         External: Module Facade
    //////////////////////////////////////////////////////////////*/

    function proxyGenericCallReturnInvitee(bytes memory data) external onlyModule returns (address invitee) {
        data = genericCall(data);
        if (data.length != 32) revert GenericCallInvalidEncoding();
        invitee = abi.decode(data, (address));
    }

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
