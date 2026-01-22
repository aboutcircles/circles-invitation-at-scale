// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HubStorageWrites} from "test/helpers/HubStorageWrites.sol";
import {InvitationFarm} from "src/InvitationFarm.sol";
import {InvitationModule} from "src/InvitationModule.sol";
import {IModuleManager} from "src/interfaces/IModuleManager.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {CirclesV2Setup} from "test/helpers/CirclesV2Setup.sol";

contract InvitationFarmTest is CirclesV2Setup, HubStorageWrites {
    uint64 public day;

    uint256 internal gnosisFork;

    InvitationModule public invitationModule;
    InvitationFarm public invitationFarm;

    address farmAdmin = makeAddr("farmAdmin");
    address farmMaintainer = makeAddr("farmMaintainer");
    address seeder = makeAddr("seeder");
    address originInviter = makeAddr("originInviter");
    address[] public invitees = [
        makeAddr("invitee1"),
        makeAddr("invitee2"),
        makeAddr("invitee3"),
        makeAddr("invitee4"),
        makeAddr("invitee5"),
        makeAddr("invitee6"),
        makeAddr("invitee7"),
        makeAddr("invitee8"),
        makeAddr("invitee9"),
        makeAddr("invitee10")
    ];

    function setUp() public override {
        super.setUp();
        vm.warp(INVITATION_ONLY_TIME + 1);
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

    function testAdminAccessControl(
        address newAdmin,
        address newSeeder,
        address newMaintainer,
        address inviter,
        uint256 quota
    ) public {
        vm.prank(invitationFarm.admin());
        vm.expectEmit();
        emit InvitationFarm.AdminSet(newAdmin);
        invitationFarm.setAdmin(newAdmin);
        assertEq(invitationFarm.admin(), newAdmin);

        vm.startPrank(newAdmin);
        _registerHuman(newSeeder);
        vm.expectEmit();
        emit InvitationFarm.SeederSet(newSeeder);
        invitationFarm.setSeeder(newSeeder);

        vm.expectEmit();
        emit InvitationFarm.MaintainerSet(newMaintainer);
        invitationFarm.setMaintainer(newMaintainer);

        _registerHuman(inviter);
        vm.expectEmit();
        emit InvitationFarm.InviterQuotaUpdated(inviter, quota);
        invitationFarm.setInviterQuota(inviter, quota);

        address newInvitationModule = address(new InvitationModule());
        address genericCallProxy = address(InvitationModule(newInvitationModule).GENERIC_CALL_PROXY());

        vm.expectEmit();
        emit InvitationFarm.InvitationModuleUpdated(newInvitationModule, genericCallProxy);
        invitationFarm.updateInvitationModule(newInvitationModule);

        vm.stopPrank();
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

    // TODO
    // 1. When invitee is not registered as Human
    // 2. When bot minting fail
    // 3. When the Inviter or Invitee fund is drained / not being transferred correctly
}
