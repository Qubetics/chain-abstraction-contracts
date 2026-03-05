// // SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

    import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
    import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
    import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

interface ITreasuryVault {
    function batchTransfer(
        address[] memory recipients,
        uint256[] memory amounts
    ) external;
}   

interface ISolverManager {
    function solverRewardUpdation(
        uint256 sourceChainId,
        uint256 targetChainId,
        uint256 intentSourceAmount
    ) external;

    function platformFeeUpdation(
        uint256 sourceChainId,
        uint256 feeAmount
    ) external;

    function getSolverFeePercentage() external view returns (uint256);

    function getPlatformFeePercentage() external view returns (uint256);

}

contract IntentManager is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    uint32 public constant STRING_LIMIT = 500;

    // Role definitions
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant INTENT_OPERATOR_ROLE = keccak256("INTENT_OPERATOR_ROLE");

    // Enum to represent batch type
    enum BatchType {
        BTC,
        TICS
    }

    // Enum to represent phases of an intent
    enum IntentPhase {
        Refunded
    }

    // Struct to store intent details
    struct IntentDetails {
        string sourceAddress;
        string targetAddress;
        string sourceChain;
        string targetChain;
        uint128 sourceAmount;
        uint128 targetAmount;
        string sourceToken;
        string targetToken;
        string intentId;
        string withdrawTxHash;
        string depositTxHash;
    }

    // Struct for batch intent submission
    struct BatchIntentInput {
        string sourceAddress;
        string targetAddress;
        string sourceChain;
        string targetChain;
        uint128 sourceAmount;
        uint128 targetAmount;
        string sourceToken;
        string targetToken;
        string intentId;
        string withdrawTxHash;
        string depositTxHash;
    }

    // Mappings
    mapping(string => IntentDetails) public intents;

    // Array to store all intent IDs for enumeration
    string[] private intentIds;
    mapping(string => uint256) private intentIdToIndex;

    // Treasury Vault address
    address public treasuryVault;
    // Solver Address
    address public solverManager;
    bool public gmvReached;

    // Events
    event IntentInsight(
        string sourceAddress,
        string targetAddress,
        string sourceChain,
        string targetChain,
        uint128 sourceAmount,
        uint128 targetAmount,
        string sourceToken,
        string targetToken,
        string intentId,
        string withdrawTxHash,
        string depositTxHash
    );

    event BatchIntentsProcessed(
        uint256 batchSize,
        BatchType batchType,
        string timestamp
    );

    event TreasuryVaultUpdated(address indexed oldVault, address indexed newVault);

    // Custom errors
    error NoneValue();
    error ExceedsLimit();
    error IntentNotFound();
    error InvalidPhaseTransition();
    error IntentAlreadyExists();
    error ZeroAddress();
    error EmptyBatch();
    error InvalidBatchType();
    error TreasuryVaultNotSet();

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
     * @param _treasuryVault The address of the TreasuryVault contract
     */
    function initialize(address admin, address _treasuryVault) public initializer {
        if (admin == address(0)) revert ZeroAddress();
        if (_treasuryVault == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(INTENT_OPERATOR_ROLE, admin);

        treasuryVault = _treasuryVault;
    }

    /**
     * @notice Process batch intents
     * @param batchIntents Array of intent details to process
     * @param batchType Type of batch (BTC or TICS)
     * @param timestamp Timestamp of batch processing
     */
    function processBatchIntents(
        BatchIntentInput[] memory batchIntents,
        BatchType batchType,
        string memory timestamp
    )
        external
        nonReentrant
        onlyRole(INTENT_OPERATOR_ROLE)
    {
        if (batchIntents.length == 0) revert EmptyBatch();

        // Prepare arrays for TICS batch transfer
        address[] memory recipients;
        uint256[] memory amounts;

        if (batchType == BatchType.TICS) {
            if (treasuryVault == address(0)) revert TreasuryVaultNotSet();
            recipients = new address[](batchIntents.length);
            amounts = new uint256[](batchIntents.length);
        }

        for (uint256 i = 0; i < batchIntents.length; i++) {
            BatchIntentInput memory input = batchIntents[i];

            // Validate amount
            if (input.sourceAmount == 0) revert NoneValue();
            if (input.targetAmount == 0) revert NoneValue();


            // Ensure intent doesn't already exist
            if (_intentExists(intents[input.intentId])) revert IntentAlreadyExists();

            // Create intent details
            IntentDetails memory intentDetails = IntentDetails({
                sourceAddress: input.sourceAddress,
                targetAddress: input.targetAddress,
                sourceChain: input.sourceChain,
                targetChain: input.targetChain,
                sourceAmount: input.sourceAmount,
                targetAmount: input.targetAmount,
                sourceToken: input.sourceToken,
                targetToken: input.targetToken,
                intentId: input.intentId,
                withdrawTxHash: input.withdrawTxHash,
                depositTxHash: input.depositTxHash
            });

            // Store intent
            intents[input.intentId] = intentDetails;

            // Add to array
            intentIds.push(input.intentId);
            intentIdToIndex[input.intentId] = intentIds.length - 1;

            // Emit event for individual intent
            emit IntentInsight(
                input.sourceAddress,
                input.targetAddress,
                input.sourceChain,
                input.targetChain,
                input.sourceAmount,
                input.targetAmount,
                input.sourceToken,
                input.targetToken,
                input.intentId,
                input.withdrawTxHash,
                input.depositTxHash
            );

            uint256 sourceChainId = 0;
            uint256 targetChainId = 0;
            // Treat "TICS" and "tics" (and common variants) as TICS chain; default is BTC (0)
            if (_isTicsToken(input.sourceToken)) {
                sourceChainId = 9030;
            }
            if (_isTicsToken(input.targetToken)) {
                targetChainId = 9030;
            }

        uint256 solverFee = ISolverManager(solverManager)
        .getSolverFeePercentage();

        uint256 platformFee = ISolverManager(solverManager)
        .getPlatformFeePercentage();

        if (gmvReached) {
            ISolverManager(solverManager).solverRewardUpdation(
                sourceChainId,
                targetChainId,
                (input.sourceAmount * solverFee) / 10000
            );

            ISolverManager(solverManager).platformFeeUpdation(
                sourceChainId,
                (input.sourceAmount * platformFee) / 10000
            );
        } else {
            uint256 totalFee = solverFee + platformFee;

            ISolverManager(solverManager).solverRewardUpdation(
                sourceChainId,
                targetChainId,
                (input.sourceAmount * totalFee) / 10000
            );
        }

        // For TICS batch, prepare data for vault transfer
        if (batchType == BatchType.TICS) {
            // Parse target address string to address
            recipients[i] = _parseAddress(input.targetAddress);
            amounts[i] = uint256(input.targetAmount);
        }

        }

        // Execute batch transfer for TICS
        if (batchType == BatchType.TICS) {
            ITreasuryVault(treasuryVault).batchTransfer(recipients, amounts);
        }

        emit BatchIntentsProcessed(batchIntents.length, batchType, timestamp);
    }

    /**
     * @notice Update treasury vault address
     * @param _treasuryVault New treasury vault address
     */
    function setTreasuryVault(address _treasuryVault) external onlyRole(ADMIN_ROLE) {
        if (_treasuryVault == address(0)) revert ZeroAddress();
        address oldVault = treasuryVault;
        treasuryVault = _treasuryVault;
        emit TreasuryVaultUpdated(oldVault, _treasuryVault);
    }


    function setSolverManager(address _solverManager)
    external
    onlyRole(ADMIN_ROLE)
    {
        if (_solverManager == address(0)) revert ZeroAddress();
        solverManager = _solverManager;
    }

    function setGmvReached(bool _status)
    external
    onlyRole(ADMIN_ROLE)
    {
        gmvReached = _status;
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
        return intent.sourceAmount > 0 || bytes(intent.sourceAddress).length > 0;
    }

    /**
     * @notice Returns true if token is TICS (case-insensitive: "TICS", "tics", "Tics")
     *         So rewards and chain id use TICS (9030) even when intent was stored with lowercase "tics"
     */
    function _isTicsToken(string memory token) internal pure returns (bool) {
        bytes32 h = keccak256(bytes(token));
        return h == keccak256("TICS") || h == keccak256("tics") || h == keccak256("Tics");
    }

    /**
     * @notice Internal function to parse string address to address type
     * @param addressString String representation of address
     * @return Parsed address
     */
    function _parseAddress(string memory addressString)
        internal
        pure
        returns (address)
    {
        bytes memory stringBytes = bytes(addressString);
        require(stringBytes.length == 42, "Invalid address length");
        require(stringBytes[0] == '0' && stringBytes[1] == 'x', "Invalid address prefix");

        bytes memory addressBytes = new bytes(20);
        for (uint256 i = 0; i < 20; i++) {
            uint8 digit1 = _parseHexChar(stringBytes[2 + i * 2]);
            uint8 digit2 = _parseHexChar(stringBytes[3 + i * 2]);
            addressBytes[i] = bytes1(digit1 * 16 + digit2);
        }

        return address(uint160(bytes20(addressBytes)));
    }

    /**
     * @notice Internal function to parse hex character
     */
    function _parseHexChar(bytes1 char) internal pure returns (uint8) {
        uint8 c = uint8(char);
        if (c >= 48 && c <= 57) return c - 48; // 0-9
        if (c >= 65 && c <= 70) return c - 55; // A-F
        if (c >= 97 && c <= 102) return c - 87; // a-f
        revert("Invalid hex character");
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
