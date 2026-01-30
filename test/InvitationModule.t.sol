// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {HubStorageWrites} from "test/helpers/HubStorageWrites.sol";
import {IModuleManager} from "src/interfaces/IModuleManager.sol";
import {IHub} from "test/helpers/CirclesV2Setup.sol";
import {InvitationModule} from "src/InvitationModule.sol";
import {GenericCallProxy} from "src/GenericCallProxy.sol";
import {CirclesV2Setup, TypeDefinitions} from "test/helpers/CirclesV2Setup.sol";
import {
    FakeSafeAlwaysTrue,
    FakeSafeAlwaysFalse,
    FakeSafeGroup,
    Scammer,
    FakeTreasury,
    FakeMintPolicy
} from "test/helpers/FakeSafe.sol";
import {InvitationModuleNoValidateHuman} from "test/helpers/InvitationModuleNoValidateHuman.sol";

/**
 * @title InvitationModuleTest
 * @notice Test suite for the InvitationModule contract.
 * @dev This contract tests the functionality of the InvitationModule, including direct and proxy invitations,
 * as well as batch invitations. It uses a forked Gnosis chain environment to simulate real-world conditions.
 */

contract InvitationModuleTest is CirclesV2Setup, HubStorageWrites {
    /// @notice The current day, calculated from the block timestamp.
    uint64 public day;

    /// @notice An instance of the InvitationModule contract.
    InvitationModule public invitationModule;

    /// @notice Error that signals a reentrancy attempt during invitation processing.
    error Reentrancy();

    /// @notice The address of the original inviter.
    address originInviter;
    /// @notice The address of the proxy inviter.
    address proxyInviter;
    /// @notice The address of the first invitee.
    address invitee1;
    /// @notice The address of the second invitee.
    address invitee2;
    /// @notice The address of the third invitee.
    address invitee3;

    /// @notice The address for the fake contract that mimics an inviter but doesn't have Safe functionalities.
    address fakeInviterSafe;
    /// @notice The address for the fake contract that mimics a proxy inviter but doesn't have Safe functionalities.
    address fakeProxyInviterSafe;
    /// @notice The address for the fake contract that mimics an invitee but doesn't have Safe functionalities.
    address fakeInvitee;
    /// @notice The address for the fake contract that always returns false for Safe checks.
    address fakeSafe;

    /**
     * @notice Sets up the test environment before each test case.
     * @dev This function creates a fork of the Gnosis chain, deploys the InvitationModule,
     * sets up test accounts (origin inviter, proxy inviter, and invitees), and enables the
     * InvitationModule for these accounts.
     */
    function setUp() public override {
        super.setUp();
        vm.warp(INVITATION_ONLY_TIME + 1);
        // set current day
        day = HUB_V2.day(block.timestamp);

        invitationModule = new InvitationModule();
        fakeInviterSafe = address(new FakeSafeAlwaysTrue());
        fakeProxyInviterSafe = address(new FakeSafeAlwaysTrue());
        fakeInvitee = address(new FakeSafeAlwaysTrue());
        fakeSafe = address(new FakeSafeAlwaysFalse());
        originInviter = makeAddr("originInviter");
        proxyInviter = makeAddr("proxyInviter");
        invitee1 = makeAddr("invitee1");
        invitee2 = makeAddr("invitee2");
        invitee3 = makeAddr("invited3");

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
        _simulateSafe(invitee3);

        _registerHuman(address(fakeInviterSafe));
        _setCRCBalance(uint256(uint160(address(fakeInviterSafe))), address(fakeInviterSafe), day, uint192(96 ether));

        _registerHuman(fakeProxyInviterSafe);
        _setCRCBalance(uint256(uint160(address(fakeProxyInviterSafe))), fakeInviterSafe, day, uint192(96 ether));

        // enable invitation module for actors
        vm.prank(proxyInviter);
        IModuleManager(proxyInviter).enableModule(address(invitationModule));
        vm.prank(originInviter);
        IModuleManager(originInviter).enableModule(address(invitationModule));
        vm.prank(invitee1);
        IModuleManager(invitee1).enableModule(address(invitationModule));
        vm.prank(invitee2);
        IModuleManager(invitee2).enableModule(address(invitationModule));
        vm.prank(invitee3);
        IModuleManager(invitee3).enableModule(address(invitationModule));
    }

    /**
     * @notice Tests the direct invitation functionality.
     * @dev This test covers four scenarios:
     * 1. Origin inviter has the module enabled and doesn't trust the invitee (should be valid).
     * 2. Origin inviter has the module enabled and trusts the invitee (should be valid).
     * 3. Origin inviter doesn't have the module enabled but trusts the invitee (should be valid).
     * 4. Origin inviter doesn't have the module enabled and doesn't trust the invitee (should revert).
     */
    function testDirectInvite() public {
        {
            // Revert: Value less than 96 CRC
            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModule.NotExactInvitationFee.selector, ""));
            HUB_V2.safeTransferFrom(
                originInviter,
                address(invitationModule),
                uint256(uint160(originInviter)),
                91 ether,
                abi.encode(invitee1)
            );
        }
        {
            // Revert: Data don't encode invitee address
            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModule.InvalidEncoding.selector, ""));
            HUB_V2.safeTransferFrom(
                originInviter, address(invitationModule), uint256(uint160(originInviter)), 96 ether, bytes("")
            );
        }

        {
            // Revert: Non human can't invite
            address nonHuman = makeAddr("nonHuman");
            vm.assume(HUB_V2.isHuman(nonHuman) == false);
            _simulateSafe(nonHuman);
            _setCRCBalance(uint256(uint160(nonHuman)), nonHuman, day, uint192(96 ether));
            vm.prank(nonHuman);
            IModuleManager(nonHuman).enableModule(address(invitationModule));

            vm.prank(nonHuman);
            vm.expectRevert(abi.encodeWithSelector(InvitationModule.HumanValidationFailed.selector, nonHuman));
            HUB_V2.safeTransferFrom(
                nonHuman, address(invitationModule), uint256(uint160(nonHuman)), 96 ether, abi.encode(invitee1)
            );
        }

        uint256 snapShotId = vm.snapshotState();
        {
            // Case 1: OriginInviter has invitation module enabled && originInviter don't trust invitee1 -> valid

            vm.prank(originInviter);
            vm.expectEmit(address(invitationModule));
            emit InvitationModule.RegisterHuman(invitee1, originInviter, originInviter);
            HUB_V2.safeTransferFrom(
                originInviter,
                address(invitationModule),
                uint256(uint160(originInviter)),
                96 ether,
                abi.encode(invitee1)
            );

            assertTrue(HUB_V2.isHuman(invitee1));
            assertEq(HUB_V2.balanceOf(originInviter, uint256(uint160(originInviter))), 0); // originInviter's 96 CRC is burnt
            assertEq(HUB_V2.balanceOf(invitee1, uint256(uint160(invitee1))), 48 ether); // invitee1 gets invitaiton bonus of own CRC
            (, uint256 expiry) = HUB_V2.trustMarkers(originInviter, invitee1);
            assertTrue(expiry == type(uint96).max);
            //assertTrue(HUB_V2.isTrusted(originInviter, invitee1)); //  originInviter now trust invitee1
            assertEq(HUB_V2.balanceOf(address(invitationModule), uint256(uint160(originInviter))), 0); // invitationModule don't hold anything.

            // Should revert if trying to invite again
            _setCRCBalance(uint256(uint160(originInviter)), originInviter, day, uint192(96 ether));

            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModule.InviteeAlreadyRegistered.selector, invitee1));
            HUB_V2.safeTransferFrom(
                originInviter,
                address(invitationModule),
                uint256(uint160(originInviter)),
                96 ether,
                abi.encode(invitee1)
            );

            // Case 2

            _setTrust(originInviter, invitee2);

            vm.prank(originInviter);

            HUB_V2.safeTransferFrom(
                originInviter,
                address(invitationModule),
                uint256(uint160(originInviter)),
                96 ether,
                abi.encode(invitee2)
            );
            assertTrue(HUB_V2.isHuman(invitee2));

            // let's use fakeInviterSafe, which will fail in enforceTrust as trust function is not called

            vm.prank(fakeInviterSafe);
            vm.expectRevert(
                abi.encodeWithSelector(InvitationModule.TrustEnforcementFailed.selector, fakeInviterSafe, invitee3)
            );
            HUB_V2.safeTransferFrom(
                fakeInviterSafe,
                address(invitationModule),
                uint256(uint160(fakeInviterSafe)),
                96 ether,
                abi.encode(invitee3)
            );

            // Should success even though trust is not called through _callHubFromSafe, but inviter already trusted invitee3
            _setTrust(fakeInviterSafe, invitee3);
            vm.prank(fakeInviterSafe);
            HUB_V2.safeTransferFrom(
                fakeInviterSafe,
                address(invitationModule),
                uint256(uint160(fakeInviterSafe)),
                96 ether,
                abi.encode(invitee3)
            );
            assertTrue(HUB_V2.isHuman(invitee3));
            assertEq(HUB_V2.balanceOf(fakeInviterSafe, uint256(uint160(fakeInviterSafe))), 0); // fakeInviterSafe's 96 CRC is burnt
            assertEq(HUB_V2.balanceOf(invitee3, uint256(uint160(invitee3))), 48 ether); // invitee3 gets invitaiton bonus of own CRC
            (, uint256 invitee3Expiry) = HUB_V2.trustMarkers(fakeInviterSafe, invitee3);
            assertTrue(invitee3Expiry == type(uint96).max);
            assertEq(HUB_V2.balanceOf(address(invitationModule), uint256(uint160(fakeInviterSafe))), 0); // invitationModule don't hold anything.
        }
        vm.revertToState(snapShotId);
        {
            // Case 4: OriginInviter don't have invitation module disabled  && don't trust invitee1 -> revert

            vm.prank(originInviter);
            IModuleManager(originInviter).disableModule(address(0x01), address(invitationModule));

            // originInviter don't trust invitee yet, revert
            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModule.TrustRequired.selector, originInviter, invitee1));
            HUB_V2.safeTransferFrom(
                originInviter,
                address(invitationModule),
                uint256(uint160(originInviter)),
                96 ether,
                abi.encode(invitee1)
            );

            // Set trust to invitee1
            _setTrust(originInviter, invitee1);

            // Case 3: OriginInviter don't have invitation module enabled, but trust invitee1 -> valid
            vm.prank(originInviter);
            HUB_V2.safeTransferFrom(
                originInviter,
                address(invitationModule),
                uint256(uint160(originInviter)),
                96 ether,
                abi.encode(invitee1)
            );

            assertTrue(HUB_V2.isHuman(invitee1));
            assertEq(HUB_V2.balanceOf(originInviter, uint256(uint160(originInviter))), 0); // originInviter's 96 CRC is burnt
            assertEq(HUB_V2.balanceOf(invitee1, uint256(uint160(invitee1))), 48 ether); // invitee1 gets invitaiton bonus of own CRC
            (, uint256 expiry) = HUB_V2.trustMarkers(originInviter, invitee1);
            assertTrue(expiry == type(uint96).max);
            assertEq(HUB_V2.balanceOf(address(invitationModule), uint256(uint160(originInviter))), 0); // invitationModule don't hold anything.
        }
    }

    /**
     * @notice Tests the proxy invitation functionality.
     * @dev This test covers three scenarios:
     * 1. Both origin and proxy inviters have the module enabled (should be valid).
     * 2. Both origin and proxy inviters do not have the module enabled (should revert).
     * 3. Origin inviter has the module enabled, but the proxy inviter does not (should revert).
     */
    function testProxyInvite() public {
        {
            // Revert Human Enforcement Failed

            _setTrust(fakeProxyInviterSafe, fakeInviterSafe);
            _setTrust(fakeProxyInviterSafe, fakeInvitee); // To pass enforceTrust check

            vm.prank(fakeInviterSafe);

            vm.expectRevert(abi.encodeWithSelector(InvitationModule.HumanRegistrationFailed.selector, fakeInvitee));
            HUB_V2.safeTransferFrom(
                fakeInviterSafe,
                address(invitationModule),
                uint256(uint160(fakeProxyInviterSafe)),
                96 ether,
                abi.encode(fakeInvitee)
            );
        }
        {
            // Revert: proxyInviter don't trust originInviter
            vm.prank(originInviter);

            vm.expectRevert(
                abi.encodeWithSelector(InvitationModule.TrustRequired.selector, proxyInviter, originInviter)
            );
            HUB_V2.safeTransferFrom(
                originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, abi.encode(invitee1)
            );
            _setTrust(proxyInviter, originInviter);
        }
        uint256 snapShotId = vm.snapshotState();
        {
            // Case 1: originInviter and proxyInviter has module enabled -> valid
            vm.prank(originInviter);
            HUB_V2.safeTransferFrom(
                originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, abi.encode(invitee1)
            );
            assertTrue(HUB_V2.isHuman(invitee1));
            assertEq(HUB_V2.balanceOf(originInviter, uint256(uint160(originInviter))), 96 ether); // originInviter's 96 CRC remains
            assertEq(HUB_V2.balanceOf(proxyInviter, uint256(uint160(proxyInviter))), 0); // proxyInviter's 96 CRC is burnt
            assertEq(HUB_V2.balanceOf(invitee1, uint256(uint160(invitee1))), 48 ether); // invitee1 gets invitaiton bonus of own CRC
            (, uint256 expiryOrigin) = HUB_V2.trustMarkers(originInviter, invitee1);
            assertTrue(expiryOrigin == type(uint96).max);
            (, uint256 expiryProxy) = HUB_V2.trustMarkers(proxyInviter, invitee1);
            assertTrue(expiryProxy == block.timestamp);

            assertEq(HUB_V2.balanceOf(address(invitationModule), uint256(uint160(originInviter))), 0); // invitationModule don't hold anything.
        }
        vm.revertToState(snapShotId);

        {
            vm.prank(originInviter);
            IModuleManager(originInviter).disableModule(address(0x01), address(invitationModule));

            vm.prank(proxyInviter);
            IModuleManager(proxyInviter).disableModule(address(0x01), address(invitationModule));

            // Case 2: originInviter && proxyInviter don't have module enabled
            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModule.ModuleNotEnabled.selector, originInviter));
            HUB_V2.safeTransferFrom(
                originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, abi.encode(invitee1)
            );

            vm.prank(originInviter);
            IModuleManager(originInviter).enableModule(address(invitationModule));

            // Case 3: originInviter have invitationModule &&  proxyInviter don't have invitationModule enabled
            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModule.ModuleNotEnabled.selector, proxyInviter));
            HUB_V2.safeTransferFrom(
                originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, abi.encode(invitee1)
            );

            vm.prank(proxyInviter);
            IModuleManager(proxyInviter).enableModule(address(invitationModule));

            // Both originInviter && proxyInviter have invitationModule enabled -> fallback to case 1 -> valid
            vm.prank(originInviter);
            HUB_V2.safeTransferFrom(
                originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, abi.encode(invitee1)
            );
            assertTrue(HUB_V2.isHuman(invitee1));
        }
        vm.revertToState(snapShotId);
        {

            bytes memory maliciousTransferCallData = abi.encodeWithSelector(
                IHub.safeTransferFrom.selector,
                proxyInviter,
                originInviter,
                uint256(uint160(proxyInviter)),
                96 ether,
                ""
            );

            bytes memory maliciousModuleCallData = abi.encodeWithSelector(
                IModuleManager.execTransactionFromModuleReturnData.selector,
                address(HUB_V2),
                0,
                maliciousTransferCallData,
                0
            );

            bytes memory genericCallPayload = abi.encode(proxyInviter, maliciousModuleCallData);

            vm.prank(originInviter);
            vm.expectRevert(
                abi.encodeWithSelector(
                    GenericCallProxy.GenericCallReverted.selector, abi.encodeWithSignature("Error(string)", "GS104")
                )
            );
            HUB_V2.safeTransferFrom(
                originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, genericCallPayload
            );
        }
    }

    /**
     * @notice Tests the batch direct invitation functionality.
     * @dev This test verifies that multiple invitees can be invited in a single transaction.
     * It also checks for various failure conditions, such as insufficient CRC, invalid data,
     * and unreachable code paths.
     */
    function testBatchDirectInvite(bytes memory data) public {
        _setCRCBalance(uint256(uint160(originInviter)), originInviter, day, uint192(192 ether));
        vm.assume(data.length > 32);
        // Note: in InvitationModule, these 2 lines are not reachable  as it will revert in ERC1155.ERC1155InvalidArrayLength(uint256,uint256) 0x5b059991
        // if (numberOfInvitees != values.length) revert ArrayLengthMismatch(); // dead branch, will first revert in ERC1155 in Hub 0x5b059991
        // if (numberOfInvitees < 2) revert TooFewInvites(); // dead branch, will first revert the line before this

        {
            // Construct array parameters
            address[] memory invitees = new address[](2);
            invitees[0] = invitee1;
            invitees[1] = invitee2;

            uint256[] memory ids = new uint256[](2);
            ids[0] = uint256(uint160(originInviter));
            ids[1] = uint256(uint160(originInviter));

            uint256[] memory values = new uint256[](2);
            values[0] = 96 ether;
            values[1] = 92 ether; // Not enough CRC

            // Revert: Not enough CRC for invitation
            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModule.NotExactInvitationFee.selector));
            HUB_V2.safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, abi.encode(invitees));

            values[1] = 96 ether;

            vm.prank(originInviter);
            // Revert: Invalid data that will get _isGenericCall(data) == true, but fail at calling genericCallProxy
            vm.expectRevert();
            HUB_V2.safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, data);

            // when the invitee don't have InvitationModule enabled, should revert
            address invitee4 = makeAddr("invitee4");
            _simulateSafe(invitee4);
            invitees[0] = invitee4;

            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModule.ModuleNotEnabled.selector, invitee3));
            HUB_V2.safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, abi.encode(invitees));

            // Valid case
            vm.prank(originInviter);
            HUB_V2.safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, abi.encode(invitees));

            assertTrue(HUB_V2.isHuman(invitee1));
            assertTrue(HUB_V2.isHuman(invitee2));
            assertEq(HUB_V2.balanceOf(originInviter, uint256(uint160(originInviter))), 0); // originInviter's 192 CRC is burnt
            assertEq(HUB_V2.balanceOf(invitee1, uint256(uint160(invitee1))), 48 ether); // invitee1 gets invitaiton bonus of own CRC
            assertEq(HUB_V2.balanceOf(invitee2, uint256(uint160(invitee2))), 48 ether); // invitee2 gets invitaiton bonus of own CRC
            (, uint256 expiryOrigin1) = HUB_V2.trustMarkers(originInviter, invitee1);
            assertTrue(expiryOrigin1 == type(uint96).max);
            (, uint256 expiryOrigin2) = HUB_V2.trustMarkers(originInviter, invitee2);
            assertTrue(expiryOrigin2 == type(uint96).max);

            assertEq(HUB_V2.balanceOf(address(invitationModule), uint256(uint160(originInviter))), 0); // invitationModule don't hold anything.
        }
    }

    /**
     * @notice Tests the batch proxy invitation functionality.
     * @dev This test verifies that multiple invitees can be invited via a proxy in a single transaction.
     * It also checks for various failure conditions, such as insufficient CRC, missing trust relationships,
     * and invalid data.
     */
    function testBatchProxyInvite(bytes memory data) public {
        _setCRCBalance(uint256(uint160(proxyInviter)), originInviter, day, uint192(192 ether));

        {
            // Construct array parameters
            address[] memory invitees = new address[](2);
            invitees[0] = invitee1;
            invitees[1] = invitee2;

            uint256[] memory ids = new uint256[](2);
            ids[0] = uint256(uint160(proxyInviter));
            ids[1] = uint256(uint160(proxyInviter));

            uint256[] memory values = new uint256[](2);
            values[0] = 92 ether; // Not enough CRC
            values[1] = 96 ether;

            // Revert: Not enough CRC for invitation
            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModule.NotExactInvitationFee.selector));
            HUB_V2.safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, abi.encode(invitees));

            values[0] = 96 ether;

            // Revert: proxy Inviter don't trust Invitee
            vm.prank(originInviter);
            vm.expectRevert(
                abi.encodeWithSelector(InvitationModule.TrustRequired.selector, proxyInviter, originInviter)
            );
            HUB_V2.safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, abi.encode(invitees));

            _setTrust(proxyInviter, originInviter);

            // Revert: Invalid data that will get _isGenericCall(data) == true, but fail at calling genericCallProxy

            vm.assume(data.length > 32);

            vm.prank(originInviter);
            vm.expectRevert();
            HUB_V2.safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, data);

            // Valid case
            vm.prank(originInviter);
            HUB_V2.safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, abi.encode(invitees));

            assertTrue(HUB_V2.isHuman(invitee1));
            assertTrue(HUB_V2.isHuman(invitee2));
            assertEq(HUB_V2.balanceOf(originInviter, uint256(uint160(proxyInviter))), 0); // originInviter's proxyInviter 192 CRC is burnt
            assertEq(HUB_V2.balanceOf(invitee1, uint256(uint160(invitee1))), 48 ether); // invitee1 gets invitaiton bonus of own CRC
            assertEq(HUB_V2.balanceOf(invitee2, uint256(uint160(invitee2))), 48 ether); // invitee2 gets invitaiton bonus of own CRC
            (, uint256 expiryInvitee1) = HUB_V2.trustMarkers(originInviter, invitee1);
            assertTrue(expiryInvitee1 == type(uint96).max);
            (, uint256 expiryInvitee2) = HUB_V2.trustMarkers(originInviter, invitee2);
            assertTrue(expiryInvitee2 == type(uint96).max);

            (, uint256 expiryProxy1) = HUB_V2.trustMarkers(proxyInviter, invitee1);
            assertTrue(expiryProxy1 == block.timestamp);
            (, uint256 expiryProxy2) = HUB_V2.trustMarkers(proxyInviter, invitee2);
            assertTrue(expiryProxy2 == block.timestamp);

            assertEq(HUB_V2.balanceOf(address(invitationModule), uint256(uint160(originInviter))), 0); // invitationModule don't hold anything.
        }
    }

    /**
     * @notice Tests that the ERC1155 receiver hooks can only be called by the Hub.
     * @dev This test ensures that `onERC1155Received` and `onERC1155BatchReceived` revert
     * when called by an address other than the Hub, preventing unauthorized token transfers.
     */
    function testOnlyHub() public {
        vm.prank(makeAddr("randomAddress"));
        vm.expectRevert(abi.encodeWithSelector(InvitationModule.OnlyHub.selector));
        invitationModule.onERC1155Received(makeAddr("randomAddress"), originInviter, 0, 96 ether, "");

        uint256[] memory ids = new uint256[](2);
        ids[0] = uint256(uint160(originInviter));
        ids[1] = uint256(uint160(originInviter));

        uint256[] memory values = new uint256[](2);
        values[0] = 96 ether;
        values[1] = 96 ether;
        vm.expectRevert(abi.encodeWithSelector(InvitationModule.OnlyHub.selector));
        invitationModule.onERC1155BatchReceived(makeAddr("randomAddress"), originInviter, ids, values, "");
    }

    /**
     * @notice Tests that calling the Hub from a fake Safe (without proper Safe functionality) fails.
     * @dev This test verifies that when a fake Safe contract (that doesn't implement proper Safe module functionality)
     * attempts to make a call to the Hub through the InvitationModule, it fails with the expected revert.
     * The test uses a FakeSafeAlwaysFalse contract that always returns false for Safe execTransactionFromModuleReturnData.
     */
    function testCallHubFromSafeFail() public {
        _registerHuman(fakeSafe);
        _setCRCBalance(uint256(uint160(address(fakeSafe))), fakeSafe, day, uint192(96 ether));
        vm.prank(fakeSafe);
        vm.expectRevert(abi.encodePacked(address(invitationModule))); // revert calldata from fakeSafe, which is the abi.encodePacked(msg.sender)
        HUB_V2.safeTransferFrom(
            fakeSafe, address(invitationModule), uint256(uint160(fakeSafe)), 96 ether, abi.encode(invitee1)
        );
    }

    /**
     * @notice Tests reentrancy protection in both single and batch invitation scenarios.
     * @dev This test verifies that the InvitationModule properly prevents reentrancy attacks
     * by attempting to call the Hub recursively during the onERC1155Received and
     * onERC1155BatchReceived callbacks. Both scenarios should revert with a Reentrancy error.
     * The test covers:
     * - Single transfer reentrancy attempt via onERC1155Received
     * - Batch transfer reentrancy attempt via onERC1155BatchReceived
     */
    function testReentrancy() public {
        // Reentrant onERC1155Received
        // singe Transfer: originInviter need 192 CRC
        // batch Transfer: f originInviter need 384 CRC
        _setCRCBalance(uint256(uint160(proxyInviter)), originInviter, day, uint192(384 ether));
        // Trick to prevent ERC1155MissingApprovalForAll error
        _setOperatorApproval(originInviter, address(invitationModule.GENERIC_CALL_PROXY()));

        bytes memory reentrantCalldata = abi.encodeCall(
            IHub.safeTransferFrom,
            (originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, abi.encode(invitee1))
        );
        bytes memory fullCalldataWithAddr = abi.encode(HUB, reentrantCalldata);
        vm.prank(originInviter);
        vm.expectRevert(
            abi.encodeWithSelector(
                GenericCallProxy.GenericCallReverted.selector, abi.encodePacked(InvitationModule.Reentrancy.selector)
            )
        ); // revert GenericCallReverted(Reentrancy())
        HUB_V2.safeTransferFrom(
            originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, fullCalldataWithAddr
        );

        // Reentrant onERC1155BatchReceived
        address[] memory invitees = new address[](2);
        invitees[0] = invitee1;
        invitees[1] = invitee2;

        uint256[] memory ids = new uint256[](2);
        ids[0] = uint256(uint160(proxyInviter));
        ids[1] = uint256(uint160(proxyInviter));

        uint256[] memory values = new uint256[](2);
        values[0] = 96 ether;
        values[1] = 96 ether;

        reentrantCalldata = abi.encodeCall(
            IHub.safeBatchTransferFrom, (originInviter, address(invitationModule), ids, values, abi.encode(invitees))
        );
        fullCalldataWithAddr = abi.encode(HUB, reentrantCalldata);
        vm.prank(originInviter);
        vm.expectRevert(
            abi.encodeWithSelector(
                GenericCallProxy.GenericCallReverted.selector, abi.encodePacked(InvitationModule.Reentrancy.selector)
            )
        ); // revert GenericCallReverted(Reentrancy())
        HUB_V2.safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, fullCalldataWithAddr);
    }

    // To demonstrate that without human validation, inviter can result in trusting malicious group and drain personal CRC by the scammer
    function testDrainCRCFromInviter() public {
        // 1. inviter trust invitee (a fake group) in through InvitationModule.onERC1155Received call
        // 2. invitee register itself as group
        // 2. invitee call groupMint while the collateral is sent to scammer account continuously
        // 3. scammer hold a huge amount of fake group token, which inviter trust
        // 4. through opreateFlowMatrix, scammer drain all the inviter's token since inviter trust invitee(fake group)

        Scammer scammer = new Scammer();
        FakeMintPolicy fakeMintPolicy = new FakeMintPolicy();
        FakeTreasury fakeTreasury = new FakeTreasury(address(scammer));
        FakeSafeGroup fakeGroup = new FakeSafeGroup(address(scammer), address(fakeTreasury), address(fakeMintPolicy));
        uint192 scammerInitialCRCAmount = uint192(1 ether);
        _registerHuman(address(scammer));
        _setCRCBalance(uint256(uint160(address(scammer))), address(scammer), day, scammerInitialCRCAmount);
        {
            scammer.trustExternal(address(originInviter));
            vm.prank(address(scammer));
            HUB_V2.setApprovalForAll(address(scammer), true); // To prevent errror from isApprovedForAll(scammer, scammer) = false

            // The original InvitationModule will not success
            vm.prank(originInviter);
            vm.expectRevert(
                abi.encodeWithSelector(InvitationModule.HumanRegistrationFailed.selector, address(fakeGroup))
            );
            HUB_V2.safeTransferFrom(
                originInviter,
                address(invitationModule),
                uint256(uint160(originInviter)),
                96 ether,
                abi.encode(address(fakeGroup))
            );

            // Let's create a new InvitationModule that don't check if the invitee is registered as human after onERC1155Received is called
            InvitationModuleNoValidateHuman invitationModuleNoValidateHuman = new InvitationModuleNoValidateHuman();

            vm.prank(originInviter);
            IModuleManager(originInviter).enableModule(address(invitationModuleNoValidateHuman));
            vm.prank(originInviter);
            // Make originInviter invites fakeGroup as invitee
            HUB_V2.safeTransferFrom(
                originInviter,
                address(invitationModuleNoValidateHuman),
                uint256(uint160(originInviter)),
                96 ether,
                abi.encode(address(fakeGroup))
            );

            // Make scammer abuse group treasury and hold as many group CRC as it wants, which is trusted by originInviter
            uint256 loopAmt = 100;
            scammer.mintGroupToken(address(fakeGroup), address(fakeTreasury), scammerInitialCRCAmount, loopAmt);

            assertEq(
                HUB_V2.balanceOf(address(scammer), uint256(uint160(address(fakeGroup)))),
                scammerInitialCRCAmount * loopAmt
            );
        }
        // The current amount of personal CRC hold by originInviter
        uint256 inviterAmount = HUB_V2.balanceOf(originInviter, uint256(uint160(originInviter)));

        // Construct operateFlowMatrix

        { // scammer --fakeGroupCRC--> originInviter --originInviterCRC--> scammer
            TypeDefinitions.FlowEdge[] memory flowEdges = new TypeDefinitions.FlowEdge[](2);
            TypeDefinitions.Stream[] memory streams = new TypeDefinitions.Stream[](1);
            bytes memory packCoordinate;
            address[] memory flowVertices = new address[](3);
            flowVertices[0] = address(scammer);
            flowVertices[1] = address(fakeGroup);
            flowVertices[2] = address(originInviter);

            uint16[] memory indexes;
            (flowVertices, indexes) = _sortWithMapping(flowVertices);

            flowEdges[0] = TypeDefinitions.FlowEdge({streamSinkId: uint16(0), amount: uint192(inviterAmount)});
            flowEdges[1] = TypeDefinitions.FlowEdge({streamSinkId: uint16(1), amount: uint192(inviterAmount)});

            uint16[] memory flowEdgeIds = new uint16[](1);
            flowEdgeIds[0] = uint16(1); // the last flowEdges is terminated edge

            streams[0] = TypeDefinitions.Stream({
                sourceCoordinate: indexes[0], // source: scammer
                flowEdgeIds: flowEdgeIds,
                data: bytes("")
            });

            uint16[] memory coords = new uint16[]((flowEdges.length) * 3);

            // scammer --fakeGroupCRC--> originInviter

            coords[0] = uint16(indexes[1]);
            coords[1] = uint16(indexes[0]);
            coords[2] = uint16(indexes[2]);

            // originInviter --originInviterCRC--> scammer

            coords[3] = uint16(indexes[2]);
            coords[4] = uint16(indexes[2]);
            coords[5] = uint16(indexes[0]);

            packCoordinate = _packCoordinates(coords);

            vm.startPrank(address(scammer));
            // ===================== call operateFlowMatrix =====================

            HUB_V2.operateFlowMatrix(flowVertices, flowEdges, streams, packCoordinate);
            vm.stopPrank();
        }

        assertEq(HUB_V2.balanceOf(address(scammer), uint256(uint160(address(originInviter)))), inviterAmount); // Scammer now holds all originInviter's personal CRC
        assertEq(HUB_V2.balanceOf(address(originInviter), uint256(uint160(address(originInviter)))), 0);
        assertEq(HUB_V2.balanceOf(address(originInviter), uint256(uint160(address(fakeGroup)))), inviterAmount); // originInviter now holds equivalent amount of fakeGroupCRC
    }

    /// ======================== Utils function for operateFlowMatrix ========================
    /**
     * @notice Sorts an array of addresses in ascending order
     *         and returns both the sorted array and a mapping (as an array)
     *         that indicates the original index for each sorted element.
     *          Helper function from MintRedemptionFlow.t.sol
     * @param arr The array of addresses to sort.
     * @return sortedAddresses The sorted array of addresses.
     * @return indexes An array where each element is the original index
     *         of the corresponding address in the sorted array.
     */
    function _sortWithMapping(address[] memory arr)
        internal
        pure
        returns (address[] memory sortedAddresses, uint16[] memory indexes)
    {
        // Initialize the indexes array to track original positions.
        // Each position i starts with the value i.
        uint16[] memory permutation = new uint16[](arr.length);
        for (uint16 i; i < arr.length;) {
            permutation[i] = i;
            unchecked {
                ++i;
            }
        }

        // We'll perform a bubble sort on the addresses array.
        // As we swap addresses, we swap the indexes as well.
        for (uint256 i = 0; i < arr.length; i++) {
            for (uint256 j = 0; j < arr.length - i - 1; j++) {
                // Compare addresses directly (addresses are comparable)
                if (arr[j] > arr[j + 1]) {
                    // Swap addresses
                    address temp = arr[j];
                    arr[j] = arr[j + 1];
                    arr[j + 1] = temp;

                    // Swap corresponding indexes to maintain mapping
                    uint16 tempIndex = permutation[j];
                    permutation[j] = permutation[j + 1];
                    permutation[j + 1] = tempIndex;
                }
            }
        }

        indexes = new uint16[](arr.length);
        for (uint16 i = 0; i < arr.length; i++) {
            // Place i at the index specified by arr[i]
            indexes[permutation[i]] = i;
        }
        return (arr, indexes);
    }

    /**
     * @notice helper function from FlowMatrixGenerator.sol
     * @dev Packs `coords` (of length 3*E) into 6*E bytes:
     *      for each triple (c0, c1, c2), produce c0(16 bits), c1(16 bits), c2(16 bits).
     */
    function _packCoordinates(uint16[] memory coords) internal pure returns (bytes memory) {
        require(coords.length % 3 == 0, "Coords length must be multiple of 3");
        uint256 edgeCount = coords.length / 3;
        bytes memory result = new bytes(edgeCount * 6);

        for (uint256 i = 0; i < edgeCount; i++) {
            // 3 coords per edge
            uint16 c0 = coords[3 * i + 0];
            uint16 c1 = coords[3 * i + 1];
            uint16 c2 = coords[3 * i + 2];

            // Each coord => 2 bytes
            // so offset is i*6
            uint256 offset = i * 6;
            result[offset + 0] = bytes1(uint8(c0 >> 8));
            result[offset + 1] = bytes1(uint8(c0 & 0xFF));
            result[offset + 2] = bytes1(uint8(c1 >> 8));
            result[offset + 3] = bytes1(uint8(c1 & 0xFF));
            result[offset + 4] = bytes1(uint8(c2 >> 8));
            result[offset + 5] = bytes1(uint8(c2 & 0xFF));
        }
        return result;
    }
}
