// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {InviterVolunteerModule} from "src/InviterVolunteerModule.sol";

contract InviterVolunteerModuleScript is Script {
    InviterVolunteerModule public inviterVolunteerModule;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        inviterVolunteerModule = new InviterVolunteerModule();

        vm.stopBroadcast();
    }
}
