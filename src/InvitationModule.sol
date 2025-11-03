// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IModuleManager} from "src/interfaces/IModuleManager.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {GenericCallProxy} from "src/GenericCallProxy.sol";

contract InvitationModule {
    /*//////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/
    error OnlyHub();
    error Reentrancy();
    error InvalidEncoding();
    error ArrayLengthMismatch();
    error TooFewInvites();
    error NotExactInvitationFee();
    error ModuleNotEnabled(address avatar);
    error HumanValidationFailed(address avatar);
    error TrustRequired(address truster, address trustee);
    error InviteeAlreadyRegistered(address invitee);
    error HumanRegistrationFailed(address invitee);
    error TrustEnforcementFailed(address truster, address trustee);

    /*//////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    event RegisterHuman(address indexed human, address indexed originInviter, address indexed proxyInviter);

    /*//////////////////////////////////////////////////////////////
                              Constants & Immutables
    //////////////////////////////////////////////////////////////*/

    /// @notice Circles v2 Hub.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));
    uint256 public constant INVITATION_FEE = 96 ether;
    GenericCallProxy public immutable GENERIC_CALL_PROXY;

    /*//////////////////////////////////////////////////////////////
                                 Modifiers
    //////////////////////////////////////////////////////////////*/

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

    /// @notice Restricts to Hub callbacks.
    modifier onlyHub() {
        if (msg.sender != address(HUB)) revert OnlyHub();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               Constructor
    //////////////////////////////////////////////////////////////*/

    constructor() {
        GENERIC_CALL_PROXY = new GenericCallProxy();
        HUB.registerOrganization("InvitationModule", bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                                External
    //////////////////////////////////////////////////////////////*/

    // should be called together with enabling the module
    function trustInviter(address inviter) external {
        validateInviter(inviter);
        // make org trust id
        HUB.trust(inviter, type(uint96).max);
    }

    function getOriginInviter() external view returns (address originInviter) {
        assembly {
            originInviter := tload(0)
        }
    }

    /*//////////////////////////////////////////////////////////////
                         Internal: Validation (view)
    //////////////////////////////////////////////////////////////*/

    function validateModuleEnabled(address safe) internal view {
        if (!_isModuleEnabled(safe)) revert ModuleNotEnabled(safe);
    }

    function validateTrust(address truster, address trustee) internal view {
        // check proxy inviter trusts origin inviter
        if (!_isTrusted(truster, trustee)) revert TrustRequired(truster, trustee);
    }

    function validateHuman(address avatar) internal view {
        if (!_isHuman(avatar)) revert HumanValidationFailed(avatar);
    }

    function validateInviter(address inviter) internal view {
        validateHuman(inviter);
        validateModuleEnabled(inviter);
    }

    /*//////////////////////////////////////////////////////////////
                     Internal: Enforcement / Core Logic
    //////////////////////////////////////////////////////////////*/

    // pre-checks module enabled required
    function enforceTrust(address truster, address trustee, uint96 expiry) internal {
        bytes memory data = abi.encodeWithSelector(IHub.trust.selector, trustee, expiry);
        _callHubFromSafe(truster, data);
        // sanity check in case truster is custom contract implementing Safe interface
        if (!_isTrusted(truster, trustee)) revert TrustEnforcementFailed(truster, trustee);
    }

    function enforceHumanRegistered(address invitee, address inviter) internal {
        // check invitee has module enabled
        validateModuleEnabled(invitee);

        if (HUB.avatars(invitee) != address(0)) revert InviteeAlreadyRegistered(invitee);

        // make invitee register as human
        // ASSUMPTION: the default safe deployment flow calls NameRegistry.updateMetadataDigest(bytes32) to set metadatadigest, what
        // allows to set metadatadigest as bytes32(0) to not overwrite previous value
        // in case this wasn't done the metadatadigest should be updated after registration
        bytes memory data = abi.encodeWithSelector(IHub.registerHuman.selector, inviter, bytes32(0));
        _callHubFromSafe(invitee, data);
        // sanity check in case invitee is custom contract implementing Safe interface
        if (!_isHuman(invitee)) revert HumanRegistrationFailed(invitee);

        // make this org trust id
        HUB.trust(invitee, type(uint96).max);
    }

    function proxyInvite(address proxyInviter, address invitee) internal {
        // transfer 96 CRC to proxy inviter
        HUB.safeTransferFrom(address(this), proxyInviter, uint256(uint160(proxyInviter)), INVITATION_FEE, "");

        // enforce invitee to register as human
        enforceHumanRegistered(invitee, proxyInviter);
    }

    /*//////////////////////////////////////////////////////////////
                     Internal: Low-level / Helper Utils
    //////////////////////////////////////////////////////////////*/

    function _callHubFromSafe(address safe, bytes memory callData) internal {
        (bool success, bytes memory returnData) =
            IModuleManager(safe).execTransactionFromModuleReturnData(address(HUB), uint256(0), callData, uint8(0));
        if (!success) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    function _isGenericCall(bytes memory data) internal pure returns (bool) {
        uint256 firstWord;
        assembly {
            firstWord := mload(add(data, 0x20))
        }
        return firstWord > data.length;
    }

    function _isTrusted(address truster, address trustee) internal view returns (bool) {
        return HUB.isTrusted(truster, trustee);
    }

    function _isHuman(address avatar) internal view returns (bool) {
        return HUB.isHuman(avatar);
    }

    function _isModuleEnabled(address safe) internal view returns (bool) {
        return IModuleManager(safe).isModuleEnabled(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                           ERC-1155 Callbacks
    //////////////////////////////////////////////////////////////*/

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
            validateTrust(proxyInviter, originInviter);
        }

        enforceTrust(proxyInviter, invitee, directInvite ? type(uint96).max : uint96(block.timestamp));

        proxyInvite(proxyInviter, invitee);

        if (!directInvite) enforceTrust(originInviter, invitee, type(uint96).max);

        emit RegisterHuman(invitee, originInviter, proxyInviter);

        return this.onERC1155Received.selector;
    }

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
