// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HubStorageWrites} from "test/helpers/HubStorageWrites.sol";
import {InvitationFarm} from "src/InvitationFarm.sol";
import {InvitationModule} from "src/InvitationModule.sol";
import {IModuleManager} from "src/interfaces/IModuleManager.sol";
import {IHub} from "src/interfaces/IHub.sol";

contract InvitationFarmTest is Test, HubStorageWrites {
    uint64 public day;

    uint256 internal gnosisFork;

    InvitationModule public invitationModule;
    InvitationFarm public invitationFarm;

    address farmAdmin = 0x37E17D136BdAc822cEc2cF854de1EFC6E5699c87;
    address farmMaintainer = 0x7b127847f7C5C7dbCA3Cb9c101033791aeDB2B10;
    address seeder = 0x3F8eD746602DEb687b2aD824E65Eaff132123Cc4;
    address originInviter = 0x68e3c2aa468D9a80A8d9Bb8fC53bf072FE98B83a;
    address[] public invitees = [
        address(0xeA90D70a428500B5cA85DCa9792A52a3b852D307),
        0x582f688fAb9BE0053B365556981dEBA8Ba7D4280,
        0x88A42A07A57C47bff00F7c9a23e3a0989A39a5ec,
        0x4246FB4b64Edd3621897008724Ff6df5bf0F3931,
        0xd94Ca9fEb6194F1f65e15a06dE0c2030B2584b3D,
        0x507235c7F41C6164be26472e5cD881436dd0Ce90,
        0x854E9F40a69b74E70cc6eDF0a80cD8511b6136a9,
        0xc7f261Eb23eb9f90257A319780D5c82b768d5a8f,
        0x5d9C264d756c8Ed181dBC10283AE7E98529678c8,
        0x46CA507f05F537537826e756F1c9fA574DAd6A82
    ];

    function setUp() public {
        gnosisFork = vm.createFork(vm.envString("GNOSIS_RPC"));
        vm.selectFork(gnosisFork);
        // deploy contracts
        invitationModule = new InvitationModule();
        vm.prank(farmAdmin);
        invitationFarm = new InvitationFarm(address(invitationModule));

        // set current day
        day = IHub(HUB).day(block.timestamp);
        // create test accounts
        // seeder
        _registerHuman(seeder);
        _simulateSafe(seeder);
        _setCRCBalance(uint256(uint160(seeder)), seeder, day, uint192(1000 ether));
        // origin
        _registerHuman(originInviter);
        _simulateSafe(originInviter);

        // enable invitation module for actors
        vm.prank(seeder);
        IModuleManager(seeder).enableModule(address(invitationModule));
        vm.prank(originInviter);
        IModuleManager(originInviter).enableModule(address(invitationModule));

        // set farm maintainer
        vm.prank(farmAdmin);
        invitationFarm.setMaintainer(farmMaintainer);
        // set farm seeder
        vm.prank(farmAdmin);
        invitationFarm.setSeeder(seeder);

        // seed the farm with the initial 10 bots
        uint256[] memory ids = new uint256[](10);
        ids[0] = uint256(uint160(seeder));
        ids[1] = uint256(uint160(seeder));
        ids[2] = uint256(uint160(seeder));
        ids[3] = uint256(uint160(seeder));
        ids[4] = uint256(uint160(seeder));
        ids[5] = uint256(uint160(seeder));
        ids[6] = uint256(uint160(seeder));
        ids[7] = uint256(uint160(seeder));
        ids[8] = uint256(uint160(seeder));
        ids[9] = uint256(uint160(seeder));
        uint256[] memory values = new uint256[](10);
        values[0] = 96 ether;
        values[1] = 96 ether;
        values[2] = 96 ether;
        values[3] = 96 ether;
        values[4] = 96 ether;
        values[5] = 96 ether;
        values[6] = 96 ether;
        values[7] = 96 ether;
        values[8] = 96 ether;
        values[9] = 96 ether;
        bytes memory data = abi.encode(
            address(invitationFarm), abi.encodeWithSelector(InvitationFarm.createBots.selector, uint256(10))
        );

        vm.prank(seeder);
        IHub(HUB).safeBatchTransferFrom(seeder, address(invitationModule), ids, values, data);

        // make invitees as safes with enabled invitation module
        for (uint256 i; i < 10; i++) {
            address invitee = invitees[i];
            _simulateSafe(invitee);
            vm.prank(invitee);
            IModuleManager(invitee).enableModule(address(invitationModule));
        }
    }

    function testClaimInvites() public {
        // lets move 3 days, so bots have enough CRC minted for an invite
        vm.warp(block.timestamp + 3 days);

        // lets whitelist origin inviter
        vm.prank(farmAdmin);
        invitationFarm.setInviterQuota(originInviter, 10);

        // should be a batch tx
        vm.startPrank(originInviter);
        // this first should be eth_call to compile input for transfer part and later part of the batch tx
        uint256[] memory ids = invitationFarm.claimInvites(10);
        uint256[] memory values = new uint256[](ids.length);
        for (uint256 i; i < values.length; i++) {
            values[i] = 96 ether;
        }

        IHub(HUB).safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, abi.encode(invitees));
        vm.stopPrank();

        for (uint256 k; k < 10; k++) {
            assertTrue(IHub(HUB).isHuman(invitees[k]));
        }
    }

    function testFarmGrow() public {
        // lets move 2 days + 1 hour, so bots have enough CRC to invite same number of bots
        vm.warp(block.timestamp + 2 days + 1 hours);

        assertEq(invitationFarm.totalBots(), 10);
        vm.prank(farmMaintainer);
        invitationFarm.growFarm(10);

        assertEq(invitationFarm.totalBots(), 20);

        address sentinel = address(1);
        address bot = sentinel;
        for (uint256 i; i < 20; i++) {
            bot = invitationFarm.bots(bot);
            assertTrue(IHub(HUB).isHuman(bot));
        }
    }
}
