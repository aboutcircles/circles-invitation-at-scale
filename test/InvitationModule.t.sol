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

    error NotExactInvitationFee();
    error InvalidEncoding();
    error HumanValidationFailed(address avatar);
    error TrustRequired(address truster, address trustee);
    error ModuleNotEnabled(address avatar);
    error ArrayLengthMismatch();
    error TooFewInvites();

    event RegisterHuman(address indexed human, address indexed originInviter, address indexed proxyInviter);

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
    }

    // case 1: origin inviter has invitation module, don't trust invitee -> valid
    // case 2: origin inviter has invitation module, trust invitee -> valid
    // case 3: origin inviter don't have invitation module, trust invitee -> valid
    // case 4: origin inviter don't have invitation module, don't trust invitee -> revert TrustRequired
    function testDirectInvite(bool isModuleEnabled) public {
        {
            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModuleTest.NotExactInvitationFee.selector, ""));
            IHub(HUB).safeTransferFrom(
                originInviter,
                address(invitationModule),
                uint256(uint160(originInviter)),
                91 ether,
                abi.encode(invitee1)
            );
        }
        {
            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModuleTest.InvalidEncoding.selector, ""));
            IHub(HUB).safeTransferFrom(
                originInviter, address(invitationModule), uint256(uint160(originInviter)), 96 ether, bytes("")
            );
        }
        // if OriginInviter is not human
        {
            address nonHuman = makeAddr("nonHuman");
            vm.assume(IHub(HUB).isHuman(nonHuman) == false);
            _simulateSafe(nonHuman);
            _setCRCBalance(uint256(uint160(nonHuman)), nonHuman, day, uint192(96 ether));
            vm.prank(nonHuman);
            IModuleManager(nonHuman).enableModule(address(invitationModule));

            vm.prank(nonHuman);
            vm.expectRevert(abi.encodeWithSelector(InvitationModuleTest.HumanValidationFailed.selector, nonHuman));
            IHub(HUB).safeTransferFrom(
                nonHuman, address(invitationModule), uint256(uint160(nonHuman)), 96 ether, abi.encode(invitee1)
            );
        }

        if (isModuleEnabled) {
            vm.prank(originInviter);
            vm.expectEmit(address(invitationModule));
            emit RegisterHuman(invitee1, originInviter, originInviter);
            IHub(HUB).safeTransferFrom(
                originInviter,
                address(invitationModule),
                uint256(uint160(originInviter)),
                96 ether,
                abi.encode(invitee1)
            );

            assertTrue(IHub(HUB).isHuman(invitee1));
            assertEq(IHub(HUB).balanceOf(originInviter, uint256(uint160(originInviter))), 0); // originInviter's 96 CRC is burnt
            assertEq(IHub(HUB).balanceOf(invitee1, uint256(uint160(invitee1))), 48 ether); // invitee1 gets invitaiton bonus of own CRC
            assertTrue(IHub(HUB).isTrusted(originInviter, invitee1));
            assertEq(IHub(HUB).balanceOf(address(invitationModule), uint256(uint160(originInviter))), 0); // invitationModule don't hold anything.
        } else {
            // InvitationModule is disabled

            vm.prank(originInviter);
            IModuleManager(originInviter).disableModule(address(0x01), address(invitationModule));

            // originInviter don't trust invitee yet
            vm.prank(originInviter);
            vm.expectRevert(
                abi.encodeWithSelector(InvitationModuleTest.TrustRequired.selector, originInviter, invitee1)
            );
            IHub(HUB).safeTransferFrom(
                originInviter,
                address(invitationModule),
                uint256(uint160(originInviter)),
                96 ether,
                abi.encode(invitee1)
            );

            _setTrust(originInviter, invitee1);

            vm.prank(originInviter);

            IHub(HUB).safeTransferFrom(
                originInviter,
                address(invitationModule),
                uint256(uint160(originInviter)),
                96 ether,
                abi.encode(invitee1)
            );

            assertTrue(IHub(HUB).isHuman(invitee1));
            assertEq(IHub(HUB).balanceOf(originInviter, uint256(uint160(originInviter))), 0); // originInviter's 96 CRC is burnt
            assertEq(IHub(HUB).balanceOf(invitee1, uint256(uint160(invitee1))), 48 ether); // invitee1 gets invitaiton bonus of own CRC
            assertTrue(IHub(HUB).isTrusted(originInviter, invitee1));
            assertEq(IHub(HUB).balanceOf(address(invitationModule), uint256(uint160(originInviter))), 0); // invitationModule don't hold anything.
        }
    }

    // case 1: originInviter has invitationModule -> valid
    // case 2: originInviter don't have invitationModule -> revert
    // case 3: proxyInviter is not Human
    // case 4: proxyInviter is not Human & invitationModule enabled
    function testProxyInvite(bool isModuleEnabled) public {
        // test the case

        // validateModuleEnabled(originInviter);
        // validateInviter(proxyInviter);
        // // check proxy inviter trusts origin inviter
        // validateTrust(proxyInviter, originInviter);
        vm.prank(originInviter);

        vm.expectRevert(
            abi.encodeWithSelector(InvitationModuleTest.TrustRequired.selector, proxyInviter, originInviter)
        );
        IHub(HUB).safeTransferFrom(
            originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, abi.encode(invitee2)
        );

        _setTrust(proxyInviter, originInviter);

        if (isModuleEnabled) {
            // both origin and proxy Inviter has module enabled
            vm.prank(originInviter);
            IHub(HUB).safeTransferFrom(
                originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, abi.encode(invitee2)
            );
            assertTrue(IHub(HUB).isHuman(invitee2));
            return;
        } else {
            // origin inviter don't have module enabled
            // revert if

            vm.prank(originInviter);
            IModuleManager(originInviter).disableModule(address(0x01), address(invitationModule));

            vm.prank(proxyInviter);
            IModuleManager(proxyInviter).disableModule(address(0x01), address(invitationModule));

            // originInviter don't trust invitee yet
            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModuleTest.ModuleNotEnabled.selector, originInviter));
            IHub(HUB).safeTransferFrom(
                originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, abi.encode(invitee1)
            );

            vm.prank(originInviter);
            IModuleManager(originInviter).enableModule(address(invitationModule));

            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModuleTest.ModuleNotEnabled.selector, proxyInviter));
            IHub(HUB).safeTransferFrom(
                originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, abi.encode(invitee1)
            );
            vm.prank(proxyInviter);
            IModuleManager(proxyInviter).enableModule(address(invitationModule));
            vm.prank(originInviter);
            IHub(HUB).safeTransferFrom(
                originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, abi.encode(invitee2)
            );
            assertTrue(IHub(HUB).isHuman(invitee2));
            return;
        }
    }

    function testBatchInvite() public {
        _setCRCBalance(uint256(uint160(originInviter)), originInviter, day, uint192(192 ether));

        // Note: in InvitationModule, these 2 lines are not reachable  as it will revert in ERC1155.ERC1155InvalidArrayLength(uint256,uint256) 0x5b059991
        // if (numberOfInvitees != values.length) revert ArrayLengthMismatch(); // dead branch, will first revert in ERC1155 in Hub 0x5b059991
        // if (numberOfInvitees < 2) revert TooFewInvites(); // dead branch, will first revert the line before this

        {
            address[] memory invitees = new address[](2);
            invitees[0] = invitee1;
            invitees[1] = invitee2;

            uint256[] memory ids = new uint256[](2);
            ids[0] = uint256(uint160(originInviter));
            ids[1] = uint256(uint160(originInviter));
            uint256[] memory values = new uint256[](2);
            values[0] = 96 ether; // Not enough CRC
            values[1] = 92 ether;

            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModuleTest.NotExactInvitationFee.selector));
            IHub(HUB).safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, abi.encode(invitees));

            //  Invalid data that will get _isGenericCall(data) == true, but fail at calling genericCallProxy
            address randomAddress = makeAddr("randomAddr");
            bytes memory data = abi.encode(randomAddress);
            vm.assume(uint256(uint160(randomAddress)) > data.length);
            values[1] = 96 ether;

            vm.prank(originInviter);
            vm.expectRevert();
            IHub(HUB).safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, data);
        }

        {
            // let's test ivniting 2 addresses
            address[] memory invitees = new address[](2);
            invitees[0] = invitee1;
            invitees[1] = invitee2;

            uint256[] memory ids = new uint256[](2);
            ids[0] = uint256(uint160(originInviter));
            ids[1] = uint256(uint160(originInviter));

            uint256[] memory values = new uint256[](2);
            values[0] = 96 ether;
            values[1] = 96 ether;

            // invitee1 and invitee2
            vm.prank(originInviter);
            IHub(HUB).safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, abi.encode(invitees));

            assertTrue(IHub(HUB).isHuman(invitee1));
            assertTrue(IHub(HUB).isHuman(invitee2));
            assertEq(IHub(HUB).balanceOf(originInviter, uint256(uint160(originInviter))), 0); // originInviter's 96 CRC is burnt
            assertEq(IHub(HUB).balanceOf(invitee1, uint256(uint160(invitee1))), 48 ether); // invitee1 gets invitaiton bonus of own CRC
            assertEq(IHub(HUB).balanceOf(invitee2, uint256(uint160(invitee2))), 48 ether); // invitee2 gets invitaiton bonus of own CRC
            assertTrue(IHub(HUB).isTrusted(originInviter, invitee1));
            assertTrue(IHub(HUB).isTrusted(originInviter, invitee2));
            assertEq(IHub(HUB).balanceOf(address(invitationModule), uint256(uint160(originInviter))), 0); // invitationModule don't hold anything.
        }
    }
}
