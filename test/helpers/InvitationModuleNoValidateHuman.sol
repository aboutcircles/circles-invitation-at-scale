// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IModuleManager} from "src/interfaces/IModuleManager.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {GenericCallProxy} from "src/GenericCallProxy.sol";

/// @title Circles Invitation Module without Human validation
/// @notice This is a mock Invitation Module contract where if (!_isHuman(invitee)) revert HumanRegistrationFailed(invitee); is removed
contract InvitationModuleNoValidateHuman {
    /*//////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/

    /// @dev Thrown when a function is called by an address other than the Hub.
    error OnlyHub();

    /// @dev Thrown when a reentrant call is detected for the same `from` context.
    error Reentrancy();

    /// @dev Thrown when encoded payloads do not satisfy minimal ABI requirements.
    error InvalidEncoding();

    /// @dev Thrown when provided parallel arrays have mismatched lengths.
    error ArrayLengthMismatch();

    /// @dev Thrown when batch invitations contain fewer than the required minimum (2).
    error TooFewInvites();

    /// @dev Thrown when the ERC-1155 value is not exactly equal to {INVITATION_FEE}.
    error NotExactInvitationFee();

    /// @dev Thrown when the Safe does not have this module enabled.
    /// @param avatar The Safe (inviter/invitee) that lacks the module enablement.
    error ModuleNotEnabled(address avatar);

    /// @dev Thrown when an address is not recognized as a human in the Hub.
    /// @param avatar The address that failed human validation.
    error HumanValidationFailed(address avatar);

    /// @dev Thrown when a required trust relation is missing in the Hub.
    /// @param truster The address expected to trust `trustee`.
    /// @param trustee The address expected to be trusted by `truster`.
    error TrustRequired(address truster, address trustee);

    /// @dev Thrown when an invitee is already registered in the Hub.
    /// @param invitee The already-registered address.
    error InviteeAlreadyRegistered(address invitee);

    /// @dev Thrown when post-registration verification fails in the Hub.
    /// @param invitee The address that failed to appear as a human after registration.
    error HumanRegistrationFailed(address invitee);

    /// @dev Thrown when post-enforcement verification of a trust link fails.
    /// @param truster The address expected to trust `trustee`.
    /// @param trustee The address expected to be trusted by `truster`.
    error TrustEnforcementFailed(address truster, address trustee);

    /*//////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an invitee is registered as a human through this module.
    /// @param human The newly registered human (invitee).
    /// @param originInviter The original caller or initiator of the invitation (taken from the ERC-1155 `from` address).
    /// @param proxyInviter The proxy inviter derived from the ERC-1155 token id (cast to address).
    event RegisterHuman(address indexed human, address indexed originInviter, address indexed proxyInviter);

    /*//////////////////////////////////////////////////////////////
                              Constants & Immutables
    //////////////////////////////////////////////////////////////*/

    /// @notice Circles v2 Hub instance used for trust, registration, and transfers.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    /// @notice Exact CRC amount expected for each invitation transfer item.
    uint256 public constant INVITATION_FEE = 96 ether;

    /// @notice Helper proxy used to perform “generic calls” that return encoded invitee address data.
    GenericCallProxy public immutable GENERIC_CALL_PROXY;

    /*//////////////////////////////////////////////////////////////
                                 Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @notice Reentrancy guard keyed by the `from` address for Hub callbacks.
    /// @dev Uses EVM transient storage (TLOAD/TSTORE) to detect nested entry.
    /// @param from The ERC-1155 `from` address used to key the reentrancy context.
    modifier nonReentrant(address from) {
        assembly {
            if tload(0) {
                // revert Reentrancy()
                mstore(0, 0xab143c06)
                revert(0x1c, 0x4)
            }
            tstore(0, from)
        }
        _;
        assembly {
            tstore(0, 0)
        }
    }

    /// @notice Restricts function entry to calls originating from the Hub.
    /// @dev Reverts with {OnlyHub} if `msg.sender != HUB`.
    modifier onlyHub() {
        if (msg.sender != address(HUB)) revert OnlyHub();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               Constructor
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys the {GenericCallProxy} and self-registers this module as an organization in the Hub.
    /// @dev `GENERIC_CALL_PROXY` is immutable; organization registration uses a zero metadata digest.
    constructor() {
        GENERIC_CALL_PROXY = new GenericCallProxy();
        HUB.registerOrganization("InvitationModule", bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                                External
    //////////////////////////////////////////////////////////////*/

    /// @notice Grants long-lived trust from this organization to a given inviter Safe.
    /// @dev Should be called in tandem with enabling this module on the inviter Safe.
    ///      Reverts if the inviter is not human or the module is not enabled.
    /// @param inviter The address to be trusted by this organization.
    function trustInviter(address inviter) external {
        validateInviter(inviter);
        // make org trust id
        HUB.trust(inviter, type(uint96).max);
    }

    /// @notice Returns the current `originInviter` for the active callback context.
    /// @dev Reads the transient storage slot written by {nonReentrant}; only meaningful during callbacks.
    /// @return originInviter The `from` address of the ongoing ERC-1155 callback.
    function getOriginInviter() external view returns (address originInviter) {
        assembly {
            originInviter := tload(0)
        }
    }

    /*//////////////////////////////////////////////////////////////
                         Internal: Validation (view)
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates that this module is enabled on a Safe.
    /// @dev Reverts with {ModuleNotEnabled} if disabled.
    /// @param safe The Safe for which module enablement is checked.
    function validateModuleEnabled(address safe) internal view {
        if (!_isModuleEnabled(safe)) revert ModuleNotEnabled(safe);
    }

    /// @notice Validates an existing trust link in the Hub.
    /// @dev Reverts with {TrustRequired} if `truster` does not trust `trustee`.
    /// @param truster The address expected to trust `trustee`.
    /// @param trustee The address expected to be trusted by `truster`.
    function validateTrust(address truster, address trustee) internal view {
        if (!_isTrusted(truster, trustee)) revert TrustRequired(truster, trustee);
    }

    /// @notice Validates that an address is a registered human in the Hub.
    /// @dev Reverts with {HumanValidationFailed} if not human.
    /// @param avatar The address to validate.
    function validateHuman(address avatar) internal view {
        if (!_isHuman(avatar)) revert HumanValidationFailed(avatar);
    }

    /// @notice Validates that an inviter Safe is human and has this module enabled.
    /// @param inviter The Safe to validate as an inviter.
    function validateInviter(address inviter) internal view {
        validateHuman(inviter);
        validateModuleEnabled(inviter);
    }

    /*//////////////////////////////////////////////////////////////
                     Internal: Enforcement / Core Logic
    //////////////////////////////////////////////////////////////*/

    /// @notice Enforces a trust relation `truster -> trustee` with a given expiry via the Hub.
    /// @dev
    /// - Precondition: module must be enabled on `truster` (validated upstream).
    /// - Postcondition: verifies trust exists after the call; reverts with {TrustEnforcementFailed} otherwise.
    /// @param truster The Safe that will trust `trustee`.
    /// @param trustee The address to be trusted.
    /// @param expiry The trust expiry; `type(uint96).max` for permanent.
    function enforceTrust(address truster, address trustee, uint96 expiry) internal {
        bytes memory data = abi.encodeWithSelector(IHub.trust.selector, trustee, expiry);
        _callHubFromSafe(truster, data);
        // sanity check in case truster is custom contract implementing Safe interface
        if (!_isTrusted(truster, trustee)) revert TrustEnforcementFailed(truster, trustee);
    }

    /// @notice Enforces the registration of `invitee` as a human, called via their Safe.
    /// @dev
    /// - Requires the module to be enabled on `invitee`.
    /// - Reverts if the invitee is already registered.
    /// - Calls Hub to register human and verifies success.
    /// - Finally, this organization trusts the invitee permanently.
    /// @param invitee The address to be registered as a human.
    /// @param inviter The inviter to be recorded in the human registration call.
    function enforceHumanRegistered(address invitee, address inviter) internal {
        // check invitee has module enabled
        validateModuleEnabled(invitee);

        if (HUB.avatars(invitee) != address(0)) revert InviteeAlreadyRegistered(invitee);

        // Register the invitee as a human.
        // NOTE: The default Safe deployment flow is expected to call
        // `NameRegistry.updateMetadataDigest(bytes32)` to set an initial metadata digest.
        // This allows passing `bytes32(0)` here without overwriting any existing value.
        // If that initialization step was skipped, the metadata digest should be updated manually after registration.
        bytes memory data = abi.encodeWithSelector(IHub.registerHuman.selector, inviter, bytes32(0));
        _callHubFromSafe(invitee, data);
        // Remove sanity check in case invitee is custom contract implementing Safe interface
        // if (!_isHuman(invitee)) revert HumanRegistrationFailed(invitee);

        // make this org trust id
        HUB.trust(invitee, type(uint96).max);
    }

    /// @notice Transfers to the proxy inviter his CRC and enforces human registration for the `invitee`.
    /// @dev Transfers exactly {INVITATION_FEE} CRC to `proxyInviter`, then calls {enforceHumanRegistered}.
    /// @param proxyInviter The proxy inviter receiving the fee and recorded as inviter.
    /// @param invitee The address to be registered as human.
    function proxyInvite(address proxyInviter, address invitee) internal {
        // transfer 96 CRC to proxy inviter
        HUB.safeTransferFrom(address(this), proxyInviter, uint256(uint160(proxyInviter)), INVITATION_FEE, "");

        // enforce invitee to register as human
        enforceHumanRegistered(invitee, proxyInviter);
    }

    /*//////////////////////////////////////////////////////////////
                     Internal: Low-level / Helper Utils
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a Hub call from a given Safe using the Safe module execution path.
    /// @dev Reverts bubbling the Hub’s revert reason if the call fails.
    /// @param safe The Safe that executes the transaction.
    /// @param callData The ABI-encoded Hub call data to execute.
    function _callHubFromSafe(address safe, bytes memory callData) internal {
        (bool success, bytes memory returnData) =
            IModuleManager(safe).execTransactionFromModuleReturnData(address(HUB), uint256(0), callData, uint8(0));
        if (!success) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    /// @notice Detects whether a payload represents a “generic call” envelope rather than a raw address array.
    /// @dev Detects whether the payload encodes a generic call by checking if the first word resembles an address.
    ///      Real contract addresses are always much larger than `data.length`, so this condition distinguishes
    ///      `abi.encode(address, bytes)` envelopes from simple `abi.encode(address[])` arrays.
    /// @param data ABI-encoded payload to inspect.
    /// @return True if the payload is a generic call envelope; false if it’s a raw `address[]`.
    function _isGenericCall(bytes memory data) internal pure returns (bool) {
        uint256 firstWord;
        assembly {
            firstWord := mload(add(data, 0x20))
        }
        return firstWord > data.length;
    }

    /// @notice Simple view wrapper for Hub trust relation.
    /// @param truster The address expected to trust `trustee`.
    /// @param trustee The address expected to be trusted by `truster`.
    /// @return True if `truster` trusts `trustee` in the Hub.
    function _isTrusted(address truster, address trustee) internal view returns (bool) {
        return HUB.isTrusted(truster, trustee);
    }

    /// @notice Simple view wrapper for Hub human registration status.
    /// @param avatar The address to query.
    /// @return True if `avatar` is a human in the Hub.
    function _isHuman(address avatar) internal view returns (bool) {
        return HUB.isHuman(avatar);
    }

    /// @notice Checks if this module is enabled on a given Safe.
    /// @param safe The Safe to query.
    /// @return True if this module is enabled on `safe`.
    function _isModuleEnabled(address safe) internal view returns (bool) {
        return IModuleManager(safe).isModuleEnabled(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                           ERC-1155 Callbacks
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC-1155 single-token transfer hook used by the Hub to process an invitation.
    /// @dev
    /// - Requires `value == INVITATION_FEE` and payload length ≥ 32 bytes.
    /// - Decodes the invitee from either a generic call via {GENERIC_CALL_PROXY} or a raw address.
    /// - Direct invite path `originInviter == proxyInviter`:
    ///     * If the inviter’s module is disabled, requires `originInviter` to already trust `invitee`,
    ///       then transfers and registers the invitee (no additional trust enforcement).
    /// - Proxied invite path `originInviter != proxyInviter`:
    ///     * Requires module enabled on `originInviter` and `proxyInviter` to be a valid inviter,
    ///       and `proxyInviter` to trust `originInviter`.
    /// - Expiry policy:
    ///     * Direct invite: `proxyInviter -> invitee` trust is permanent (`type(uint96).max`)
    ///     * Proxied invite: `proxyInviter -> invitee` trust is ephemeral (current block timestamp),
    ///       and `originInviter -> invitee` trust is permanent.
    /// @param from The ERC-1155 `from` address; treated as `originInviter`.
    /// @param id The ERC-1155 token id; cast to `proxyInviter` address.
    /// @param value The ERC-1155 amount; must equal {INVITATION_FEE}.
    /// @param data Encoded payload to extract the `invitee` address.
    /// @return The ERC-1155 acceptance selector.
    function onERC1155Received(address, address from, uint256 id, uint256 value, bytes memory data)
        external
        onlyHub
        nonReentrant(from)
        returns (bytes4)
    {
        if (value != INVITATION_FEE) revert NotExactInvitationFee();
        if (data.length < 32) revert InvalidEncoding();

        address originInviter = from;
        validateHuman(originInviter);
        address proxyInviter = address(uint160(id));
        bool directInvite = originInviter == proxyInviter;

        address invitee =
            data.length > 32 ? GENERIC_CALL_PROXY.proxyGenericCallReturnInvitee(data) : abi.decode(data, (address));

        if (directInvite) {
            if (!_isModuleEnabled(originInviter)) {
                validateTrust(originInviter, invitee);
                proxyInvite(originInviter, invitee);
                return this.onERC1155Received.selector;
            }
        } else {
            validateModuleEnabled(originInviter);
            validateInviter(proxyInviter);
            // check proxy inviter trusts origin inviter
            validateTrust(proxyInviter, originInviter);
        }

        enforceTrust(proxyInviter, invitee, directInvite ? type(uint96).max : uint96(block.timestamp));

        proxyInvite(proxyInviter, invitee);

        if (!directInvite) enforceTrust(originInviter, invitee, type(uint96).max);

        emit RegisterHuman(invitee, originInviter, proxyInviter);

        return this.onERC1155Received.selector;
    }

    /// @notice ERC-1155 batch transfer hook used by the Hub to process multiple invitations in one call.
    /// @dev
    /// - Requires `ids.length == values.length` and `ids.length >= 2`.
    /// - Validates `originInviter` as a proper inviter (human + module enabled).
    /// - Decodes invitees either via {GENERIC_CALL_PROXY} (generic call) or raw `address[]`.
    /// - For each item:
    ///     * Requires `values[i] == INVITATION_FEE`.
    ///     * Short-circuits validations for contiguous runs of the same `proxyInviter`.
    ///     * Applies the same expiry policy as the single-transfer path.
    /// - Emits {RegisterHuman} for each invitee.
    /// @param from The ERC-1155 `from` address; treated as `originInviter`.
    /// @param ids The ERC-1155 token ids; each cast to a `proxyInviter` address.
    /// @param values The ERC-1155 amounts; each must equal {INVITATION_FEE}.
    /// @param data Encoded payload to extract the invitee addresses.
    /// @return The ERC-1155 batch-acceptance selector.
    function onERC1155BatchReceived(
        address,
        address from,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) external onlyHub nonReentrant(from) returns (bytes4) {
        uint256 numberOfInvitees = ids.length;
        if (numberOfInvitees != values.length) revert ArrayLengthMismatch();
        if (numberOfInvitees < 2) revert TooFewInvites();

        address originInviter = from;
        validateInviter(originInviter);

        address[] memory invitees = _isGenericCall(data)
            ? GENERIC_CALL_PROXY.proxyGenericCallReturnInvitees(data, numberOfInvitees)
            : abi.decode(data, (address[]));
        if (numberOfInvitees != invitees.length) revert InvalidEncoding();

        address lastProxyInviter;
        for (uint256 i; i < numberOfInvitees;) {
            if (values[i] != INVITATION_FEE) revert NotExactInvitationFee();
            address proxyInviter = address(uint160(ids[i]));
            bool directInvite = originInviter == proxyInviter;
            if (!directInvite && lastProxyInviter != proxyInviter) {
                validateInviter(proxyInviter);
                // check proxy inviter trusts origin inviter
                validateTrust(proxyInviter, originInviter);
            }
            address invitee = invitees[i];
            enforceTrust(proxyInviter, invitee, directInvite ? type(uint96).max : uint96(block.timestamp));
            proxyInvite(proxyInviter, invitee);
            if (!directInvite) enforceTrust(originInviter, invitee, type(uint96).max);
            lastProxyInviter = proxyInviter;
            emit RegisterHuman(invitee, originInviter, proxyInviter);
            unchecked {
                ++i;
            }
        }

        return this.onERC1155BatchReceived.selector;
    }
}
