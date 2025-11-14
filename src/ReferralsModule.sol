// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IModuleManager} from "src/interfaces/IModuleManager.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {INameRegistry} from "src/interfaces/INameRegistry.sol";
import {IAffiliateGroupRegistry} from "src/interfaces/IAffiliateGroupRegistry.sol";
import {ISafeProxyFactory} from "src/interfaces/ISafeProxyFactory.sol";
import {ISafe} from "src/interfaces/ISafe.sol";
import {ISafeModuleSetup} from "src/interfaces/ISafeModuleSetup.sol";
import {ISafeWebAuthnSharedSigner} from "src/interfaces/ISafeWebAuthnSharedSigner.sol";
import {IInvitationModule} from "src/interfaces/IInvitationModule.sol";

/// @title ReferralsModule
/// @notice Pre-deploys “pre-made” human CRC Safe accounts on behalf of origin inviters, and lets invited humans
///         claim those Safes using a device WebAuthn passkey plus an offchain secret provided by the origin inviter.
/// @dev
/// - Account creation is triggered by the Invitation Module’s Generic Call Proxy.
/// - Flow narrative:
///   1) Origin inviter generates an offchain secret key and derives its public address `signer`.
///   2) Origin inviter shares the secret key privately with the human they invite.
///   3) This module pre-deploys a Safe for `signer`, enabling the required modules.
///   4) The invited human generates a device passkey and submits an EIP-712 signature using the shared secret key,
///      authorizing configuration of the shared WebAuthn signer inside their Safe.
///   5) The module finalizes ownership (configures passkey), normalizes CRC to the welcome bonus, optionally
///      updates metadata / affiliate group, and then disables itself on the Safe.
contract ReferralsModule {
    /*//////////////////////////////////////////////////////////////
                                Structs
    //////////////////////////////////////////////////////////////*/

    /// @notice Parameters for configuring the Safe WebAuthn shared signer once the human claims.
    /// @dev These fields are encoded in an EIP-712 message that the invitee signs using the offchain secret key.
    /// @param x The X coordinate of the WebAuthn public key.
    /// @param y The Y coordinate of the WebAuthn public key.
    /// @param verifier The WebAuthn verifier/authenticator contract address.
    struct Passkey {
        uint256 x;
        uint256 y;
        address verifier;
    }

    /// @notice Minimal account record keyed by the origin inviter’s offchain public address `signer`.
    /// @dev `account` is the deployed Safe. `claimed` flips true when the human claims.
    /// @param account The deployed Safe address tied to the `signer`.
    /// @param claimed Whether the account has already been claimed.
    struct Account {
        address account;
        bool claimed;
    }

    /*//////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a function restricted to the Invitation Module Generic Call Proxy is called by another address.
    error OnlyGenericCallProxy();

    /// @notice Thrown when the EIP-712 claim signature is malformed or resolves to no pre-deployed account.
    error InvalidSignature();

    /// @notice Thrown when attempting to create an account for a signer that already has one.
    error SignerAlreadyUsed();

    /// @notice Thrown when attempting to claim an account that has already been claimed.
    error AccountAlreadyClaimed();

    /*//////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a pre-made Safe is deployed for an origin inviter’s `signer`.
    /// @param account The pre-deployed Safe address that awaits claim by the invitee.
    event AccountCreated(address indexed account);

    /// @notice Emitted after a successful human claim when this module disables itself on the Safe.
    /// @param account The claimed Safe address.
    event AccountClaimed(address indexed account);

    /*//////////////////////////////////////////////////////////////
                              Constants & Immutables
    //////////////////////////////////////////////////////////////*/

    /// @notice Circles v2 Hub contract.
    address internal constant HUB = address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8);

    /// @notice Target welcome CRC balance after claim completes.
    /// @dev After calling `personalMint`, any CRC above this amount is burned to normalize the balance.
    uint256 internal constant WELCOME_BONUS = 48 ether;

    /// @notice Circles v2 Name Registry contract.
    address internal constant NAME_REGISTRY = address(0xA27566fD89162cC3D40Cb59c87AAaA49B85F3474);

    /// @notice Circles Affiliate Group Registry contract.
    address internal constant AFFILIATE_GROUP_REGISTRY = address(0xca8222e780d046707083f51377B5Fd85E2866014);

    /// @notice Invitation Module address used during Safe setup.
    /// @dev Set once during construction.
    address internal immutable INVITATION_MODULE;

    /// @notice Generic Call Proxy owned by the Invitation Module that is authorized to trigger account creation.
    /// @dev Retrieved from the Invitation Module during construction.
    address internal immutable GENERIC_CALL_PROXY;

    /// @notice Safe Proxy Factory used to deploy Safe proxies.
    ISafeProxyFactory internal constant SAFE_PROXY_FACTORY =
        ISafeProxyFactory(address(0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67));

    /// @notice Safe singleton (implementation) used by the proxy.
    address internal constant SAFE_SINGLETON = address(0x29fcB43b46531BcA003ddC8FCB67FFE91900C762);

    /// @notice Safe ERC-4337 module enabled on deployed Safes.
    address internal constant SAFE_4337_MODULE = address(0x75cf11467937ce3F2f357CE24ffc3DBF8fD5c226);

    /// @notice Helper contract to enable a list of Safe modules at setup time.
    address internal constant SAFE_MODULE_SETUP = address(0x2dd68b007B46fBe91B9A7c3EDa5A7a1063cB5b47);

    /// @notice Safe WebAuthn Shared Signer owner to be configured during claim with the invitee’s device passkey.
    address internal constant SAFE_WEB_AUTHN_SHARED_SIGNER = address(0xfD90FAd33ee8b58f32c00aceEad1358e4AFC23f9);

    /// @notice Sentinel address used by Safe for module linked-list operations.
    address internal constant SENTINEL = address(1);

    /// @notice Precomputed initializer hash used in CREATE2 salt for deterministic address prediction.
    bytes32 internal immutable ACCOUNT_INITIALIZER_HASH;

    /// @notice Safe proxy creation code hash used in CREATE2 address prediction.
    bytes32 internal constant ACCOUNT_CREATION_CODE_HASH =
        0xe298282cefe913ab5d282047161268a8222e4bd4ed106300c547894bbefd31ee;

    /// @notice Typehash of EIP-712 domain separator.
    /// @dev keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    bytes32 internal constant DOMAIN_SEPARATOR_TYPEHASH =
        0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    /// @notice Typehash for the Passkey struct used in the EIP-712 digest.
    /// @dev keccak256("Passkey(uint256 x,uint256 y,address verifier)")
    bytes32 internal constant PASSKEY_TYPEHASH = 0x6f5bf8ecc7e0e1deab50ed1bf5eaaa272c6dc0147cfa7f55c7e7551bc5ff0751;

    /// @notice EIP-712 domain separator bound to this chain and contract instance.
    bytes32 public immutable DOMAIN_SEPARATOR;

    /*//////////////////////////////////////////////////////////////
                                Storage
    //////////////////////////////////////////////////////////////*/

    /// @notice Maps the offchain `signer` (origin inviter’s generated public address) to the pre-made account record.
    /// @dev
    /// - `accounts[signer].account` is the pre-deployed Safe (zero until created).
    /// - `accounts[signer].claimed` flips after a successful claim by the invitee.
    mapping(address signer => Account) public accounts;

    /*//////////////////////////////////////////////////////////////
                                 Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts execution to the Invitation Module Generic Call Proxy.
    /// @dev Reverts with {OnlyGenericCallProxy} when `msg.sender` is not the proxy.
    modifier onlyGenericCallProxy() {
        if (msg.sender != GENERIC_CALL_PROXY) revert OnlyGenericCallProxy();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               Constructor
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes immutable references and computes the EIP-712 domain separator.
    /// @dev
    /// - Stores the Invitation Module address and loads its associated `GENERIC_CALL_PROXY`.
    /// - Computes the EIP-712 domain separator for this contract instance using:
    ///       name = "ReferralsModule", version = "1", chainId = block.chainid.
    /// - Calls {_initializer()} to build the Safe setup calldata and pre-computes its
    ///   `ACCOUNT_INITIALIZER_HASH`, which is later combined with each `signer` to form the
    ///   CREATE2 salt used by `createProxyWithNonce`. This ensures *deterministic Safe addresses*
    ///   across deployments for the same initializer and `signer`.
    /// @param invitationModule The Invitation Module address; also the source of `GENERIC_CALL_PROXY`.
    constructor(address invitationModule) {
        INVITATION_MODULE = invitationModule;
        GENERIC_CALL_PROXY = IInvitationModule(invitationModule).GENERIC_CALL_PROXY();
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                DOMAIN_SEPARATOR_TYPEHASH,
                keccak256(bytes("ReferralsModule")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
        bytes memory initializer = _initializer();
        ACCOUNT_INITIALIZER_HASH = keccak256(initializer);
    }

    /*//////////////////////////////////////////////////////////////
                          CREATE ACCOUNT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pre-deploys a Safe for an origin inviter’s offchain `signer`.
    /// @dev
    /// - Only callable by the Invitation Module Generic Call Proxy.
    /// - Reverts with {SignerAlreadyUsed} if a Safe was already pre-deployed for `signer`.
    /// - Initializes the Safe with:
    ///   owner = `SAFE_WEB_AUTHN_SHARED_SIGNER`, threshold = 1,
    ///   fallback handler = `SAFE_4337_MODULE`,
    ///   modules = [`SAFE_4337_MODULE`, `INVITATION_MODULE`, `address(this)`].
    /// - The deployed Safe awaits claim by the invitee who knows the `signer`’s secret key.
    /// @param signer The public address derived from the origin inviter’s offchain secret key.
    /// @return account The pre-deployed Safe address tied to `signer`.
    function createAccount(address signer) public onlyGenericCallProxy returns (address account) {
        if (accounts[signer].account != address(0)) revert SignerAlreadyUsed();

        bytes memory initializer = _initializer();

        account = SAFE_PROXY_FACTORY.createProxyWithNonce(SAFE_SINGLETON, initializer, uint256(uint160(signer)));
        accounts[signer].account = account;
        emit AccountCreated(account);
    }

    /// @notice Batch pre-deploys Safes for multiple `signers`.
    /// @dev Each element reuses {createAccount} semantics and restrictions.
    /// @param signers The list of public addresses derived from origin inviters’ offchain secrets.
    /// @return _accounts The list of pre-deployed Safe addresses aligned with `signers`.
    function createAccounts(address[] memory signers)
        external
        onlyGenericCallProxy
        returns (address[] memory _accounts)
    {
        uint256 numberOfAccounts = signers.length;
        _accounts = new address[](numberOfAccounts);
        for (uint256 i; i < numberOfAccounts;) {
            _accounts[i] = createAccount(signers[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Predicts the pre-made Safe address for a given `signer` without deploying it.
    /// @dev Uses CREATE2 with `ACCOUNT_INITIALIZER_HASH` and `ACCOUNT_CREATION_CODE_HASH` via `SAFE_PROXY_FACTORY`.
    /// @param signer The offchain public address chosen by the origin inviter as the pre-deployment key.
    /// @return predictedAddress The deterministic Safe address that would be deployed for `signer`.
    function computeAddress(address signer) external view returns (address predictedAddress) {
        bytes32 salt = keccak256(abi.encodePacked(ACCOUNT_INITIALIZER_HASH, uint256(uint160(signer))));
        predictedAddress = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(SAFE_PROXY_FACTORY), salt, ACCOUNT_CREATION_CODE_HASH)
                    )
                )
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                          CLAIM ACCOUNT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Claims the pre-made Safe by proving knowledge of the offchain secret (for `signer`)
    ///         and configuring the device WebAuthn passkey; sets Name Registry metadata in a single transaction;
    ///         then disables this module.
    /// @dev
    /// - The invitee signs the EIP-712 passkey digest using the offchain secret key provided by the origin inviter.
    /// - The module recovers `signer` from the signature, locates the pre-made Safe, and finalizes:
    ///   * marks claimed,
    ///   * configures the WebAuthn shared signer with `(x,y,verifier)`,
    ///   * calls `personalMint` and burns CRC above `WELCOME_BONUS`,
    ///   * disables this module on the Safe.
    /// - Reverts with {InvalidSignature} if malformed or no Safe is mapped for the recovered `signer`.
    /// - Reverts with {AccountAlreadyClaimed} if already claimed.
    /// @param x The X coordinate of the WebAuthn public key.
    /// @param y The Y coordinate of the WebAuthn public key.
    /// @param verifier The WebAuthn verifier/authenticator contract address.
    /// @param signature The 65-byte ECDSA signature over the EIP-712 passkey digest, signed by the offchain secret key.
    function claimAccount(uint256 x, uint256 y, address verifier, bytes calldata signature, bytes32 metadataDigest)
        external
    {
        address account = _transferOwnership(x, y, verifier, signature);
        // set metadatadigest
        _updateMetadataDigest(account, metadataDigest);
        // disable module
        _disableModule(account);
    }

    /// @notice Claims the pre-made Safe, sets Name Registry metadata and affiliate group, then disables this module.
    /// @dev Follows the same claim flow as the base variant and then performs both additional updates.
    /// @param x The X coordinate of the passkey public key.
    /// @param y The Y coordinate of the passkey public key.
    /// @param verifier The verifier/authenticator contract address.
    /// @param signature The 65-byte ECDSA signature over the EIP-712 passkey digest.
    /// @param metadataDigest The metadata digest to set in the Name Registry.
    /// @param affiliateGroup The affiliate group address to register.
    function claimAccount(
        uint256 x,
        uint256 y,
        address verifier,
        bytes calldata signature,
        bytes32 metadataDigest,
        address affiliateGroup
    ) external {
        address account = _transferOwnership(x, y, verifier, signature);
        // set metadatadigest
        _updateMetadataDigest(account, metadataDigest);
        // set affiliate group
        _setAffiliateGroup(account, affiliateGroup);
        // disable module
        _disableModule(account);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructs the Safe initializer calldata used for pre-deployed referral Safes.
    /// @dev
    /// - Configures a single owner: `SAFE_WEB_AUTHN_SHARED_SIGNER` with threshold = 1.
    /// - Uses `SAFE_MODULE_SETUP` to enable three modules on the Safe:
    ///   * `SAFE_4337_MODULE`
    ///   * `INVITATION_MODULE`
    ///   * `address(this)` (the ReferralsModule)
    /// - Sets `SAFE_4337_MODULE` as the Safe’s fallback handler.
    /// - The returned bytes are passed to `ISafe.setup` during proxy deployment and also hashed
    ///   into `ACCOUNT_INITIALIZER_HASH` for CREATE2 address prediction.
    /// @return initializer ABI-encoded calldata for `ISafe.setup` that fully configures the Safe.
    function _initializer() internal view returns (bytes memory initializer) {
        address[] memory modules = new address[](3);
        modules[0] = SAFE_4337_MODULE;
        modules[1] = INVITATION_MODULE;
        modules[2] = address(this);
        bytes memory data = abi.encodeWithSelector(ISafeModuleSetup.enableModules.selector, modules);

        address[] memory owners = new address[](1);
        owners[0] = SAFE_WEB_AUTHN_SHARED_SIGNER;
        initializer = abi.encodeWithSelector(
            ISafe.setup.selector,
            owners,
            uint256(1), // threshold
            SAFE_MODULE_SETUP,
            data,
            SAFE_4337_MODULE, // fallback handler
            address(0),
            uint256(0),
            payable(address(0))
        );
    }

    /// @notice Verifies the invitee’s claim (EIP-712 signature using the offchain secret), marks the account as claimed,
    ///         configures WebAuthn, calls `personalMint`, and burns any CRC above `WELCOME_BONUS`.
    /// @dev
    /// - Reverts with {InvalidSignature} if signature length != 65 or recovery resolves to an unmapped `signer`.
    /// - Reverts with {AccountAlreadyClaimed} if the Safe was already claimed.
    /// - Performs Safe module calls to:
    ///   1) Configure the WebAuthn shared signer with the provided passkey.
    ///   2) Call `Hub.personalMint()`.
    ///   3) If balance exceeds `WELCOME_BONUS`, burn the excess.
    /// @param x The X coordinate of the WebAuthn public key.
    /// @param y The Y coordinate of the WebAuthn public key.
    /// @param verifier The WebAuthn verifier/authenticator contract address.
    /// @param signature The 65-byte ECDSA signature over the EIP-712 passkey digest.
    /// @return account The pre-made Safe that was successfully claimed.
    function _transferOwnership(uint256 x, uint256 y, address verifier, bytes calldata signature)
        internal
        returns (address account)
    {
        // validate signature
        if (signature.length != 65) revert InvalidSignature();

        bytes32 passkeyHash = getPasskeyHash(x, y, verifier);
        bytes32 r = bytes32(signature[:32]);
        bytes32 s = bytes32(signature[32:64]);
        uint8 v = uint8(bytes1(signature[64:65]));
        address signer = ecrecover(passkeyHash, v, r, s);

        account = accounts[signer].account;
        if (account == address(0)) revert InvalidSignature();

        if (accounts[signer].claimed) revert AccountAlreadyClaimed();
        accounts[signer].claimed = true;

        // configure the passkey
        bytes memory callData =
            abi.encodeWithSelector(ISafeWebAuthnSharedSigner.configure.selector, Passkey(x, y, verifier));
        _callFromSafe(account, SAFE_WEB_AUTHN_SHARED_SIGNER, callData, uint8(1));

        // make sure that the total supply is 48CRC
        callData = abi.encodeWithSelector(IHub.personalMint.selector);
        _callFromSafe(account, HUB, callData, uint8(0));

        uint256 balance = IHub(HUB).balanceOf(account, uint256(uint160(account)));
        if (balance > WELCOME_BONUS) {
            callData =
                abi.encodeWithSelector(IHub.burn.selector, uint256(uint160(account)), balance - WELCOME_BONUS, "");
            _callFromSafe(account, HUB, callData, uint8(0));
        }
    }

    /// @notice Updates the Name Registry metadata digest for `account` post-claim.
    /// @dev Executes via the Safe using {_callFromSafe}.
    /// @param account The Safe whose metadata is updated.
    /// @param metadataDigest The metadata digest to set.
    function _updateMetadataDigest(address account, bytes32 metadataDigest) internal {
        bytes memory callData = abi.encodeWithSelector(INameRegistry.updateMetadataDigest.selector, metadataDigest);
        _callFromSafe(account, NAME_REGISTRY, callData, uint8(0));
    }

    /// @notice Sets the affiliate group for `account` in the Affiliate Group Registry post-claim.
    /// @dev Executes via the Safe using {_callFromSafe}.
    /// @param account The Safe whose affiliate group is set.
    /// @param affiliateGroup The affiliate group address to associate with the Safe.
    function _setAffiliateGroup(address account, address affiliateGroup) internal {
        bytes memory callData =
            abi.encodeWithSelector(IAffiliateGroupRegistry.setAffiliateGroup.selector, affiliateGroup);
        _callFromSafe(account, AFFILIATE_GROUP_REGISTRY, callData, uint8(0));
    }

    /// @notice Disables this module on `account` and emits {AccountClaimed}.
    /// @dev Uses Safe’s sentinel as the “previous module” since this module is added last at setup.
    /// @param account The Safe on which this module is disabled.
    function _disableModule(address account) internal {
        bytes memory callData = abi.encodeWithSelector(IModuleManager.disableModule.selector, SENTINEL, address(this));
        _callFromSafe(account, account, callData, uint8(0));
        emit AccountClaimed(account);
    }

    /// @notice Executes a call from a given Safe using the Safe module execution path.
    /// @dev Reverts bubbling the target’s revert reason if the call fails.
    /// @param safe The Safe that executes the transaction.
    /// @param target The contract to call.
    /// @param callData The ABI-encoded call data to execute.
    /// @param operation The Safe operation type (0 = CALL, 1 = DELEGATECALL).
    function _callFromSafe(address safe, address target, bytes memory callData, uint8 operation) internal {
        (bool success, bytes memory returnData) =
            IModuleManager(safe).execTransactionFromModuleReturnData(target, uint256(0), callData, operation);
        if (!success) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          EIP-712 FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Builds the EIP-712 preimage that the invitee signs with the offchain secret key.
    /// @dev Returns `0x1901 || DOMAIN_SEPARATOR || keccak256(abi.encode(PASSKEY_TYPEHASH, x, y, verifier))`.
    /// @param x The X coordinate of the WebAuthn public key.
    /// @param y The Y coordinate of the WebAuthn public key.
    /// @param verifier The WebAuthn verifier/authenticator contract address.
    /// @return The encoded EIP-712 message bytes to be signed with the offchain secret.
    function encodePasskeyData(uint256 x, uint256 y, address verifier) public view returns (bytes memory) {
        bytes32 passkeyHash = keccak256(abi.encode(PASSKEY_TYPEHASH, x, y, verifier));
        return abi.encodePacked(bytes1(0x19), bytes1(0x01), DOMAIN_SEPARATOR, passkeyHash);
    }

    /// @notice Computes the EIP-712 digest for the given passkey parameters.
    /// @dev Equal to `keccak256(encodePasskeyData(x, y, verifier))`.
    /// @param x The X coordinate of the passkey public key.
    /// @param y The Y coordinate of the passkey public key.
    /// @param verifier The verifier/authenticator contract address.
    /// @return The EIP-712 digest to be signed or recovered for claim.
    function getPasskeyHash(uint256 x, uint256 y, address verifier) public view returns (bytes32) {
        return keccak256(encodePasskeyData(x, y, verifier));
    }
}
