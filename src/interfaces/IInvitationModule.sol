// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

interface IInvitationModule {
    function GENERIC_CALL_PROXY() external view returns (address);
    function getOriginInviter() external view returns (address originInviter);
}
