// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

interface IInvitationFarm {
    error ExceedsInviteQuota();
    error FarmIsDrained();
    error OnlyAdmin();
    error OnlyGenericCallProxy();
    error OnlyHumanAvatarsAreInviters(address avatar);
    error OnlyMaintainer();
    error OnlySeederOrBot();

    event AdminSet(address indexed newAdmin);
    event BotCreated(address indexed createdBot);
    event FarmGrown(address indexed maintainer, uint256 indexed numberOfBots, uint256 indexed totalNumberOfBots);
    event InvitationModuleUpdated(address indexed module, address indexed genericCallProxy);
    event InviterQuotaUpdated(address indexed inviter, uint256 indexed quota);
    event InvitesClaimed(address indexed inviter, uint256 indexed count);
    event MaintainerSet(address indexed maintainer);
    event SeederSet(address indexed seeder);

    function HUB() external view returns (address);
    function INVITATION_FEE() external view returns (uint256);
    function NAME_REGISTRY() external view returns (address);
    function admin() external view returns (address);
    function bots(address bot) external view returns (address nextBot);
    function claimInvite() external returns (uint256 id);
    function claimInvites(uint256 numberOfInvites) external returns (uint256[] memory ids);
    function createBot() external returns (address createdBot);
    function createBots(uint256 numberOfBots) external returns (address[] memory createdBots);
    function growFarm(uint256 numberOfBots) external;
    function invitationModule() external view returns (address);
    function inviterQuota(address) external view returns (uint256);
    function lastUsedBot() external view returns (address);
    function maintainBots(uint256 iterations) external;
    function maintainer() external view returns (address);
    function seeder() external view returns (address);
    function setAdmin(address newAdmin) external;
    function setInviterQuota(address inviter, uint256 quota) external;
    function setMaintainer(address newMaintainer) external;
    function setSeeder(address newSeeder) external;
    function totalBots() external view returns (uint256);
    function updateBotMetadataDigest(address startBot, uint256 numberOfBots, bytes32 metadataDigest)
        external
        returns (address);
    function updateInvitationModule(address newInvitationModule) external;
}
