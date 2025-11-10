// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {ReferralsModule} from "src/ReferralsModule.sol";

contract DeployInvitationModule is Script {
    address invitationModule = 0x00738aca013B7B2e6cfE1690F0021C3182Fa40B5;
    ReferralsModule public referralsModule;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        referralsModule = new ReferralsModule(invitationModule);

        vm.stopBroadcast();
    }
}
