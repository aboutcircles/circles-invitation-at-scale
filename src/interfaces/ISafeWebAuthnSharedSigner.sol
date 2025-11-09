// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

interface ISafeWebAuthnSharedSigner {
    struct Signer {
        uint256 x;
        uint256 y;
        uint176 verifiers;
    }

    function configure(Signer memory signer) external;
}