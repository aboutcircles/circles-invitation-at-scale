// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {HubStorageWrites} from "test/helpers/HubStorageWrites.sol";
import {IModuleManager} from "src/interfaces/IModuleManager.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {InvitationModule} from "src/InvitationModule.sol";
import {ReferralsModule} from "src/ReferralsModule.sol";

interface ISafe {
    function getStorageAt(uint256 offset, uint256 length) external view returns (bytes memory);
}

contract ReferralsModuleTest is Test, HubStorageWrites {
    uint256 internal constant SIGNER_SLOT =
        38553689938471249931580260399865754279307054632110400389912672281974829735002;
    uint64 public day;
    uint256 internal gnosisFork;

    InvitationModule public invitationModule;
    ReferralsModule public referralsModule;

    address originInviter = 0x68e3c2aa468D9a80A8d9Bb8fC53bf072FE98B83a;
    address proxyInviter = 0x3A63F544918051f9285cf97008705790FD280012;

    // test passkeys
    address verifier = 0x445a0683e494ea0c5AF3E83c5159fBE47Cf9e765;
    uint256 x1 = uint256(bytes32(0x3e7e62c2aa625b98d1ca643e93b6081ca0421fbf836bbbaace3f439b7691bba5));
    uint256 y1 = uint256(bytes32(0x4477cdcb2e11c0a864da1d4cfff6d6097293a9936cab3076c8a68f3cb68b70f1));
    uint256 x2 = uint256(bytes32(0x770326b515dcf72d2211b82b474a84a3f903e9dc612f4d6a1088e04c5849046f));
    uint256 y2 = uint256(bytes32(0x239c115887b698669498eb595a7d2fadb66d912f95c691e2dcc22161ce2ba036));

    // test offchain secrets
    address signer1 = 0xeA90D70a428500B5cA85DCa9792A52a3b852D307;
    uint256 pk1 = 0x592da4069533d8c23fe722ca42c45074315000a188003a518fc165d8dccd11ba;
    address signer2 = 0x582f688fAb9BE0053B365556981dEBA8Ba7D4280;
    uint256 pk2 = 0x8f7268379df23b4b20d0cae9c32e6f6283adc09a559d97cd648f3b9058686bcf;

    function setUp() public {
        gnosisFork = vm.createFork(vm.envString("GNOSIS_RPC"));
        vm.selectFork(gnosisFork);

        invitationModule = new InvitationModule();
        referralsModule = new ReferralsModule(address(invitationModule));

        // set current day
        day = IHub(HUB).day(block.timestamp);
        // create test human accounts as safes
        // proxy
        _registerHuman(proxyInviter);
        _simulateSafe(proxyInviter);
        // origin
        _registerHuman(originInviter);
        _simulateSafe(originInviter);
        // give origin 96 CRC of own and proxy
        _setCRCBalance(uint256(uint160(originInviter)), originInviter, day, uint192(96 ether));
        _setCRCBalance(uint256(uint160(proxyInviter)), originInviter, day, uint192(96 ether));

        // enable invitation module for actors
        vm.prank(proxyInviter);
        IModuleManager(proxyInviter).enableModule(address(invitationModule));
        vm.prank(originInviter);
        IModuleManager(originInviter).enableModule(address(invitationModule));

        // set proxy trust origin (the requirement to involve as proxy inviter)
        _setTrust(proxyInviter, originInviter);
    }

    function testReferrals() public {
        // the public addresses of offchain shared secrets
        address[] memory signers = new address[](2);
        signers[0] = signer1;
        signers[1] = signer2;

        bytes memory data = abi.encode(
            address(referralsModule), abi.encodeWithSelector(bytes4(ReferralsModule.createAccounts.selector), signers)
        );

        // create 2 referrals using own and proxy CRCs
        vm.startPrank(originInviter);
        uint256[] memory ids = new uint256[](2);
        ids[0] = uint256(uint160(originInviter));
        ids[1] = uint256(uint160(proxyInviter));
        uint256[] memory values = new uint256[](ids.length);
        for (uint256 i; i < values.length; i++) {
            values[i] = 96 ether;
        }

        IHub(HUB).safeBatchTransferFrom(originInviter, address(invitationModule), ids, values, data);

        vm.stopPrank();

        // claim same day first account

        bytes32 digest = referralsModule.getPasskeyHash(x1, y1, verifier);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk1, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        referralsModule.claimAccount(x1, y1, verifier, signature);

        (address account,) = referralsModule.accounts(signer1);

        assertTrue(IHub(HUB).isHuman(account));

        assertEq(IHub(HUB).balanceOf(account, uint256(uint160(account))), 48 ether);

        bytes memory passkey = abi.encode(x1, y1, verifier);
        bytes memory storedPasskey = ISafe(account).getStorageAt(SIGNER_SLOT, 3);
        assertEq(keccak256(passkey), keccak256(storedPasskey));

        // lets move 3 days before claim next account
        vm.warp(block.timestamp + 3 days);

        // claim in 3 days

        digest = referralsModule.getPasskeyHash(x2, y2, verifier);

        (v, r, s) = vm.sign(pk2, digest);
        signature = abi.encodePacked(r, s, v);

        referralsModule.claimAccount(x2, y2, verifier, signature);

        (account,) = referralsModule.accounts(signer2);

        assertTrue(IHub(HUB).isHuman(account));

        assertEq(IHub(HUB).balanceOf(account, uint256(uint160(account))), 48 ether);

        passkey = abi.encode(x2, y2, verifier);
        storedPasskey = ISafe(account).getStorageAt(SIGNER_SLOT, 3);
        assertEq(keccak256(passkey), keccak256(storedPasskey));
    }
}
