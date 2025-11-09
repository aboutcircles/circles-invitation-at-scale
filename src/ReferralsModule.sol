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

contract ReferralsModule {
    /*//////////////////////////////////////////////////////////////
                                Structs
    //////////////////////////////////////////////////////////////*/
    struct Passkey {
        uint256 x;
        uint256 y;
        address verifier;
    }
    struct Account {
        address account;
        bool claimed;
    }
    /*//////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/
    error OnlyGenericCallProxy();
    error InvalidSignature();
    error SignerAlreadyUsed();
    error AccountAlreadyClaimed();

    /*//////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    event AccountCreated(address indexed account);
    event AccountClaimed(address indexed account);

    /*//////////////////////////////////////////////////////////////
                              Constants & Immutables
    //////////////////////////////////////////////////////////////*/
    /// @notice Circles v2 Hub.
    address internal constant HUB = address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8);
    uint256 internal constant WELCOME_BONUS = 48 ether;
    /// @notice Circles v2 Name Registry contract.
    address internal constant NAME_REGISTRY = address(0xA27566fD89162cC3D40Cb59c87AAaA49B85F3474);
    address internal constant AFFILIATE_GROUP_REGISTRY = address(0xca8222e780d046707083f51377B5Fd85E2866014);
    
    address internal immutable INVITATION_MODULE;
    address internal immutable GENERIC_CALL_PROXY;

    ISafeProxyFactory internal constant SAFE_PROXY_FACTORY =
        ISafeProxyFactory(address(0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67));
    address internal constant SAFE_SINGLETON = address(0x29fcB43b46531BcA003ddC8FCB67FFE91900C762);
    address internal constant SAFE_4337_MODULE = address(0x75cf11467937ce3F2f357CE24ffc3DBF8fD5c226);
    address internal constant SAFE_MODULE_SETUP = address(0x2dd68b007B46fBe91B9A7c3EDa5A7a1063cB5b47);
    address internal constant SAFE_WEB_AUTHN_SHARED_SIGNER = address(0xfD90FAd33ee8b58f32c00aceEad1358e4AFC23f9);
    
    address internal constant SENTINEL = address(1);
    bytes32 internal constant ACCOUNT_INITIALIZER_HASH = 0x440ea2f93c9703f7d456d48796f7bc25b8721582535a492ce0a09df32146242a;
    bytes32 internal constant ACCOUNT_CREATION_CODE_HASH = 0xe298282cefe913ab5d282047161268a8222e4bd4ed106300c547894bbefd31ee;
       
    /// @notice Typehash of EIP712 domain separator.
    /// @dev keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    bytes32 internal constant DOMAIN_SEPARATOR_TYPEHASH =
        0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
    /// @dev keccak256("Passkey(uint256 x,uint256 y,address verifier)")
    bytes32 internal constant PASSKEY_TYPEHASH =
        0x6f5bf8ecc7e0e1deab50ed1bf5eaaa272c6dc0147cfa7f55c7e7551bc5ff0751;
    /// @notice EIP-712 domain separator.
    bytes32 public immutable DOMAIN_SEPARATOR;

    /*//////////////////////////////////////////////////////////////
                                Storage
    //////////////////////////////////////////////////////////////*/

    mapping(address signer => Account) public accounts;

    /*//////////////////////////////////////////////////////////////
                                 Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts to Module calls.
    modifier onlyGenericCallProxy() {
        if (msg.sender != GENERIC_CALL_PROXY) revert OnlyGenericCallProxy();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               Constructor
    //////////////////////////////////////////////////////////////*/

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
    }

    /*//////////////////////////////////////////////////////////////
                          CREATE ACCOUNT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function createAccount(address signer) public onlyGenericCallProxy returns (address account) {
        if (accounts[signer].account != address(0)) revert SignerAlreadyUsed();
        
        address[] memory modules = new address[](3);
        modules[0] = SAFE_4337_MODULE;
        modules[1] = INVITATION_MODULE;
        modules[2] = address(this);
        bytes memory data = abi.encodeWithSelector(ISafeModuleSetup.enableModules.selector, modules);

        address[] memory owners = new address[](1);
        owners[0] = SAFE_WEB_AUTHN_SHARED_SIGNER;
        bytes memory initializer = abi.encodeWithSelector(
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
        
        account = SAFE_PROXY_FACTORY.createProxyWithNonce(SAFE_SINGLETON, initializer, uint256(uint160(signer)));
        accounts[signer].account = account;
        emit AccountCreated(account);
    }

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

    function computeAddress(address signer) external pure returns (address predictedAddress) {
        bytes32 salt = keccak256(abi.encodePacked(ACCOUNT_INITIALIZER_HASH, uint256(uint160(signer))));
        predictedAddress = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(SAFE_PROXY_FACTORY), salt, ACCOUNT_CREATION_CODE_HASH))))
        );
    }

    /*//////////////////////////////////////////////////////////////
                          CLAIM ACCOUNT FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    function claimAccount(uint256 x, uint256 y, address verifier, bytes calldata signature) external {
        address account = _transferOwnership(x, y, verifier, signature);
        // disable module
        _disableModule(account);
    }

    function claimAccount(uint256 x, uint256 y, address verifier, bytes calldata signature, bytes32 metadataDigest) external {
        address account = _transferOwnership(x, y, verifier, signature);
        // set metadatadigest
        _updateMetadataDigest(account, metadataDigest);
        // disable module
        _disableModule(account);
    }

    function claimAccount(uint256 x, uint256 y, address verifier, bytes calldata signature, address affiliateGroup) external {
        address account = _transferOwnership(x, y, verifier, signature);
        // set affiliate group
        _setAffiliateGroup(account, affiliateGroup);
        // disable module
        _disableModule(account);
    }

    function claimAccount(uint256 x, uint256 y, address verifier, bytes calldata signature, bytes32 metadataDigest, address affiliateGroup) external {
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

    function _transferOwnership(uint256 x, uint256 y, address verifier, bytes calldata signature) internal returns (address account) {
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
        bytes memory callData = abi.encodeWithSelector(ISafeWebAuthnSharedSigner.configure.selector, Passkey(x, y, verifier));
        _callFromSafe(account, SAFE_WEB_AUTHN_SHARED_SIGNER, callData, uint8(1));

        // make sure that the total supply is 48CRC
        callData = abi.encodeWithSelector(IHub.personalMint.selector);
        _callFromSafe(account, HUB, callData, uint8(0));

        uint256 balance = IHub(HUB).balanceOf(account, uint256(uint160(account)));
        if (balance > WELCOME_BONUS) {
            callData = abi.encodeWithSelector(IHub.burn.selector, uint256(uint160(account)), balance - WELCOME_BONUS, "");
            _callFromSafe(account, HUB, callData, uint8(0));
        }
    }

    function _updateMetadataDigest(address account, bytes32 metadataDigest) internal {
        bytes memory callData = abi.encodeWithSelector(INameRegistry.updateMetadataDigest.selector, metadataDigest);
        _callFromSafe(account, NAME_REGISTRY, callData, uint8(0));
    }

    function _setAffiliateGroup(address account, address affiliateGroup) internal {
        bytes memory callData = abi.encodeWithSelector(IAffiliateGroupRegistry.setAffiliateGroup.selector, affiliateGroup);
        _callFromSafe(account, AFFILIATE_GROUP_REGISTRY, callData, uint8(0));
    }

    function _disableModule(address account) internal {
        // disable this module as it has done its job for this account
        // make safe call to itself, selector: Safe.disableModule(address,address)
        // as this module is the last added in Safe, it allows to use sentinel as previous module
        bytes memory callData = abi.encodeWithSelector(IModuleManager.disableModule.selector, SENTINEL, address(this));
        _callFromSafe(account, account, callData, uint8(0));
        emit AccountClaimed(account);
    }

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

    function encodePasskeyData(uint256 x, uint256 y, address verifier) public view returns (bytes memory) {
        bytes32 passkeyHash = keccak256(
            abi.encode(PASSKEY_TYPEHASH, x, y, verifier)
        );
        return abi.encodePacked(
            bytes1(0x19), bytes1(0x01), DOMAIN_SEPARATOR, passkeyHash
        );
    }

    function getPasskeyHash(uint256 x, uint256 y, address verifier)
        public
        view
        returns (bytes32)
    {
        return keccak256(encodePasskeyData(x, y, verifier));
    }
}
