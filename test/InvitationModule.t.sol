// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {HubStorageWrites} from "test/helpers/HubStorageWrites.sol";
import {IModuleManager} from "src/interfaces/IModuleManager.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {InvitationModule} from "src/InvitationModule.sol";

/**
 * @title InvitationModuleTest
 * @notice Test suite for the InvitationModule contract.
 * @dev This contract tests the functionality of the InvitationModule, including direct and proxy invitations,
 * as well as batch invitations. It uses a forked Gnosis chain environment to simulate real-world conditions.
 * Uncovered branch
 * 1. Branch 0 (path: 0) - Lines 97-102 in the nonReentrant modifier.
 * 2. Branch 5 (path: 0) - Line 199-200 in enforceTrust function.
 * 3. Branch 7 (path: 0) - Line 224-225 in enforceHumanRegistered function.
 * 4. Branch 8 (path: 0) - Lines 253-258.
 */
contract InvitationModuleTest is Test, HubStorageWrites {
    /// @notice The current day, calculated from the block timestamp.
    uint64 public day;
    /// @notice The fork identifier for the Gnosis chain fork.
    uint256 internal gnosisFork;

    /// @notice An instance of the InvitationModule contract.
    InvitationModule public invitationModule;

    /// @notice Error thrown when the invitation fee is not exactly 96 CRC.
    error NotExactInvitationFee();
    /// @notice Error thrown when the data encoding for an invitation is invalid.
    error InvalidEncoding();
    /// @notice Error thrown when a non-human attempts to send an invitation.
    error HumanValidationFailed(address avatar);
    /// @notice Error thrown when a required trust relationship is missing.
    error TrustRequired(address truster, address trustee);
    /// @notice Error thrown when a required module is not enabled for an avatar.
    error ModuleNotEnabled(address avatar);
    /// @notice Error thrown when array lengths mismatch in a batch operation.
    error ArrayLengthMismatch();
    /// @notice Error thrown when a batch invitation has too few invitees.
    error TooFewInvites();
    /// @notice Error thrown when a function is called by an address other than the Hub.
    error OnlyHub();
    /// @notice Error thrown when a human registration fails.
    error HumanRegistrationFailed(address invitee);
    /// @notice Error thrown when an invitee is already registered as a human.
    error InviteeAlreadyRegistered(address invitee);

    /// @notice Event emitted when a new human is registered.
    event RegisterHuman(address indexed human, address indexed originInviter, address indexed proxyInviter);

    /// @notice The address of the original inviter.
    address originInviter = 0x68e3c2aa468D9a80A8d9Bb8fC53bf072FE98B83a;
    /// @notice The address of the proxy inviter.
    address proxyInviter = 0x3A63F544918051f9285cf97008705790FD280012;
    /// @notice The address of the first invitee.
    address invitee1 = 0xFaC83AAc88D48e76C38A2Db49004e6DCfF530e66;
    /// @notice The address of the second invitee.
    address invitee2 = 0x5222D426102052983152dD4b19668f1ddD139E48;

    /**
     * @notice Sets up the test environment before each test case.
     * @dev This function creates a fork of the Gnosis chain, deploys the InvitationModule,
     * sets up test accounts (origin inviter, proxy inviter, and invitees), and enables the
     * InvitationModule for these accounts.
     */
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
            // Revert: Data don't encode invitee address
            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModuleTest.InvalidEncoding.selector, ""));
            IHub(HUB).safeTransferFrom(
                originInviter, address(invitationModule), uint256(uint160(originInviter)), 96 ether, bytes("")
            );
        }
        {
            // Revert: Non human can't invite
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

        // Case 1: OriginInviter has invitation module enabled && originInviter don't trust invitee1 -> valid
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
            assertTrue(IHub(HUB).isTrusted(originInviter, invitee1)); //  oriignInviter now trust invitee1
            assertEq(IHub(HUB).balanceOf(address(invitationModule), uint256(uint160(originInviter))), 0); // invitationModule don't hold anything.

            // Should revert if trying to invite again
            _setCRCBalance(uint256(uint160(originInviter)), originInviter, day, uint192(96 ether));

            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModuleTest.InviteeAlreadyRegistered.selector, invitee1));
            IHub(HUB).safeTransferFrom(
                originInviter,
                address(invitationModule),
                uint256(uint160(originInviter)),
                96 ether,
                abi.encode(invitee1)
            );
            // Note: testing case 2 is trivial as InvitationModule will call `enforceTrust` to set trust to invitee1 anyway
        } else {
            // Case 4: OriginInviter don't have invitation module disabled  && don't trust invitee1 -> revert

            vm.prank(originInviter);
            IModuleManager(originInviter).disableModule(address(0x01), address(invitationModule));

            // originInviter don't trust invitee yet, revert
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

            // Set trust to invitee1
            _setTrust(originInviter, invitee1);

            // Case 3: OriginInviter don't have invitation module enabled, but trust invitee1 -> valid
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

    /**
     * @notice Tests the proxy invitation functionality.
     * @param isModuleEnabled A boolean to control whether the InvitationModule is enabled for the inviters.
     * @dev This test covers three scenarios:
     * 1. Both origin and proxy inviters have the module enabled (should be valid).
     * 2. Both origin and proxy inviters do not have the module enabled (should revert).
     * 3. Origin inviter has the module enabled, but the proxy inviter does not (should revert).
     */
    function testProxyInvite(bool isModuleEnabled) public {
        // Revert: proxyInviter don't trust originInviter
        vm.prank(originInviter);

        vm.expectRevert(
            abi.encodeWithSelector(InvitationModuleTest.TrustRequired.selector, proxyInviter, originInviter)
        );
        IHub(HUB).safeTransferFrom(
            originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, abi.encode(invitee1)
        );
        _setTrust(proxyInviter, originInviter);

        if (isModuleEnabled) {
            // Case 1: originInviter and proxyInviter has module enabled -> valid
            vm.prank(originInviter);
            IHub(HUB).safeTransferFrom(
                originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, abi.encode(invitee1)
            );
            assertTrue(IHub(HUB).isHuman(invitee1));
            assertEq(IHub(HUB).balanceOf(originInviter, uint256(uint160(originInviter))), 96 ether); // originInviter's 96 CRC remains
            assertEq(IHub(HUB).balanceOf(proxyInviter, uint256(uint160(proxyInviter))), 0); // proxyInviter's 96 CRC is burnt
            assertEq(IHub(HUB).balanceOf(invitee1, uint256(uint160(invitee1))), 48 ether); // invitee1 gets invitaiton bonus of own CRC
            assertTrue(IHub(HUB).isTrusted(originInviter, invitee1)); //  originInviter now trust invitee1
            assertTrue(IHub(HUB).isTrusted(proxyInviter, invitee1)); // proxyInviter also trust invitee1 for 1 block
            assertEq(IHub(HUB).balanceOf(address(invitationModule), uint256(uint160(originInviter))), 0); // invitationModule don't hold anything.

            vm.warp(block.timestamp + 1);
            assertFalse(IHub(HUB).isTrusted(proxyInviter, invitee1)); // proxyInviter don't trust invitee1 after 1 block
            return;
        } else {
            vm.prank(originInviter);
            IModuleManager(originInviter).disableModule(address(0x01), address(invitationModule));

            vm.prank(proxyInviter);
            IModuleManager(proxyInviter).disableModule(address(0x01), address(invitationModule));

            // Case 2: originInviter && proxyInviter don't have module enabled
            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModuleTest.ModuleNotEnabled.selector, originInviter));
            IHub(HUB).safeTransferFrom(
                originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, abi.encode(invitee1)
            );

            vm.prank(originInviter);
            IModuleManager(originInviter).enableModule(address(invitationModule));

            // Case 3: originInviter have invitationModule &&  proxyInviter don't have invitationModule enabled
            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModuleTest.ModuleNotEnabled.selector, proxyInviter));
            IHub(HUB).safeTransferFrom(
                originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, abi.encode(invitee1)
            );

            vm.prank(proxyInviter);
            IModuleManager(proxyInviter).enableModule(address(invitationModule));

            // Both originInviter && proxyInviter have invitationModule enabled -> fallbacl to case 1 -> valid
            vm.prank(originInviter);
            IHub(HUB).safeTransferFrom(
                originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, abi.encode(invitee1)
            );
            assertTrue(IHub(HUB).isHuman(invitee1));
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
            vm.expectRevert(abi.encodeWithSelector(InvitationModuleTest.NotExactInvitationFee.selector));
            IHub(HUB).safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, abi.encode(invitees));

            values[1] = 96 ether;

            // Revert: Invalid data that will get _isGenericCall(data) == true, but fail at calling genericCallProxy
            address randomAddress = makeAddr("randomAddr");
            bytes memory data = abi.encode(randomAddress);
            vm.assume(uint256(uint160(randomAddress)) > data.length);

            vm.prank(originInviter);
            vm.expectRevert();
            IHub(HUB).safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, data);

            // Valid case
            vm.prank(originInviter);
            IHub(HUB).safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, abi.encode(invitees));

            assertTrue(IHub(HUB).isHuman(invitee1));
            assertTrue(IHub(HUB).isHuman(invitee2));
            assertEq(IHub(HUB).balanceOf(originInviter, uint256(uint160(originInviter))), 0); // originInviter's 192 CRC is burnt
            assertEq(IHub(HUB).balanceOf(invitee1, uint256(uint160(invitee1))), 48 ether); // invitee1 gets invitaiton bonus of own CRC
            assertEq(IHub(HUB).balanceOf(invitee2, uint256(uint160(invitee2))), 48 ether); // invitee2 gets invitaiton bonus of own CRC
            assertTrue(IHub(HUB).isTrusted(originInviter, invitee1));
            assertTrue(IHub(HUB).isTrusted(originInviter, invitee2));
            assertEq(IHub(HUB).balanceOf(address(invitationModule), uint256(uint160(originInviter))), 0); // invitationModule don't hold anything.
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
            values[0] = 92 ether;
            values[1] = 96 ether; // Not enough CRC

            // Revert: Not enough CRC for invitation
            vm.prank(originInviter);
            vm.expectRevert(abi.encodeWithSelector(InvitationModuleTest.NotExactInvitationFee.selector));
            IHub(HUB).safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, abi.encode(invitees));

            values[0] = 96 ether;

            // Revert: proxy Inviter don't trust Invitee
            vm.prank(originInviter);
            vm.expectRevert(
                abi.encodeWithSelector(InvitationModuleTest.TrustRequired.selector, proxyInviter, originInviter)
            );
            IHub(HUB).safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, abi.encode(invitees));

            _setTrust(proxyInviter, originInviter);

            // Revert: Invalid data that will get _isGenericCall(data) == true, but fail at calling genericCallProxy
            address randomAddress = makeAddr("randomAddr");
            bytes memory data = abi.encode(randomAddress);
            vm.assume(uint256(uint160(randomAddress)) > data.length);

            vm.prank(originInviter);
            vm.expectRevert();
            IHub(HUB).safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, data);

            // Valid case
            vm.prank(originInviter);
            IHub(HUB).safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, abi.encode(invitees));

            assertTrue(IHub(HUB).isHuman(invitee1));
            assertTrue(IHub(HUB).isHuman(invitee2));
            assertEq(IHub(HUB).balanceOf(originInviter, uint256(uint160(proxyInviter))), 0); // originInviter's proxyInviter 192 CRC is burnt
            assertEq(IHub(HUB).balanceOf(invitee1, uint256(uint160(invitee1))), 48 ether); // invitee1 gets invitaiton bonus of own CRC
            assertEq(IHub(HUB).balanceOf(invitee2, uint256(uint160(invitee2))), 48 ether); // invitee2 gets invitaiton bonus of own CRC
            assertTrue(IHub(HUB).isTrusted(originInviter, invitee1));
            assertTrue(IHub(HUB).isTrusted(originInviter, invitee2));
            assertTrue(IHub(HUB).isTrusted(proxyInviter, invitee1));
            assertTrue(IHub(HUB).isTrusted(proxyInviter, invitee2));
            assertEq(IHub(HUB).balanceOf(address(invitationModule), uint256(uint160(originInviter))), 0); // invitationModule don't hold anything.

            vm.warp(block.timestamp + 1);
            assertFalse(IHub(HUB).isTrusted(proxyInviter, invitee1));
            assertFalse(IHub(HUB).isTrusted(proxyInviter, invitee2));
        }
    }

    /**
     * @notice Tests that the ERC1155 receiver hooks can only be called by the Hub.
     * @dev This test ensures that `onERC1155Received` and `onERC1155BatchReceived` revert
     * when called by an address other than the Hub, preventing unauthorized token transfers.
     */
    function testOnlyHub() public {
        vm.prank(makeAddr("randomAddress"));
        vm.expectRevert(abi.encodeWithSelector(InvitationModuleTest.OnlyHub.selector));
        invitationModule.onERC1155Received(makeAddr("randomAddress"), originInviter, 0, 96 ether, "");

        uint256[] memory ids = new uint256[](2);
        ids[0] = uint256(uint160(originInviter));
        ids[1] = uint256(uint160(originInviter));

        uint256[] memory values = new uint256[](2);
        values[0] = 96 ether;
        values[1] = 96 ether;
        vm.expectRevert(abi.encodeWithSelector(InvitationModuleTest.OnlyHub.selector));
        invitationModule.onERC1155BatchReceived(makeAddr("randomAddress"), originInviter, ids, values, "");
    }
}
