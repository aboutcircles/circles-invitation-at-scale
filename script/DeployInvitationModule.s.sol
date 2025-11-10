// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {InvitationModule} from "src/InvitationModule.sol";

contract DeployInvitationModule is Script {
    address deployer = address(0x2CCfe36bcF800Ee54C269047ADEa154cE1f80923);
    InvitationModule public invitationModule; // 0x00738aca013B7B2e6cfE1690F0021C3182Fa40B5

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        invitationModule = new InvitationModule();

        vm.stopBroadcast();
    }
}
