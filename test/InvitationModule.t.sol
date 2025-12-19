// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {HubStorageWrites} from "test/helpers/HubStorageWrites.sol";
import {IModuleManager} from "src/interfaces/IModuleManager.sol";
import {IHub} from "test/helpers/CirclesV2Setup.sol";
import {InvitationModule} from "src/InvitationModule.sol";
import {GenericCallProxy} from "src/GenericCallProxy.sol";
import {CirclesV2Setup} from "test/helpers/CirclesV2Setup.sol";
import {FakeSafeAlwaysTrue, FakeSafeAlwaysFalse} from "test/helpers/FakeSafe.sol";

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
     * @param isModuleEnabled A boolean to control whether the InvitationModule is enabled for the origin inviter.
     * @dev This test covers four scenarios:
     * 1. Origin inviter has the module enabled and doesn't trust the invitee (should be valid).
     * 2. Origin inviter has the module enabled and trusts the invitee (should be valid).
     * 3. Origin inviter doesn't have the module enabled but trusts the invitee (should be valid).
     * 4. Origin inviter doesn't have the module enabled and doesn't trust the invitee (should revert).
     */
    function testDirectInvite(bool isModuleEnabled) public {
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

        // Case 1: OriginInviter has invitation module enabled && originInviter don't trust invitee1 -> valid
        if (isModuleEnabled) {
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
        } else {
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
     * @param isModuleEnabled A boolean to control whether the InvitationModule is enabled for the inviters.
     * @dev This test covers three scenarios:
     * 1. Both origin and proxy inviters have the module enabled (should be valid).
     * 2. Both origin and proxy inviters do not have the module enabled (should revert).
     * 3. Origin inviter has the module enabled, but the proxy inviter does not (should revert).
     */
    function testProxyInvite(bool isModuleEnabled) public {
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

        if (isModuleEnabled) {
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

            return;
        } else {
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
            return;
        }
    }

    /**
     * @notice Tests the batch direct invitation functionality.
     * @dev This test verifies that multiple invitees can be invited in a single transaction.
     * It also checks for various failure conditions, such as insufficient CRC, invalid data,
     * and unreachable code paths.
     */
    function testBatchDirectInvite() public {
        _setCRCBalance(uint256(uint160(originInviter)), originInviter, day, uint192(192 ether));

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

            // Revert: Invalid data that will get _isGenericCall(data) == true, but fail at calling genericCallProxy
            address randomAddress = makeAddr("randomAddr");
            bytes memory data = abi.encode(randomAddress);
            vm.assume(uint256(uint160(randomAddress)) > data.length);

            vm.prank(originInviter);
            vm.expectRevert();
            HUB_V2.safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, data);

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
    function testBatchProxyInvite() public {
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
            address randomAddress = makeAddr("randomAddr");
            bytes memory data = abi.encode(randomAddress);
            vm.assume(uint256(uint160(randomAddress)) > data.length);

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
                GenericCallProxy.GenericCallReverted.selector,
                abi.encodePacked(InvitationModuleTest.Reentrancy.selector)
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
                GenericCallProxy.GenericCallReverted.selector,
                abi.encodePacked(InvitationModuleTest.Reentrancy.selector)
            )
        ); // revert GenericCallReverted(Reentrancy())
        HUB_V2.safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, fullCalldataWithAddr);
    }
}
