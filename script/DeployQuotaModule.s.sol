// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {InvitationQuotaGrantModule} from "src/InvitationQuotaGrantModule.sol";

contract DeployQuotaModule is Script {
    address deployer = address(0x5dc7196C5636D2CEf9Dbc78aa13a164026ba1240);
    InvitationQuotaGrantModule public quotaModule; // 0x9Eb51E6A39B3F17bB1883B80748b56170039ff1d

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        quotaModule = new InvitationQuotaGrantModule();

        vm.stopBroadcast();
    }
}
