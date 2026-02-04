// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IHub} from "src/interfaces/IHub.sol";
import {IInvitationFarm} from "src/interfaces/IInvitationFarm.sol";
import {IModuleManager} from "src/interfaces/IModuleManager.sol";

/// @title InvitationQuotaGrantModule
/// @notice
/// A permissioned module that can grant inviter quota in the Invitation Farm in two ways:
/// (1) directly, by allowing authorized grantees to set quotas via the admin safe; and
/// (2) indirectly, by crediting quota to a sender who transfers exactly 96 CRC (per item) of an accepted CRC
///     to this contract via the Circles v2 Hub, then forwarding the CRC to the admin safe.
/// @dev
/// High-level flow:
/// 1) Admin configures which CRC token IDs are accepted by setting Hub trust toward those CRCs.
/// 2) A user sends exactly `REQUIRED_AMOUNT` of an accepted CRC (ERC-1155 id) to this contract via the Hub.
/// 3) The Hub calls `onERC1155Received` / `onERC1155BatchReceived`.
/// 4) The module increases the sender’s inviter quota in the Invitation Farm (by 1 per received token / per item).
/// 5) The module forwards the received ERC-1155 token(s) to the admin safe.
contract InvitationQuotaGrantModule {
    /*//////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the caller is not the admin safe (`INVITATION_FARM_ADMIN_SAFE`).
    error OnlyAdmin();

    /// @notice Thrown when the caller is not an address authorized as a quota permission grantee.
    /// @dev A grantee is considered authorized if `quotaPermissionGrantees[msg.sender] != address(0)`.
    error OnlyQuotaPermissionGrantee();

    /// @notice Thrown when a function restricted to Hub entry points is called by a non-Hub address.
    /// @dev Used by `onlyHub`.
    error OnlyHub();

    /// @notice Thrown when a reentrant call is detected within the ERC-1155 callback context.
    /// @dev Implemented via transient storage slot `0` in `nonReentrant`.
    error Reentrancy();

    /// @notice Thrown when the ERC-1155 transfer value is not exactly `REQUIRED_AMOUNT`.
    /// @dev Both single and batch callback paths require each element to match exactly.
    error NotExactlyRequiredAmount();

    /// @notice Thrown when the transferred CRC (ERC-1155 `id`) is not accepted by this module.
    /// @dev Acceptance is defined as the Hub trusting `address(uint160(id))` from this contract.
    error NotAcceptedCRC();

    /*//////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an address is added to the quota permission grantee list.
    /// @param grantee The address that has been granted permission.
    event QuotaPermissionGranted(address indexed grantee);

    /// @notice Emitted when an address is removed from the quota permission grantee list.
    /// @param grantee The address that has been revoked permission.
    event QuotaPermissionRevoked(address indexed grantee);

    /// @notice Emitted after a quota permission grantee sets an inviter’s quota through this module.
    /// @dev `grantee` is `msg.sender` (the authorized setter).
    /// @param grantee The grantee that initiated the quota update.
    /// @param inviter The inviter whose quota was set.
    /// @param quota The new absolute quota value set in the Invitation Farm.
    event InviterQuotaSet(address indexed grantee, address indexed inviter, uint256 indexed quota);

    /// @notice Emitted after the module increases an inviter’s quota due to receiving accepted CRC transfers.
    /// @dev `extraQuota` equals 1 for single receive, or `ids.length` for batch receive.
    /// @param inviter The inviter whose quota was increased (the ERC-1155 `from` address).
    /// @param extraQuota The amount added on top of the existing inviter quota.
    event InviterExtraQuotaAdded(address indexed inviter, uint256 indexed extraQuota);

    /*//////////////////////////////////////////////////////////////
                              Constants & Immutables
    //////////////////////////////////////////////////////////////*/

    /// @notice The Invitation Farm contract used to read and update inviter quotas.
    /// @dev Hard-coded deployment address.
    IInvitationFarm public constant INVITATION_FARM =
        IInvitationFarm(address(0xd28b7C4f148B1F1E190840A1f7A796C5525D8902));

    /// @notice The admin safe address as returned by `INVITATION_FARM.admin()` at deployment time.
    /// @dev This address is used for admin-only actions and as the recipient of forwarded ERC-1155 tokens.
    address public immutable INVITATION_FARM_ADMIN_SAFE;

    /// @notice The Circles v2 Hub contract.
    /// @dev Hard-coded deployment address; also the only allowed caller for ERC-1155 callbacks.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    /// @notice The exact amount (in token “value” units) required per ERC-1155 item transfer to grant quota.
    /// @dev Enforced per transfer item, including in batch transfers.
    uint256 public constant REQUIRED_AMOUNT = 96 ether;

    /// @notice Sentinel node for the internal linked list of grantees.
    /// @dev The mapping `quotaPermissionGrantees` forms a singly linked list:
    /// - `quotaPermissionGrantees[SENTINEL]` holds the current head (or SENTINEL if empty).
    /// - Each grantee maps to the next node.
    /// - A node is considered absent if its mapping value is `address(0)`.
    address private constant SENTINEL = address(0x1);

    /*//////////////////////////////////////////////////////////////
                                Storage
    //////////////////////////////////////////////////////////////*/

    /// @notice Singly linked list “next pointer” mapping for quota permission grantees.
    /// @dev
    /// - If `quotaPermissionGrantees[grantee] == address(0)`, `grantee` is not in the list.
    /// - `quotaPermissionGrantees[SENTINEL]` is the head pointer (or `SENTINEL` if list is empty).
    /// - Insertions are done at the head.
    /// - Removals traverse from SENTINEL until the target node is found.
    mapping(address => address) public quotaPermissionGrantees;

    /*//////////////////////////////////////////////////////////////
                                 Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts execution to calls made by the admin safe.
    /// @dev Reverts with {OnlyAdmin} when `msg.sender != INVITATION_FARM_ADMIN_SAFE`.
    modifier onlyAdmin() {
        if (msg.sender != INVITATION_FARM_ADMIN_SAFE) revert OnlyAdmin();
        _;
    }

    /// @notice Restricts execution to calls made by authorized quota permission grantees.
    /// @dev Reverts with {OnlyQuotaPermissionGrantee} when the caller is not present in the linked list.
    modifier onlyQuotaPermissionGrantee() {
        if (quotaPermissionGrantees[msg.sender] == address(0)) revert OnlyQuotaPermissionGrantee();
        _;
    }

    /// @notice Restricts function entry to calls originating from the Hub.
    /// @dev Reverts with {OnlyHub} if `msg.sender != HUB`.
    modifier onlyHub() {
        if (msg.sender != address(HUB)) revert OnlyHub();
        _;
    }

    /// @notice Prevents reentrancy in the ERC-1155 callback entrypoints.
    /// @dev
    /// Uses EIP-1153 transient storage at slot `0`:
    /// - If the slot is already set, reverts with {Reentrancy}.
    /// - Sets slot to 1 for the duration of the call, then clears it back to 0.
    modifier nonReentrant() {
        assembly {
            if tload(0) {
                // revert Reentrancy()
                mstore(0, 0xab143c06)
                revert(0x1c, 0x4)
            }
            tstore(0, 1)
        }
        _;
        assembly {
            tstore(0, 0)
        }
    }

    /*//////////////////////////////////////////////////////////////
                               Constructor
    //////////////////////////////////////////////////////////////*/

    /// @notice
    /// Initializes the module by reading the admin safe from the Invitation Farm and registering an organization
    /// name in the Hub.
    /// @dev
    /// - Sets `INVITATION_FARM_ADMIN_SAFE = INVITATION_FARM.admin()`.
    /// - Calls `HUB.registerOrganization("InvitationQuotaGrant", bytes32(0))`.
    /// - The Hub registration is performed unconditionally; failures will revert deployment.
    constructor() {
        INVITATION_FARM_ADMIN_SAFE = INVITATION_FARM.admin();
        HUB.registerOrganization("InvitationQuotaGrant", bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                               Admin Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets whether a CRC address is accepted by this module for quota granting.
    /// @dev
    /// Acceptance is enforced later in `_validateExactValueAndCRCAcceptance` by checking:
    /// `HUB.isTrusted(address(this), crc)`.
    ///
    /// Implementation details:
    /// - If `accept == true`, sets expiry to `type(uint96).max` (effectively “never expires”).
    /// - If `accept == false`, sets expiry to `0` (effectively “not trusted”).
    /// - Delegates to `HUB.trust(crc, expiry)`.
    ///
    /// Access: `onlyAdmin`.
    /// @param crc The CRC address (trust target) to accept or unaccept.
    /// @param accept Whether to accept (`true`) or revoke acceptance (`false`).
    function setAcceptedCRC(address crc, bool accept) external onlyAdmin {
        uint96 expiry;
        if (accept) expiry = type(uint96).max;
        HUB.trust(crc, expiry);
    }

    /// @notice Adds or removes an address from the quota permission grantee set.
    /// @dev
    /// Uses a sentinel-based singly linked list in `quotaPermissionGrantees`.
    ///
    /// Enabling (`enabled == true`):
    /// - No-ops if `grantee` is `SENTINEL` or `address(0)`.
    /// - No-ops if `grantee` is already in the list (`quotaPermissionGrantees[grantee] != address(0)`).
    /// - Inserts `grantee` at the head:
    ///   - `previous = quotaPermissionGrantees[SENTINEL]` (or `SENTINEL` if empty)
    ///   - `quotaPermissionGrantees[grantee] = previous`
    ///   - `quotaPermissionGrantees[SENTINEL] = grantee`
    /// - Emits {QuotaPermissionGranted}.
    ///
    /// Disabling (`enabled == false`):
    /// - No-ops if `grantee` is not in the list (`quotaPermissionGrantees[grantee] == address(0)`).
    /// - Traverses from `SENTINEL` until `current == grantee`, tracking `previous`.
    /// - Relinks `previous` to `previousGrantee` (the next pointer of `grantee`).
    /// - Clears `quotaPermissionGrantees[grantee]` to `address(0)`.
    /// - Emits {QuotaPermissionRevoked}.
    ///
    /// Access: `onlyAdmin`.
    /// @param grantee The address to add/remove.
    /// @param enabled `true` to grant permission; `false` to revoke.
    function grantQuotaPermission(address grantee, bool enabled) external onlyAdmin {
        if (grantee == SENTINEL || grantee == address(0)) return;
        if (enabled) {
            address previous = quotaPermissionGrantees[grantee];
            if (previous != address(0)) return;
            previous = quotaPermissionGrantees[SENTINEL];
            if (previous == address(0)) previous = SENTINEL;
            // Link the new node to the old head
            quotaPermissionGrantees[grantee] = previous;
            // Update head pointer to the new node
            quotaPermissionGrantees[SENTINEL] = grantee;
            emit QuotaPermissionGranted(grantee);
        } else {
            address previousGrantee = quotaPermissionGrantees[grantee];
            if (previousGrantee == address(0)) return;
            address current = SENTINEL;
            address previous;

            // Traverse until current == grantee
            while (current != grantee) {
                previous = current;
                current = quotaPermissionGrantees[current];
            }
            // Link the node that pointed to grantee to previousGrantee grantee pointed to
            quotaPermissionGrantees[previous] = previousGrantee;
            // Clear the removed node’s pointer
            quotaPermissionGrantees[grantee] = address(0);
            emit QuotaPermissionRevoked(grantee);
        }
    }

    /*//////////////////////////////////////////////////////////////
                               Grantees
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets an inviter’s quota in the Invitation Farm to an absolute value.
    /// @dev
    /// - Restricted to `onlyQuotaPermissionGrantee`.
    /// - Calls `_setInviterQuota(inviter, quota)` which executes via the admin safe module manager.
    /// - Emits {InviterQuotaSet} with `grantee = msg.sender`.
    ///
    /// @param inviter The inviter address whose quota will be set in the Invitation Farm.
    /// @param quota The new absolute quota to set.
    function setInviterQuota(address inviter, uint256 quota) external onlyQuotaPermissionGrantee {
        _setInviterQuota(inviter, quota);
        emit InviterQuotaSet(msg.sender, inviter, quota);
    }

    /*//////////////////////////////////////////////////////////////
                                 Internal
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a quota update in the Invitation Farm via the admin safe module manager.
    /// @dev
    /// - Encodes a call to `IInvitationFarm.setInviterQuota(inviter, quota)`.
    /// - Invokes `execTransactionFromModuleReturnData` on `INVITATION_FARM_ADMIN_SAFE` (as `IModuleManager`),
    ///   targeting the Invitation Farm with:
    ///   - `to = address(INVITATION_FARM)`
    ///   - `value = 0`
    ///   - `data = callData`
    ///   - `operation = uint8(0)` (call)
    /// - If the call fails, bubbles up the revert reason from `returnData` as-is.
    ///
    /// @param inviter The inviter whose quota will be set.
    /// @param quota The new absolute quota to set.
    function _setInviterQuota(address inviter, uint256 quota) internal {
        bytes memory callData = abi.encodeWithSelector(bytes4(IInvitationFarm.setInviterQuota.selector), inviter, quota);
        (bool success, bytes memory returnData) = IModuleManager(INVITATION_FARM_ADMIN_SAFE)
            .execTransactionFromModuleReturnData(address(INVITATION_FARM), 0, callData, uint8(0));
        if (!success) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    /// @notice Validates that the ERC-1155 transfer value is exactly `REQUIRED_AMOUNT` and that the CRC is accepted.
    /// @dev
    /// - Reverts with {NotExactlyRequiredAmount} if `value != REQUIRED_AMOUNT`.
    /// - Reverts with {NotAcceptedCRC} if `HUB.isTrusted(address(this), address(uint160(id)))` is false.
    ///
    /// CRC derivation:
    /// - The ERC-1155 `id` is treated as a 160-bit address via `address(uint160(id))`.
    ///
    /// @param value The ERC-1155 transfer amount for the given `id`.
    /// @param id The ERC-1155 token id, interpreted as the CRC address (lower 160 bits).
    function _validateExactValueAndCRCAcceptance(uint256 value, uint256 id) internal view {
        if (value != REQUIRED_AMOUNT) revert NotExactlyRequiredAmount();
        if (!HUB.isTrusted(address(this), address(uint160(id)))) revert NotAcceptedCRC();
    }

    /// @notice Increases an inviter’s quota in the Invitation Farm by `extraQuota`.
    /// @dev
    /// - Reads current quota using `INVITATION_FARM.inviterQuota(inviter)`.
    /// - Writes back `quota + extraQuota` via `_setInviterQuota`.
    /// - Emits {InviterExtraQuotaAdded}.
    ///
    /// @param inviter The inviter whose quota will be increased.
    /// @param extraQuota The amount to add to the inviter’s quota.
    function _increaseQuota(address inviter, uint256 extraQuota) internal {
        uint256 quota = INVITATION_FARM.inviterQuota(inviter);
        _setInviterQuota(inviter, quota + extraQuota);
        emit InviterExtraQuotaAdded(inviter, extraQuota);
    }

    /*//////////////////////////////////////////////////////////////
                           ERC-1155 Callbacks
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC-1155 single-token receipt callback.
    /// @dev
    /// Requirements:
    /// - Caller must be the Hub (`onlyHub`).
    /// - Non-reentrant (`nonReentrant`).
    /// - `value` must equal `REQUIRED_AMOUNT`.
    /// - `id` must correspond to an accepted CRC (Hub trust check).
    ///
    /// Effects:
    /// - Increases quota for `from` by 1.
    /// - Forwards the received token to `INVITATION_FARM_ADMIN_SAFE` using the Hub’s `safeTransferFrom`.
    ///
    /// Return value:
    /// - Returns this function’s selector to signal acceptance.
    ///
    /// @param from The address that sent the ERC-1155 token to this contract (inviter to be credited).
    /// @param id The ERC-1155 token id; interpreted as a CRC address (lower 160 bits).
    /// @param value The amount transferred; must be exactly `REQUIRED_AMOUNT`.
    /// @return The selector `onERC1155Received.selector`.
    function onERC1155Received(address, address from, uint256 id, uint256 value, bytes memory)
        external
        onlyHub
        nonReentrant
        returns (bytes4)
    {
        _validateExactValueAndCRCAcceptance(value, id);
        _increaseQuota(from, 1);
        HUB.safeTransferFrom(address(this), INVITATION_FARM_ADMIN_SAFE, id, value, "");
        return this.onERC1155Received.selector;
    }

    /// @notice ERC-1155 batch receipt callback.
    /// @dev
    /// Requirements:
    /// - Caller must be the Hub (`onlyHub`).
    /// - Non-reentrant (`nonReentrant`).
    /// - For each index `i`, `values[i]` must equal `REQUIRED_AMOUNT`.
    /// - For each index `i`, `ids[i]` must correspond to an accepted CRC (Hub trust check).
    ///
    /// Effects:
    /// - Computes `extraQuota = ids.length` and increases quota for `from` by that amount.
    /// - Forwards the received batch to `INVITATION_FARM_ADMIN_SAFE` via `safeBatchTransferFrom`.
    ///
    /// Return value:
    /// - Returns this function’s selector to signal acceptance.
    ///
    /// Notes:
    /// - The loop validates each `(ids[i], values[i])` pair.
    /// - The loop uses `unchecked` increment for gas savings; bounded by `ids.length`.
    ///
    /// @param from The address that sent the ERC-1155 tokens to this contract (inviter to be credited).
    /// @param ids The ERC-1155 token ids; each interpreted as a CRC address (lower 160 bits).
    /// @param values The amounts transferred for each id; each must be exactly `REQUIRED_AMOUNT`.
    /// @return The selector `onERC1155BatchReceived.selector`.
    function onERC1155BatchReceived(address, address from, uint256[] memory ids, uint256[] memory values, bytes memory)
        external
        onlyHub
        nonReentrant
        returns (bytes4)
    {
        uint256 extraQuota = ids.length;
        for (uint256 i; i < extraQuota;) {
            _validateExactValueAndCRCAcceptance(values[i], ids[i]);
            unchecked {
                ++i;
            }
        }
        _increaseQuota(from, extraQuota);
        HUB.safeBatchTransferFrom(address(this), INVITATION_FARM_ADMIN_SAFE, ids, values, "");
        return this.onERC1155BatchReceived.selector;
    }
}
