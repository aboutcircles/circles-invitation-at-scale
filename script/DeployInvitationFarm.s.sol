// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {InvitationFarm} from "src/InvitationFarm.sol";

contract DeployInvitationFarm is Script {
    address deployer = address(0xe4b40c78A4D8449864c8Ec89b4500F60e4a0bbb7);
    address invitationModule = 0x00738aca013B7B2e6cfE1690F0021C3182Fa40B5;
    InvitationFarm public invitationFarm; // 0xd28b7C4f148B1F1E190840A1f7A796C5525D8902

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        invitationFarm = new InvitationFarm(invitationModule);

        vm.stopBroadcast();
    }
}
