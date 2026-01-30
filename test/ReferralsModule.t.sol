// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {HubStorageWrites} from "test/helpers/HubStorageWrites.sol";
import {IModuleManager} from "src/interfaces/IModuleManager.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {InvitationModule} from "src/InvitationModule.sol";
import {ReferralsModule} from "src/ReferralsModule.sol";
import {CirclesV2Setup} from "test/helpers/CirclesV2Setup.sol";

/// @title Affiliate Group Registry Interface
/// @notice Interface for managing affiliate group registrations
interface IAffiliateGroupRegistry {
    /// @notice Get the affiliate group for an account
    /// @param account The account address to query
    /// @return The affiliate group address
    function affiliateGroup(address account) external view returns (address);
}

/// @title Safe Interface
/// @notice Interface for interacting with Safe contracts
interface ISafe {
    /// @notice Get storage data at specific offset and length
    /// @param offset Storage offset
    /// @param length Data length to read
    /// @return Storage data as bytes
    function getStorageAt(uint256 offset, uint256 length) external view returns (bytes memory);

    /// @notice Get modules paginated
    /// @param start Starting address for pagination
    /// @param pageSize Number of modules to return
    /// @return array Array of module addresses
    /// @return next Next address for pagination
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);

    /// @notice Check if module is enabled
    /// @param module Module address to check
    /// @return True if module is enabled
    function isModuleEnabled(address module) external view returns (bool);

    /// @notice Check if address is an owner
    /// @param owner Address to check
    /// @return True if address is owner
    function isOwner(address owner) external view returns (bool);
}

/// @title ReferralsModule Test Contract
/// @dev Tests account creation, claiming, and referral system features
contract ReferralsModuleTest is CirclesV2Setup, HubStorageWrites {
    struct Signer {
        uint256 x;
        uint256 y;
        address verifier; // use address instead of original P256.Verifiers
    }
    /// @dev Storage slot for passkey signer data
    /// https://github.com/safe-fndn/safe-modules/blob/4367ecf2/modules/passkey/contracts/4337/SafeWebAuthnSharedSigner.sol#L13-L167
    /// SIGNER_SLOT = uint256(keccak256(abi.encode(address(SafeWebAuthnSharedSigner), _SIGNER_MAPPING_SLOT)));
    uint256 internal constant SIGNER_SLOT =
        38553689938471249931580260399865754279307054632110400389912672281974829735002;

    /// @dev Address of the affiliate group registry contract
    address internal constant AFFILIATE_GROUP_REGISTRY = address(0xca8222e780d046707083f51377B5Fd85E2866014);

    /// @dev Address of the Safe WebAuthn shared signer contract
    address internal constant SAFE_WEB_AUTHN_SHARED_SIGNER = address(0xfD90FAd33ee8b58f32c00aceEad1358e4AFC23f9);

    bytes constant SAFE_PROXY_BYTECODE =
        hex"608060405273ffffffffffffffffffffffffffffffffffffffff600054167fa619486e0000000000000000000000000000000000000000000000000000000060003514156050578060005260206000f35b3660008037600080366000845af43d6000803e60008114156070573d6000fd5b3d6000f3fea264697066735822122003d1488ee65e08fa41e58e888a9865554c535f2c77126a82cb4c0f917f31441364736f6c63430007060033";

    address internal constant SAFE_4337_MODULE = address(0x75cf11467937ce3F2f357CE24ffc3DBF8fD5c226);

    /// @dev Current day timestamp for testing
    uint64 public day;

    /// @dev Fork identifier for Gnosis chain
    uint256 internal gnosisFork;

    /// @dev Instance of InvitationModule contract for testing
    InvitationModule public invitationModule;

    /// @dev Instance of ReferralsModule contract for testing
    ReferralsModule public referralsModule;

    /// @dev Test address for origin inviter
    address originInviter = makeAddr("originInviter");

    /// @dev Test address for proxy inviter
    address proxyInviter = makeAddr("proxyInviter");

    // test passkeys
    /// @dev FCLP256Verifier contract for passkey authentication
    address verifier = 0x445a0683e494ea0c5AF3E83c5159fBE47Cf9e765;

    /// @dev Test passkey x coordinate for first test account
    uint256 x1 = uint256(bytes32(0x38ba1c26626f1c581a0b7579ebb079796a99dceb883dc952b48cf508672bd284));

    /// @dev Test passkey y coordinate for first test account
    uint256 y1 = uint256(bytes32(0x2a7c0bdfd8d5c956e779cdc862e0ea5754b74e08b0653b9ac55bbf7e8162d1b8));

    /// @dev Test passkey x coordinate for second test account
    uint256 x2 = uint256(bytes32(0x5d8143d72a093152c79931547e0dfed15c78359fff7269a166b196bb5e4a40e7));

    /// @dev Test passkey y coordinate for second test account
    uint256 y2 = uint256(bytes32(0x8328a3ee26970409ad6a50e90efe97bbf4662d72ba0cc7d61853a2e2212ac02b));

    /// @dev Test metadata digest for account registration
    bytes32 metadataDigest = 0x9f24ca27dfd6847edbde6f254485635757ebbf7a2eb76e406046f527bffaeb86; // random bytes32

    // test offchain secrets
    /// @dev Test signer address for first account
    address signer1;

    /// @dev Private key for first test signer
    uint256 pk1;

    /// @dev Test signer address for second account
    address signer2;

    /// @dev Private key for second test signer
    uint256 pk2;

    /// @dev Error thrown when trying to reuse a signer that's already been used
    error SignerAlreadyUsed();

    /// @dev Error thrown when a generic call reverts with specific revert data
    error GenericCallReverted(bytes revertData);

    /// @dev Error thrown when caller is not the generic call proxy
    error OnlyGenericCallProxy();

    /// @dev Error thrown when trying to claim an account that's already been claimed
    error AccountAlreadyClaimed();

    /// @dev Error thrown when an invalid signature is provided
    error InvalidSignature();

    /// @notice Set up test environment with fork, contracts, and test accounts
    /// @dev Initializes Gnosis fork, deploys contracts, and sets up test scenario
    function setUp() public override {
        super.setUp();
        vm.warp(INVITATION_ONLY_TIME + 1);

        invitationModule = new InvitationModule();
        referralsModule = new ReferralsModule(address(invitationModule));

        (signer1, pk1) = makeAddrAndKey("signer1");
        (signer2, pk2) = makeAddrAndKey("signer2");

        // set current day
        day = HUB_V2.day(block.timestamp);
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

        // enable invitation module for actors
        vm.prank(proxyInviter);
        IModuleManager(proxyInviter).enableModule(address(invitationModule));
        vm.prank(originInviter);
        IModuleManager(originInviter).enableModule(address(invitationModule));

        // set proxy trust origin (the requirement to involve as proxy inviter)
        _setTrust(proxyInviter, originInviter);
    }

    function testCreateSingleAccount() public {
        bytes memory data = abi.encode(
            address(referralsModule), abi.encodeWithSelector(bytes4(ReferralsModule.createAccount.selector), signer1)
        );

        // create 1 referral using proxy CRC
        vm.startPrank(originInviter);

        HUB_V2.safeTransferFrom(
            originInviter, address(invitationModule), uint256(uint160(proxyInviter)), 96 ether, data
        );

        vm.stopPrank();

        (address account1, bool isClaimed1) = referralsModule.accounts(signer1);

        assertEq(account1, referralsModule.computeAddress(signer1));
        assertEq(isClaimed1, false);
        assertTrue(account1.code.length > 0);
        assertEq(account1.code, SAFE_PROXY_BYTECODE);
        assertTrue(ISafe(account1).isOwner(SAFE_WEB_AUTHN_SHARED_SIGNER));
        assertTrue(ISafe(account1).isModuleEnabled(address(referralsModule)));
        assertTrue(ISafe(account1).isModuleEnabled(address(invitationModule)));
        assertTrue(ISafe(account1).isModuleEnabled(SAFE_4337_MODULE));
        assertTrue(_isSignerSlotEmptyInSafeWebAuthnSharedSigner(account1));

        assertEq(HUB_V2.balanceOf(address(invitationModule), uint256(uint160(originInviter))), 0);
        assertEq(HUB_V2.balanceOf(address(invitationModule), uint256(uint160(proxyInviter))), 0);
        assertEq(HUB_V2.balanceOf(address(referralsModule), uint256(uint160(originInviter))), 0);
        assertEq(HUB_V2.balanceOf(address(referralsModule), uint256(uint160(proxyInviter))), 0);
        assertEq(HUB_V2.balanceOf(account1, uint256(uint160(account1))), 48 ether);

        vm.stopPrank();
    }

    /// @notice Test creating referral accounts through the invitation system
    /// @dev Tests the complete flow of creating accounts via batch transfer to invitation module
    function testCreateAccounts() public {
        // the public addresses of offchain shared secrets
        address[] memory signers = new address[](2);
        signers[0] = signer1;
        signers[1] = signer2;

        bytes memory data = abi.encode(
            address(referralsModule), abi.encodeWithSelector(bytes4(ReferralsModule.createAccounts.selector), signers)
        );

        // create 2 referrals using own and proxy CRCs
        vm.startPrank(originInviter);
        uint256[] memory ids = new uint256[](2);
        ids[0] = uint256(uint160(originInviter));
        ids[1] = uint256(uint160(proxyInviter));
        uint256[] memory values = new uint256[](ids.length);
        for (uint256 i; i < values.length; i++) {
            values[i] = 96 ether;
        }

        HUB_V2.safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, data);

        vm.stopPrank();

        (address account1, bool isClaimed1) = referralsModule.accounts(signer1);
        (address account2, bool isClaimed2) = referralsModule.accounts(signer2);

        assertEq(account1, referralsModule.computeAddress(signer1));
        assertEq(isClaimed1, false);
        assertTrue(account1.code.length > 0);
        assertEq(account1.code, SAFE_PROXY_BYTECODE);
        assertTrue(ISafe(account1).isOwner(SAFE_WEB_AUTHN_SHARED_SIGNER));
        assertTrue(ISafe(account1).isModuleEnabled(address(referralsModule)));
        assertTrue(ISafe(account1).isModuleEnabled(address(invitationModule)));
        assertTrue(ISafe(account1).isModuleEnabled(SAFE_4337_MODULE));
        assertTrue(_isSignerSlotEmptyInSafeWebAuthnSharedSigner(account1));

        assertEq(account2, referralsModule.computeAddress(signer2));
        assertEq(isClaimed2, false);
        assertTrue(account2.code.length > 0);
        assertEq(account2.code, SAFE_PROXY_BYTECODE);
        assertTrue(ISafe(account2).isOwner(SAFE_WEB_AUTHN_SHARED_SIGNER));
        assertTrue(ISafe(account2).isModuleEnabled(address(referralsModule)));
        assertTrue(ISafe(account2).isModuleEnabled(address(invitationModule)));
        assertTrue(ISafe(account2).isModuleEnabled(SAFE_4337_MODULE));
        assertTrue(_isSignerSlotEmptyInSafeWebAuthnSharedSigner(account2));

        assertEq(HUB_V2.balanceOf(address(invitationModule), uint256(uint160(originInviter))), 0);
        assertEq(HUB_V2.balanceOf(address(invitationModule), uint256(uint160(proxyInviter))), 0);
        assertEq(HUB_V2.balanceOf(address(referralsModule), uint256(uint160(originInviter))), 0);
        assertEq(HUB_V2.balanceOf(address(referralsModule), uint256(uint160(proxyInviter))), 0);
        assertEq(HUB_V2.balanceOf(account1, uint256(uint160(account1))), 48 ether);
        assertEq(HUB_V2.balanceOf(account2, uint256(uint160(account2))), 48 ether);

        _setCRCBalance(uint256(uint160(originInviter)), originInviter, day, uint192(96 ether));
        _setCRCBalance(uint256(uint160(proxyInviter)), originInviter, day, uint192(96 ether));

        // Revert: try to call createAccount again with the same signer
        vm.startPrank(originInviter);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReferralsModuleTest.GenericCallReverted.selector,
                abi.encodePacked(ReferralsModuleTest.SignerAlreadyUsed.selector)
            )
        );
        HUB_V2.safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, data);

        vm.stopPrank();
    }

    /// @notice Test that only the generic call proxy can call referral functions
    /// @dev Verifies access control for createAccount and createAccounts functions
    function testOnlyGeneralCallProxy() public {
        address[] memory signers = new address[](2);
        signers[0] = signer1;
        signers[1] = signer2;

        address genericCallProxy = address(invitationModule.GENERIC_CALL_PROXY());
        address alice = makeAddr("alice");
        vm.assume(alice != genericCallProxy);
        vm.prank(alice);
        vm.expectRevert(ReferralsModuleTest.OnlyGenericCallProxy.selector);
        referralsModule.createAccount(signer1);

        vm.prank(alice);
        vm.expectRevert(ReferralsModuleTest.OnlyGenericCallProxy.selector);
        referralsModule.createAccounts(signers);
    }

    /// @notice Test claiming accounts with stored signer
    /// @dev Tests the complete flow of claiming accounts with various scenarios and edge cases
    /// @param claimTimestamp Fuzz test parameter for claim timing
    function testClaimAccountOnly(uint256 claimTimestamp) public {
        claimTimestamp = claimTimestamp % 100 * 24 * 60 * 60;

        _createAccount();

        bytes32 digest = referralsModule.getPasskeyHash(x1, y1, verifier);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk1, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        referralsModule.claimAccount(x1, y1, verifier, signature, metadataDigest);

        (address account1, bool isClaimed1) = referralsModule.accounts(signer1);

        assertTrue(HUB_V2.isHuman(account1));
        assertEq(HUB_V2.balanceOf(account1, uint256(uint160(account1))), 48 ether);
        assertEq(NAME_REGISTRY.avatarToMetaDataDigest(account1), metadataDigest);
        assertFalse(ISafe(account1).isModuleEnabled(address(referralsModule)));
        assertEq(isClaimed1, true);
        assertTrue(ISafe(account1).isOwner(SAFE_WEB_AUTHN_SHARED_SIGNER));
        assertFalse(ISafe(account1).isOwner(signer1));

        bytes memory passkey = abi.encode(x1, y1, verifier);
        bytes memory storedPasskey = ISafe(account1).getStorageAt(SIGNER_SLOT, 3);
        assertEq(keccak256(passkey), keccak256(storedPasskey));

        // Revert: Invalid signature
        bytes memory invalidSignature = abi.encodePacked(r, s);
        vm.expectRevert(ReferralsModuleTest.InvalidSignature.selector);
        referralsModule.claimAccount(x1, y1, verifier, invalidSignature, metadataDigest);

        // Revert: Try to claim the same account
        vm.expectRevert(ReferralsModuleTest.AccountAlreadyClaimed.selector);
        referralsModule.claimAccount(x1, y1, verifier, signature, metadataDigest);

        // Revert: invalid signer
        (, uint256 pkIS) = makeAddrAndKey("invalidSigner");
        (v, r, s) = vm.sign(pkIS, digest);
        signature = abi.encodePacked(r, s, v);
        vm.expectRevert(ReferralsModuleTest.InvalidSignature.selector);
        referralsModule.claimAccount(x1, y1, verifier, signature, metadataDigest);

        // Test claiming account in many days later

        vm.warp(block.timestamp + claimTimestamp);

        digest = referralsModule.getPasskeyHash(x2, y2, verifier);

        (v, r, s) = vm.sign(pk2, digest);
        signature = abi.encodePacked(r, s, v);

        referralsModule.claimAccount(x2, y2, verifier, signature, metadataDigest);

        (address account2, bool isClaimed2) = referralsModule.accounts(signer2);

        assertTrue(HUB_V2.isHuman(account2));
        assertEq(HUB_V2.balanceOf(account2, uint256(uint160(account2))), 48 ether);
        assertEq(NAME_REGISTRY.avatarToMetaDataDigest(account2), metadataDigest);
        assertEq(isClaimed2, true);
        assertFalse(ISafe(account2).isModuleEnabled(address(referralsModule)));
        assertTrue(ISafe(account2).isOwner(SAFE_WEB_AUTHN_SHARED_SIGNER));
        assertFalse(ISafe(account2).isOwner(signer2));
        passkey = abi.encode(x2, y2, verifier);
        storedPasskey = ISafe(account2).getStorageAt(SIGNER_SLOT, 3);
        assertEq(keccak256(passkey), keccak256(storedPasskey));
    }

    /// @notice Test claiming account with affiliate group registration
    /// @dev Tests claiming an account and associating it with an affiliate group
    function testClaimAccountWithAffiliateGroup() public {
        // the public addresses of offchain shared secrets
        _createAccount();

        bytes32 digest = referralsModule.getPasskeyHash(x1, y1, verifier);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk1, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        address affiliateGroup = 0xC19BC204eb1c1D5B3FE500E5E5dfaBaB625F286c; // Gnosis group
        vm.prank(affiliateGroup);
        HUB_V2.registerGroup(makeAddr("mint"), "test-group", "GRP", "");

        referralsModule.claimAccount(x1, y1, verifier, signature, metadataDigest, affiliateGroup);

        (address account, bool isClaimed) = referralsModule.accounts(signer1);
        assertEq(IAffiliateGroupRegistry(AFFILIATE_GROUP_REGISTRY).affiliateGroup(account), affiliateGroup);
        assertFalse(ISafe(account).isModuleEnabled(address(referralsModule)));
        assertTrue(HUB_V2.isHuman(account));
        assertEq(HUB_V2.balanceOf(account, uint256(uint160(account))), 48 ether);
        assertEq(NAME_REGISTRY.avatarToMetaDataDigest(account), metadataDigest);
        assertEq(isClaimed, true);
        assertFalse(ISafe(account).isModuleEnabled(address(referralsModule)));
        assertTrue(ISafe(account).isOwner(SAFE_WEB_AUTHN_SHARED_SIGNER));
        assertFalse(ISafe(account).isOwner(signer2));
    }

    /// @notice Helper function to create accounts for testing
    /// @dev Creates two test accounts using the referrals module via batch transfer
    function _createAccount() internal {
        address[] memory signers = new address[](2);
        signers[0] = signer1;
        signers[1] = signer2;

        bytes memory data = abi.encode(
            address(referralsModule), abi.encodeWithSelector(bytes4(ReferralsModule.createAccounts.selector), signers)
        );

        // create 2 referrals using own and proxy CRCs
        vm.startPrank(originInviter);
        uint256[] memory ids = new uint256[](2);
        ids[0] = uint256(uint160(originInviter));
        ids[1] = uint256(uint160(proxyInviter));
        uint256[] memory values = new uint256[](ids.length);
        for (uint256 i; i < values.length; i++) {
            values[i] = 96 ether;
        }

        HUB_V2.safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, data);

        vm.stopPrank();
    }

    function _isSignerSlotEmptyInSafeWebAuthnSharedSigner(address account) internal view returns (bool) {
        // Dev: implementation copied from rom SafeWebAuthnSharedSigner contract
        bytes memory getStorageAtData = abi.encodeCall(ISafe(account).getStorageAt, (SIGNER_SLOT, 3));
        Signer memory signer;
        // Call the {StorageAccessible.getStorageAt} with assembly. This allows us to return a
        // zeroed out signer configuration instead of reverting for `account`s that are not Safes.
        // We also, expect the implementation to behave **exactly** like the Safe's - that is it
        // should encode the return data using a standard ABI encoding:
        // - The first 32 bytes is the offset of the values bytes array, always `0x20`
        // - The second 32 bytes is the length of the values bytes array, always `0x60`
        // - the following 3 words (96 bytes) are the values of the signer configuration.

        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            // Note that Yul expressions are evaluated in reverse order, so the `staticcall` is the
            // first thing to be evaluated in the nested `and` expression.
            if and(
                and(
                    // The offset of the ABI encoded bytes is 0x20, this should always be the case
                    // for standard ABI encoding of `(bytes)` tuple that `getStorageAt` returns.
                    eq(mload(0x00), 0x20),
                    // The length of the encoded bytes is exactly 0x60 bytes (i.e. 3 words, which is
                    // exactly how much we read from the Safe's storage in the `getStorageAt` call).
                    eq(mload(0x20), 0x60)
                ),
                and(
                    // The length of the return data should be exactly 0xa0 bytes, which should
                    // always be the case for the Safe's `getStorageAt` implementation.
                    eq(returndatasize(), 0xa0),
                    // The call succeeded. We write the first two words of the return data into the
                    // scratch space, as we need to inspect them before copying the signer
                    // signer configuration to our `signer` memory pointer.
                    staticcall(gas(), account, add(getStorageAtData, 0x20), mload(getStorageAtData), 0x00, 0x40)
                )
            ) {
                // Copy only the storage values from the return data to our `signer` memory address.
                // This only happens on success, so the `signer` value will be zeroed out if any of
                // the above conditions fail, indicating that no signer is configured.
                returndatacopy(signer, 0x40, 0x60)
            }
        }
        return signer.x == 0 && signer.y == 0 && signer.verifier == address(0);
    }
}
