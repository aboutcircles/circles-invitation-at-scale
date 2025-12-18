// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

contract FakeSafeAlwaysFalse {
    function isModuleEnabled(address) external view returns (bool) {
        return true;
    }

    function execTransactionFromModuleReturnData(address to, uint256 value, bytes memory data, uint8 operation)
        external
        returns (bool success, bytes memory returnData)
    {
        return (false, abi.encodePacked(msg.sender));
    }
}

// A fake safe that doesn't do the actual call but pass the check
contract FakeSafeAlwaysTrue {
    function isModuleEnabled(address) external view returns (bool) {
        return true;
    }

    function execTransactionFromModuleReturnData(address to, uint256 value, bytes memory data, uint8 operation)
        external
        returns (bool success, bytes memory returnData)
    {
        return (true, "0x");
    }

    function onERC1155Received(address, address from, uint256 id, uint256 value, bytes memory data)
        external
        returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }
}
