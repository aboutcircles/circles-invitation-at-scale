// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {InviterVolunteerModule} from "src/InviterVolunteerModule.sol";

contract InviterVolunteerModuleTest is Test {
    InviterVolunteerModule public inviterVolunteerModule;

    function setUp() public {
        inviterVolunteerModule = new InviterVolunteerModule();
    }

    function testDefault() public {
        
    }
}
