// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {HubStorageWrites} from "test/helpers/HubStorageWrites.sol";
import {IModuleManager} from "src/interfaces/IModuleManager.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {InvitationModule} from "src/InvitationModule.sol";

contract InvitationModuleTest is Test, HubStorageWrites {
    uint64 public day;
    uint256 internal gnosisFork;

    InvitationModule public invitationModule;

    address originInviter = 0x68e3c2aa468D9a80A8d9Bb8fC53bf072FE98B83a;
    address proxyInviter = 0x3A63F544918051f9285cf97008705790FD280012;
    address invitee1 = 0xFaC83AAc88D48e76C38A2Db49004e6DCfF530e66;
    address invitee2 = 0x5222D426102052983152dD4b19668f1ddD139E48;

    function setUp() public {
        gnosisFork = vm.createFork(vm.envString("GNOSIS_RPC"));
        vm.selectFork(gnosisFork);

        invitationModule = new InvitationModule();

        // set current day
        day = IHub(HUB).day(block.timestamp);
        // create test human accounts as safes
        // proxy
        _registerHuman(proxyInviter);
        _simulateSafe(proxyInviter);
        // origin
        _registerHuman(originInviter);
        _simulateSafe(originInviter);
        // give origin 96 CRC of own and proxy
        _setCRCBalance(uint256(uint160(originInviter)), originInviter, day, uint192(96 ether));
        _setCRCBalance(uint256(uint160(proxyInviter)), originInviter, day, uint192(96 ether));

        // make invitees a safe
        _simulateSafe(invitee1);
        _simulateSafe(invitee2);

        // enable invitation module for actors
        vm.prank(proxyInviter);
        IModuleManager(proxyInviter).enableModule(address(invitationModule));
        vm.prank(originInviter);
        IModuleManager(originInviter).enableModule(address(invitationModule));
        vm.prank(invitee1);
        IModuleManager(invitee1).enableModule(address(invitationModule));
        vm.prank(invitee2);
        IModuleManager(invitee2).enableModule(address(invitationModule));

        // set proxy trust origin (the requirement to involve as proxy inviter)
        _setTrust(proxyInviter, originInviter);
    }

    function testDirectInvite() public {
        vm.prank(originInviter);
        IHub(HUB)
            .safeTransferFrom(
                originInviter,
                address(invitationModule),
                uint256(uint160(originInviter)),
                96 ether,
                abi.encode(invitee1)
            );
        assertTrue(IHub(HUB).isHuman(invitee1));
    }

    function testProxyInvite() public {
        vm.prank(originInviter);
        IHub(HUB)
            .safeTransferFrom(
                originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, abi.encode(invitee2)
            );
        assertTrue(IHub(HUB).isHuman(invitee2));
    }
}
