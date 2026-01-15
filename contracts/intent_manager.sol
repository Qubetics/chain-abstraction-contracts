// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract IntentManager is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    uint32 public constant STRING_LIMIT = 500;

    // Role definitions
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant MPC_ROLE = keccak256("MPC_ROLE");
    // Reserve storage slots for future upgrades
    uint256[47] private __gap;

    // Enum to represent phases of an intent
    enum IntentPhase {
        SentToVault,
        SentToDestination
    }

    // Enum to represent Tx status
    enum TransactionStatus {
        Pending,
        Failed,
        Confirmed
    }

    // Struct to store intent details
    struct IntentDetails {
        string sourceAddress;
        string targetAddress;
        string sourceChain;
        string targetChain;
        uint128 amount;
        string sourceToken;
        string targetToken;
        string intentId;
        IntentPhase phase;
    }

    // Mappings
    mapping(string => IntentDetails) public intents;
    mapping(string => TransactionStatus) public txStatusByHash;

    // Array to store all intent IDs for enumeration
    string[] private intentIds;
    mapping(string => uint256) private intentIdToIndex;

    // Events
    event IntentSubmitted(
        string sourceAddress,
        string targetAddress,
        string sourceChain,
        string targetChain,
        uint128 amount,
        string sourceToken,
        string targetToken,
        string intentId,
        string timestamp
    );

    event IntentSentToPool(
        string sourceAddress,
        string targetAddress,
        string sourceChain,
        string targetChain,
        uint128 amount,
        string sourceToken,
        string targetToken,
        string intentId,
        string transactionHash,
        IntentPhase phase,
        TransactionStatus txStatus
    );

    event IntentSentToDestination(
        string sourceAddress,
        string targetAddress,
        string sourceChain,
        string targetChain,
        uint128 amount,
        string sourceToken,
        string targetToken,
        string intentId,
        string transactionHash,
        IntentPhase phase,
        TransactionStatus txStatus,
        string timestamp
    );

    event TransactionStatusUpdated(string txHash, TransactionStatus status);
    event SolverAdded(address indexed solver);
    event SolverRemoved(address indexed solver);

    // Custom errors
    error NoneValue();
    error ExceedsLimit();
    error IntentNotFound();
    error InvalidPhaseTransition();
    error IntentAlreadyExists();
    error ZeroAddress();

    // Modifiers
    modifier validAmount(uint128 amount) {
        if (amount == 0) revert NoneValue();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract 
     * @param admin The address that will have admin and upgrader roles
     */
    function initialize(address admin) public initializer {
        if (admin == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(MPC_ROLE, admin);
    }

    /**
     * @notice Deposits an intent for a cross-chain transaction
     */
    function depositIntent(
        string memory sourceAddress,
        string memory targetAddress,
        string memory sourceChain,
        string memory targetChain,
        uint128 amount,
        string memory sourceToken,
        string memory targetToken,
        string memory transactionHash,
        string memory intentId,
        string memory timestamp
    )
        external
        whenNotPaused
        validAmount(amount)
        onlyRole(MPC_ROLE)
    {
        // ensure we are not overwriting an existing intent
        if (_intentExists(intents[intentId])) revert IntentAlreadyExists();

        IntentDetails memory intentDetails = IntentDetails({
            sourceAddress: sourceAddress,
            targetAddress: targetAddress,
            sourceChain: sourceChain,
            targetChain: targetChain,
            amount: amount,
            sourceToken: sourceToken,
            targetToken: targetToken,
            intentId: intentId,
            phase: IntentPhase.SentToVault
        });

        intents[intentId] = intentDetails;

        // Add to array
        intentIds.push(intentId);
        intentIdToIndex[intentId] = intentIds.length - 1;

        emit IntentSubmitted(
            sourceAddress,
            targetAddress,
            sourceChain,
            targetChain,
            amount,
            sourceToken,
            targetToken,
            intentId,
            timestamp
        );

        emit IntentSentToPool(
            sourceAddress,
            targetAddress,
            sourceChain,
            targetChain,
            amount,
            sourceToken,
            targetToken,
            intentId,
            transactionHash,
            IntentPhase.SentToVault,
            TransactionStatus.Pending
        );
    }

    constructor() {
     _disableInitializers();
    }

    /**
     * @notice Fulfill an intent
     */
    function fulfillIntent(
        string memory sourceAddress,
        string memory targetAddress,
        string memory sourceChain,
        string memory targetChain,
        uint128 amount,
        string memory sourceToken,
        string memory targetToken,
        string memory transactionHash,
        string memory intentId,
        string memory timestamp
    )
        external
        whenNotPaused
        validAmount(amount)
        onlyRole(MPC_ROLE)
    {
        if (!_intentExists(intents[intentId])) revert IntentNotFound();

        IntentDetails storage intent = intents[intentId];

        if (intent.phase != IntentPhase.SentToVault)
            revert InvalidPhaseTransition();

        intent.sourceAddress = sourceAddress;
        intent.targetAddress = targetAddress;
        intent.sourceChain = sourceChain;
        intent.targetChain = targetChain;
        intent.amount = amount;
        intent.sourceToken = sourceToken;
        intent.targetToken = targetToken;
        intent.phase = IntentPhase.SentToDestination;

        emit IntentSentToDestination(
            sourceAddress,
            targetAddress,
            sourceChain,
            targetChain,
            amount,
            sourceToken,
            targetToken,
            intentId,
            transactionHash,
            IntentPhase.SentToDestination,
            TransactionStatus.Confirmed,
            timestamp
        );
    }

    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Gets intent details for a specific intent
     */
    function getIntent(string memory intentId)
        external
        view
        returns (IntentDetails memory)
    {
        if (!_intentExists(intents[intentId])) revert IntentNotFound();
        return intents[intentId];
    }

    /**
     * @notice Gets all intent IDs
     */
    function getAllIntentIds() external view returns (string[] memory) {
        return intentIds;
    }

    /**
     * @notice Checks if an intent exists
     */
    function intentExists(string memory intentId)
        external
        view
        returns (bool)
    {
        return _intentExists(intents[intentId]);
    }

    /**
     * @notice Internal function to check if an intent exists
     */
    function _intentExists(IntentDetails storage intent)
        internal
        view
        returns (bool)
    {
        return intent.amount > 0 || bytes(intent.sourceAddress).length > 0;
    }

    /**
     * @notice Authorize contract upgrades (UUPS)
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    /**
     * @notice Returns the version of the contract
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}
