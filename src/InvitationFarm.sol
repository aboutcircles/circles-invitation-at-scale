// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IHub} from "src/interfaces/IHub.sol";
import {INameRegistry} from "src/interfaces/INameRegistry.sol";
import {IInvitationModule} from "src/interfaces/IInvitationModule.sol";
import {InvitationBot} from "src/InvitationBot.sol";

contract InvitationFarm {
    /*//////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/
    error OnlyAdmin();
    error OnlyMaintainer();
    error OnlySeederOrBot();
    error ExceedsInviteQuota();
    error FarmIsDrained();
    error OnlyGenericCallProxy();
    error OnlyHumanAvatarsAreInviters(address avatar);

    /*//////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/
    event AdminSet(address indexed newAdmin);

    event MaintainerSet(address indexed maintainer);

    event SeederSet(address indexed seeder);

    event InviterQuotaUpdated(address indexed inviter, uint256 indexed quota);

    event InvitationModuleUpdated(address indexed module, address indexed genericCallProxy);

    event BotCreated(address indexed createdBot);

    event InvitesClaimed(address indexed inviter, uint256 indexed count);

    event FarmGrown(address indexed maintainer, uint256 indexed numberOfBots, uint256 indexed totalNumberOfBots);

    /*//////////////////////////////////////////////////////////////
                              Constants & Immutables
    //////////////////////////////////////////////////////////////*/

    /// @notice Circles v2 Hub.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));
    /// @notice Circles v2 Name Registry contract.
    address public constant NAME_REGISTRY = address(0xA27566fD89162cC3D40Cb59c87AAaA49B85F3474);
    address private constant SENTINEL = address(0x1);
    uint256 public constant INVITATION_FEE = 96 ether;

    /*//////////////////////////////////////////////////////////////
                                Storage
    //////////////////////////////////////////////////////////////*/

    address public admin;
    address public invitationModule;
    address internal genericCallProxy;
    address public seeder;
    address public maintainer;

    // linked list for all bots
    mapping(address bot => address nextBot) public bots;
    uint256 public totalBots;
    // flag to keep track of last used bot to start with and check 96 crc balance is present, move to next one and update the flag
    address public lastUsedBot;

    mapping(address => uint256) public inviterQuota;

    /*//////////////////////////////////////////////////////////////
                                 Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts to Admin calls.
    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier onlyMaintainer() {
        if (msg.sender != maintainer) revert OnlyMaintainer();
        _;
    }

    modifier onlySeederOrBot() {
        address originInviter = _getOriginInviter();
        if (originInviter != seeder && bots[originInviter] == address(0)) revert OnlySeederOrBot();
        _;
    }

    modifier onlyGenericCallProxy() {
        if (msg.sender != genericCallProxy) revert OnlyGenericCallProxy();
        _;
    }

    modifier withinInviteQuota(uint256 numberOfInvites) {
        uint256 remaining = inviterQuota[msg.sender];
        if (remaining == 0 || numberOfInvites > remaining) revert ExceedsInviteQuota();
        inviterQuota[msg.sender] -= numberOfInvites;
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               Constructor
    //////////////////////////////////////////////////////////////*/

    constructor(address _invitationModule) {
        invitationModule = _invitationModule;
        genericCallProxy = IInvitationModule(_invitationModule).GENERIC_CALL_PROXY();
        admin = msg.sender;
    }

    // admin functions

    function setAdmin(address newAdmin) external onlyAdmin {
        admin = newAdmin;
        emit AdminSet(newAdmin);
    }

    function setSeeder(address newSeeder) external onlyAdmin {
        validateHuman(newSeeder);
        seeder = newSeeder;
        emit SeederSet(newSeeder);
    }

    function setMaintainer(address newMaintainer) external onlyAdmin {
        maintainer = newMaintainer;
        emit MaintainerSet(maintainer);
    }

    function setInviterQuota(address inviter, uint256 quota) external onlyAdmin {
        validateHuman(inviter);
        inviterQuota[inviter] = quota;
        emit InviterQuotaUpdated(inviter, quota);
    }

    function updateInvitationModule(address newInvitationModule) external onlyAdmin {
        invitationModule = newInvitationModule;
        genericCallProxy = IInvitationModule(newInvitationModule).GENERIC_CALL_PROXY();
        emit InvitationModuleUpdated(newInvitationModule, genericCallProxy);
    }

    // init function

    function createBots(uint256 numberOfBots)
        external
        onlyGenericCallProxy
        onlySeederOrBot
        returns (address[] memory createdBots)
    {
        createdBots = new address[](numberOfBots);
        for (uint256 i; i < numberOfBots;) {
            address bot = address(new InvitationBot());
            createdBots[i] = bot;
            _addBot(bot);
            emit BotCreated(bot);
            unchecked {
                ++i;
            }
        }
    }

    function createBot() external onlyGenericCallProxy onlySeederOrBot returns (address createdBot) {
        createdBot = address(new InvitationBot());
        _addBot(createdBot);
        emit BotCreated(createdBot);
    }

    // maintaner functions

    function updateBotMetadataDigest(address startBot, uint256 numberOfBots, bytes32 metadataDigest)
        external
        onlyMaintainer
        returns (address)
    {
        if (numberOfBots > totalBots) numberOfBots = totalBots;
        address bot = startBot;
        for (uint256 i; i < numberOfBots;) {
            if (bot == SENTINEL) bot = bots[SENTINEL];
            _updateBotMetadataDigest(bot, metadataDigest);
            bot = bots[bot];
            unchecked {
                ++i;
            }
        }
        return bot;
    }

    function maintainBots(uint256 iterations) external onlyMaintainer {
        if (iterations > totalBots) iterations = totalBots;
        address bot = lastUsedBot;
        for (uint256 i; i < iterations;) {
            _mintAsBot(bot);
            bot = bots[bot];
            if (bot == SENTINEL) bot = bots[SENTINEL];
            unchecked {
                ++i;
            }
        }
        lastUsedBot = bot;
    }

    function growFarm(uint256 numberOfBots) external onlyMaintainer {
        _transferFromBots(numberOfBots, invitationModule, false);
        emit FarmGrown(msg.sender, numberOfBots, totalBots);
    }

    // share invites
    function claimInvites(uint256 numberOfInvites)
        public
        withinInviteQuota(numberOfInvites)
        returns (uint256[] memory ids)
    {
        ids = _transferFromBots(numberOfInvites, msg.sender, true);
        emit InvitesClaimed(msg.sender, ids.length);
    }

    function claimInvite() external returns (uint256 id) {
        uint256[] memory ids = claimInvites(1);
        id = ids[0];
    }

    function _transferFromBots(uint256 numberOfInvites, address receiver, bool forClaiming)
        internal
        returns (uint256[] memory ids)
    {
        ids = new uint256[](numberOfInvites);

        uint256 index;
        address startBot = lastUsedBot;
        address botToUse = startBot;
        uint256 botBalance;
        while (numberOfInvites != 0) {
            botBalance = _refreshAndGetBotBalance(botToUse);
            if (botBalance >= INVITATION_FEE) {
                uint256 capacity = botBalance / INVITATION_FEE;
                if (capacity > numberOfInvites) capacity = numberOfInvites;
                for (uint256 i; i < capacity;) {
                    ids[index++] = uint256(uint160(botToUse));
                    unchecked {
                        ++i;
                    }
                }
                _transferInvitesFromBot(
                    botToUse,
                    forClaiming,
                    receiver,
                    capacity,
                    forClaiming
                        ? new bytes(0)
                        : abi.encode(
                            address(this),
                            capacity == 1
                                ? abi.encodeWithSelector(bytes4(InvitationFarm.createBot.selector))
                                : abi.encodeWithSelector(bytes4(InvitationFarm.createBots.selector), capacity)
                        )
                );
                numberOfInvites -= capacity;
            }
            botToUse = bots[botToUse];
            if (botToUse == SENTINEL) botToUse = bots[SENTINEL];
            if (botToUse == startBot) break;
        }
        if (botToUse == startBot && numberOfInvites != 0) revert FarmIsDrained();
        lastUsedBot = botToUse;
    }

    // internal

    function validateHuman(address avatar) internal view {
        if (!HUB.isHuman(avatar)) revert OnlyHumanAvatarsAreInviters(avatar);
    }

    function _getOriginInviter() internal view returns (address) {
        return IInvitationModule(invitationModule).getOriginInviter();
    }

    function _addBot(address bot) internal {
        // Load the current head; if unset (zero), treat as empty and point to SENTINEL
        address previous = bots[SENTINEL];
        if (previous == address(0)) {
            previous = SENTINEL;
            lastUsedBot = bot;
        }
        // Link the new node to the old head
        bots[bot] = previous;
        // Update head pointer to the new node
        bots[SENTINEL] = bot;
        totalBots++;
    }

    // bot interactions

    function _mintAsBot(address bot) internal {
        bytes memory callData = abi.encodeWithSelector(IHub.personalMint.selector);
        _callHubAsBot(bot, callData);
    }

    function _refreshAndGetBotBalance(address bot) internal returns (uint256 balance) {
        _mintAsBot(bot);
        balance = HUB.balanceOf(bot, uint256(uint160(bot)));
    }

    function _transferInvitesFromBot(
        address bot,
        bool forClaiming,
        address to,
        uint256 numberOfInvites,
        bytes memory data
    ) internal {
        if (forClaiming) {
            bytes memory trustCallData = abi.encodeWithSelector(IHub.trust.selector, to, uint96(block.timestamp));
            _callHubAsBot(bot, trustCallData);
        }

        uint256 botId = uint256(uint160(bot));
        bytes memory transferCallData;
        if (forClaiming || numberOfInvites == 1) {
            transferCallData = abi.encodeWithSelector(
                IHub.safeTransferFrom.selector, bot, to, botId, numberOfInvites * INVITATION_FEE, data
            );
        } else {
            uint256[] memory ids = new uint256[](numberOfInvites);
            uint256[] memory values = new uint256[](numberOfInvites);
            for (uint256 i; i < numberOfInvites;) {
                ids[i] = botId;
                values[i] = INVITATION_FEE;
                unchecked {
                    ++i;
                }
            }
            transferCallData = abi.encodeWithSelector(IHub.safeBatchTransferFrom.selector, bot, to, ids, values, data);
        }
        _callHubAsBot(bot, transferCallData);
    }

    function _updateBotMetadataDigest(address bot, bytes32 metadataDigest) internal {
        bytes memory callData = abi.encodeWithSelector(INameRegistry.updateMetadataDigest.selector, metadataDigest);
        _callAsBot(bot, NAME_REGISTRY, callData);
    }

    function _callHubAsBot(address bot, bytes memory callData) internal {
        _callAsBot(bot, address(HUB), callData);
    }

    function _callAsBot(address bot, address target, bytes memory callData) internal {
        (bool success, bytes memory returnData) =
            InvitationBot(bot).execTransactionFromModuleReturnData(target, uint256(0), callData, uint8(0));
        if (!success) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}
