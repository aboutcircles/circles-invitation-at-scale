// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IHub} from "src/interfaces/IHub.sol";
import {INameRegistry} from "src/interfaces/INameRegistry.sol";
import {IInvitationModule} from "src/interfaces/IInvitationModule.sol";
import {InvitationBot} from "src/InvitationBot.sol";

/// @title InvitationFarm
/// @notice Manages a farm of InvitationBot instances, distributes/claims invite capacity, and grows the farm.
/// @dev
/// - Admin (multisig) configures roles/quotas and dependencies.
/// - Maintainer performs operational tasks (mint upkeep, metadata updates, growth).
/// - Seeder or an existing Bot may bootstrap more bots via the module’s generic-call proxy.
/// - Invites are allocated in units of `INVITATION_FEE` from bots round-robin.
contract InvitationFarm {
    /*//////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Caller is not the admin.
    error OnlyAdmin();

    /// @notice Caller is not the maintainer.
    error OnlyMaintainer();

    /// @notice Caller is neither the seeder nor a registered bot.
    error OnlySeederOrBot();

    /// @notice Requested invites exceed caller's remaining quota.
    error ExceedsInviteQuota();

    /// @notice No sufficient capacity across bots to fulfill the request.
    error FarmIsDrained();

    /// @notice Caller is not the configured GenericCallProxy.
    error OnlyGenericCallProxy();

    /// @notice Provided address is not a Circles human in the Hub.
    /// @param avatar The address that failed the human check.
    error OnlyHumanAvatarsAreInviters(address avatar);

    /*//////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the admin address is updated.
    /// @param newAdmin The new admin address.
    event AdminSet(address indexed newAdmin);

    /// @notice Emitted when the maintainer address is updated.
    /// @param maintainer The new maintainer address.
    event MaintainerSet(address indexed maintainer);

    /// @notice Emitted when the seeder address is updated.
    /// @param seeder The new seeder address.
    event SeederSet(address indexed seeder);

    /// @notice Emitted when an inviter's quota is set/updated.
    /// @param inviter The inviter address.
    /// @param quota The new remaining quota.
    event InviterQuotaUpdated(address indexed inviter, uint256 indexed quota);

    /// @notice Emitted when the Invitation Module (and its proxy) is updated.
    /// @param module The new module address.
    /// @param genericCallProxy The module’s GenericCallProxy address.
    event InvitationModuleUpdated(address indexed module, address indexed genericCallProxy);

    /// @notice Emitted after a new InvitationBot is created and added to the list.
    /// @param createdBot The address of the created bot.
    event BotCreated(address indexed createdBot);

    /// @notice Emitted after invites are successfully claimed.
    /// @param inviter The claimant.
    /// @param count Number of invites claimed.
    event InvitesClaimed(address indexed inviter, uint256 indexed count);

    /// @notice Emitted when the farm is grown via maintainer flow.
    /// @param maintainer The caller who initiated growth.
    /// @param numberOfBots Number of bots requested for growth.
    /// @param totalNumberOfBots Total bots after the operation (headcount at emit time).
    event FarmGrown(address indexed maintainer, uint256 indexed numberOfBots, uint256 indexed totalNumberOfBots);

    /*//////////////////////////////////////////////////////////////
                              Constants & Immutables
    //////////////////////////////////////////////////////////////*/

    /// @notice Circles v2 Hub.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    /// @notice Circles v2 Name Registry contract.
    address public constant NAME_REGISTRY = address(0xA27566fD89162cC3D40Cb59c87AAaA49B85F3474);

    /// @dev Sentinel node for the linked list of bots.
    address private constant SENTINEL = address(0x1);

    /// @notice Invite unit size (CRC) consumed per invite.
    uint256 public constant INVITATION_FEE = 96 ether;

    /*//////////////////////////////////////////////////////////////
                                Storage
    //////////////////////////////////////////////////////////////*/

    /// @notice Admin (governance) address.
    address public admin;

    /// @notice Invitation Module used by the farm.
    address public invitationModule;

    /// @dev Module’s GenericCallProxy allowed to call privileged init ops.
    address internal genericCallProxy;

    /// @notice Address allowed to bootstrap/seed via module.
    address public seeder;

    /// @notice Operational actor for upkeep/growth.
    address public maintainer;

    /// @notice Singly-linked list: bot => next bot (head at bots[SENTINEL]).
    mapping(address bot => address nextBot) public bots;

    /// @notice Total number of bots in the list.
    uint256 public totalBots;

    /// @notice Cursor for round-robin operations across bots.
    address public lastUsedBot;

    /// @notice Remaining invite quota per inviter address.
    mapping(address => uint256) public inviterQuota;

    /*//////////////////////////////////////////////////////////////
                                 Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts to Admin calls.
    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    /// @notice Restricts to Maintainer calls.
    modifier onlyMaintainer() {
        if (msg.sender != maintainer) revert OnlyMaintainer();
        _;
    }

    /// @notice Allows calls from the Seeder or any registered Bot (originating through the module).
    /// @dev Uses `_getOriginInviter()` from the module to derive the origin.
    modifier onlySeederOrBot() {
        address originInviter = _getOriginInviter();
        if (originInviter != seeder && bots[originInviter] == address(0)) revert OnlySeederOrBot();
        _;
    }

    /// @notice Restricts to the module’s GenericCallProxy.
    modifier onlyGenericCallProxy() {
        if (msg.sender != genericCallProxy) revert OnlyGenericCallProxy();
        _;
    }

    /// @notice Decrements caller’s invite quota and reverts if insufficient.
    /// @param numberOfInvites Number of invites requested.
    modifier withinInviteQuota(uint256 numberOfInvites) {
        uint256 remaining = inviterQuota[msg.sender];
        if (remaining == 0 || numberOfInvites > remaining) revert ExceedsInviteQuota();
        inviterQuota[msg.sender] -= numberOfInvites;
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               Constructor
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the farm with an Invitation Module and derives its GenericCallProxy.
    /// @param _invitationModule The module to use.
    constructor(address _invitationModule) {
        invitationModule = _invitationModule;
        genericCallProxy = IInvitationModule(_invitationModule).GENERIC_CALL_PROXY();
        admin = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                               Admin Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets a new admin.
    /// @param newAdmin The new admin address.
    function setAdmin(address newAdmin) external onlyAdmin {
        admin = newAdmin;
        emit AdminSet(newAdmin);
    }

    /// @notice Sets the seeder (must be a Hub-recognized human).
    /// @param newSeeder The new seeder address.
    function setSeeder(address newSeeder) external onlyAdmin {
        validateHuman(newSeeder);
        seeder = newSeeder;
        emit SeederSet(newSeeder);
    }

    /// @notice Sets the maintainer.
    /// @param newMaintainer The new maintainer address.
    function setMaintainer(address newMaintainer) external onlyAdmin {
        maintainer = newMaintainer;
        emit MaintainerSet(maintainer);
    }

    /// @notice Sets or updates an inviter’s quota (must be a Hub-recognized human).
    /// @param inviter The inviter address.
    /// @param quota The new remaining quota for this inviter.
    function setInviterQuota(address inviter, uint256 quota) external onlyAdmin {
        validateHuman(inviter);
        inviterQuota[inviter] = quota;
        emit InviterQuotaUpdated(inviter, quota);
    }

    /// @notice Updates the Invitation Module and refreshes the GenericCallProxy address.
    /// @param newInvitationModule The new module address.
    function updateInvitationModule(address newInvitationModule) external onlyAdmin {
        invitationModule = newInvitationModule;
        genericCallProxy = IInvitationModule(newInvitationModule).GENERIC_CALL_PROXY();
        emit InvitationModuleUpdated(newInvitationModule, genericCallProxy);
    }

    /*//////////////////////////////////////////////////////////////
                               Initialization
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates multiple bots via the module’s proxy and adds them to the list.
    /// @param numberOfBots Number of bots to create.
    /// @return createdBots Array of newly created bot addresses.
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

    /// @notice Creates a single bot via the module’s proxy and adds it to the list.
    /// @return createdBot Address of the newly created bot.
    function createBot() external onlyGenericCallProxy onlySeederOrBot returns (address createdBot) {
        createdBot = address(new InvitationBot());
        _addBot(createdBot);
        emit BotCreated(createdBot);
    }

    /*//////////////////////////////////////////////////////////////
                              Maintainer Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates metadata digest for a range of bots, walking forward from `startBot`.
    /// @dev Wraps through the sentinel if encountered. Caps `numberOfBots` to `totalBots`.
    /// @param startBot The bot to start from (inclusive).
    /// @param numberOfBots Number of bots to process.
    /// @param metadataDigest New metadata digest to set.
    /// @return The next bot after the processed range (cursor for subsequent calls).
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

    /// @notice Performs mint upkeep across bots up to `iterations`, starting from `lastUsedBot`.
    /// @param iterations Maximum number of bots to mint through in this call.
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

    /// @notice Grows the farm by allocating CRC from bots and triggering bot creation via the module.
    /// @param numberOfBots Number of bots to add.
    function growFarm(uint256 numberOfBots) external onlyMaintainer {
        _transferFromBots(numberOfBots, invitationModule, false);
        emit FarmGrown(msg.sender, numberOfBots, totalBots);
    }

    /*//////////////////////////////////////////////////////////////
                               Invite Claiming
    //////////////////////////////////////////////////////////////*/

    /// @notice Claims multiple invites for the caller, consuming their quota.
    /// @param numberOfInvites Number of invites to claim.
    /// @return ids Array of bot IDs (as uint256) that supplied the invites.
    function claimInvites(uint256 numberOfInvites)
        public
        withinInviteQuota(numberOfInvites)
        returns (uint256[] memory ids)
    {
        ids = _transferFromBots(numberOfInvites, msg.sender, true);
        emit InvitesClaimed(msg.sender, ids.length);
    }

    /// @notice Claims a single invite for the caller, consuming their quota by 1.
    /// @return id The bot ID (as uint256) that supplied the invite.
    function claimInvite() external returns (uint256 id) {
        uint256[] memory ids = claimInvites(1);
        id = ids[0];
    }

    /*//////////////////////////////////////////////////////////////
                               Allocation Core
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal allocator that walks bots round-robin and transfers CRC for invites or growth.
    /// @dev
    /// - In claim mode (`forClaiming = true`), trusts `receiver` and transfers CRC to them.
    /// - In growth mode, transfers CRC to the module with encoded callback to create bots.
    /// - Updates `lastUsedBot` cursor. Reverts {FarmIsDrained} if capacity is exhausted.
    /// @param numberOfInvites Number of invite units (INVITATION_FEE each) to allocate.
    /// @param receiver Address receiving CRC (caller in claim mode; module in growth mode).
    /// @param forClaiming If true, performs trust+transfer to receiver; else transfers to module with callback.
    /// @return ids The list of bot IDs (uint256) used for allocation, in traversal order.
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

    /*//////////////////////////////////////////////////////////////
                                 Internal
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts if `avatar` is not a human in the Circles Hub.
    /// @param avatar Address to validate.
    function validateHuman(address avatar) internal view {
        if (!HUB.isHuman(avatar)) revert OnlyHumanAvatarsAreInviters(avatar);
    }

    /// @notice Resolves the origin inviter from the Invitation Module.
    /// @return The origin inviter address.
    function _getOriginInviter() internal view returns (address) {
        return IInvitationModule(invitationModule).getOriginInviter();
    }

    /// @notice Adds a bot to the linked list and updates head/cursor.
    /// @param bot Bot address to add.
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

    /*//////////////////////////////////////////////////////////////
                              Bot Interactions
    //////////////////////////////////////////////////////////////*/

    /// @notice Triggers Hub `personalMint` as the given bot.
    /// @param bot The bot to mint for.
    function _mintAsBot(address bot) internal {
        bytes memory callData = abi.encodeWithSelector(IHub.personalMint.selector);
        _callHubAsBot(bot, callData);
    }

    /// @notice Mints then reads the bot's CRC balance for its own token ID.
    /// @param bot The bot whose balance to read.
    /// @return balance The current CRC balance for `uint256(uint160(bot))`.
    function _refreshAndGetBotBalance(address bot) internal returns (uint256 balance) {
        _mintAsBot(bot);
        balance = HUB.balanceOf(bot, uint256(uint160(bot)));
    }

    /// @notice Transfers invite units from a bot to `to`, optionally trusting `to` first.
    /// @dev Uses single or batch transfer depending on `numberOfInvites`. Calls module callback in growth mode.
    /// @param bot The source bot.
    /// @param forClaiming If true, trust `to` and transfer CRC to them; else transfer to module with callback.
    /// @param to Receiver address (inviter or module).
    /// @param numberOfInvites Number of invite units to transfer.
    /// @param data Additional data forwarded to Hub transfer (and used for module callback in growth mode).
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

    /// @notice Updates metadata digest in the Name Registry as the given bot.
    /// @param bot The bot to act as.
    /// @param metadataDigest The new metadata digest to set.
    function _updateBotMetadataDigest(address bot, bytes32 metadataDigest) internal {
        bytes memory callData = abi.encodeWithSelector(INameRegistry.updateMetadataDigest.selector, metadataDigest);
        _callAsBot(bot, NAME_REGISTRY, callData);
    }

    /// @notice Helper to call the Hub as a bot.
    /// @param bot The bot to act as.
    /// @param callData Encoded call for the Hub.
    function _callHubAsBot(address bot, bytes memory callData) internal {
        _callAsBot(bot, address(HUB), callData);
    }

    /// @notice Low-level helper to execute a call from a bot via its module interface.
    /// @param bot The bot to act as.
    /// @param target The target contract to call.
    /// @param callData ABI-encoded call data for the target.
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
