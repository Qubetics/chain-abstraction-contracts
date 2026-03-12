// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";

interface ITreasuryVault {
    function batchTransfer(
        address[] memory recipients,
        uint256[] memory amounts
    ) external;
}

contract SolverManager is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    EIP712Upgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MPC_ROLE = keccak256("MPC_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant INTENT_MANAGER_ROLE =
        keccak256("INTENT_MANAGER_ROLE");

    // Required chains for solver activation
    uint256 public constant REQUIRED_CHAIN_BTC = 0;
    uint256 public constant REQUIRED_CHAIN_TICS = 9030;

    // EIP-712 Type Hash for Solver Onboarding
    bytes32 public constant ONBOARD_SOLVER_TYPEHASH =
        keccak256(
            "OnboardSolver(string solverId,string solverName,uint256[] chainIds,string[] solverAddresses,uint256 nonce,uint256 deadline)"
        );

    bytes32 public constant VALIDATE_SOLVER_TYPEHASH =
        keccak256(
            "ValidateSolver(string solverId,uint256 nonce,uint256 deadline)"
        );

    enum ChainType {
        BTC,
        TICS
    }

    struct Solver {
        string solverId;
        string solverName;
        uint256[] chainIds;
        string[] solverAddresses;
        bool isActive;
        bool isOnboarded;
        uint256 onboardedAt;
        uint256 offboardedAt;
    }

    struct LiquidityDeposit {
        uint256 amount;
        uint256 chainId;
        uint256 timestamp;
        bool isDeposit;
    }

    struct RemoveLiquidity {
        string solverId;
        uint256 amount;
        ChainType chainType;
        string transactionHash;
    }

    struct RewardClaim {
        address solver;
        uint256 amount;
        ChainType chainType;
    }

    struct AddLiquidityBatch {
        string solverId;
        uint256 amount;
        ChainType chainType;
        string txId;
    }

    struct SolverUnclaimedRewards {
        string solverId;
        uint256 btcUnclaimed;
        uint256 ticsUnclaimed;
    }

    // Storage variables
    mapping(string => Solver) private solvers;
    mapping(string => bool) private solverExists;
    mapping(address => bool) private solverOnboarded;
    mapping(string => string) private addressToSolverId;
    mapping(string => uint256) private solverTotalAmounts;
    mapping(string => mapping(uint256 => uint256)) private solverChainAmounts;
    mapping(string => bool) private authorizedAddresses;
    mapping(string => address) private solverEvmAddress;
    mapping(address => string) private solverAccount;
    // Counter for auto-generated solver IDs
    uint256 private solverIdCounter;
    // Mapping to track if solver address has validated their ID
    mapping(address => bool) private solverIdValidated;
    // solverId => chainId => claimed reward amount
    mapping(string => mapping(uint256 => uint256)) private solverClaimedRewards;
    mapping(string => mapping(uint256 => uint256)) private solverRewards;

    // Reward percentage constants
    uint256 public constant PERCENTAGE_DIVISOR = 100;
    uint256 public solverFeePercentage;

    // Minimum liquidity thresholds for required chains (stored but not enforced yet)
    uint256 private minLiquidityBTC;
    uint256 private minLiquidityTICS;

    string[] private activeSolverIds;
    uint256 private totalActiveSolvers;
    // Treasury Vault address
    address public treasuryVault;
    address public validatorAddress;

    // Separate nonces per operation (onboard vs validate) to avoid shared nonce race conditions
    mapping(address => uint256) private onboardNonces;
    mapping(address => uint256) private validateNonces;

    uint256 public platformFeePercentage;
    // chainId => accrued platform fee
    mapping(uint256 => uint256) private platformFeeAccrued;
    // chainId => claimed platform fee
    mapping(uint256 => uint256) private platformFeeClaimed;

    // Reserve storage slots for future upgrades
    uint256[35] private __gap;

    event SolverActivated(string solverId, uint256 timestamp);

    event SolverRewardClaimed(
        address indexed solver,
        string solverId,
        uint256 chainId,
        uint256 amount,
        uint256 timestamp
    );

    event SolverDeactivated(string solverId, string reason, uint256 timestamp);

    event LiquidityAdded(
        string solverId,
        uint256 chainId,
        uint256 amount,
        uint256 timestamp,
        string txId
    );

    event LiquidityRemoved(
        string solverId,
        uint256 chainId,
        uint256 amount,
        uint256 timestamp,
        string transactionHash
    );

    event SolverFeeUpdated(uint256 oldFee, uint256 newFee, uint256 timestamp);

    event ContractUpgraded(
        address indexed newImplementation,
        uint256 timestamp
    );

    event MinimumLiquidityUpdated(
        uint256 chainId,
        uint256 oldMinimum,
        uint256 newMinimum,
        uint256 timestamp
    );

    event SolverIdInvalidated(
        string solverId,
        address solverAddress,
        uint256 timestamp
    );

    event PlatformFeeAccrued(
        uint256 chainId,
        uint256 amount,
        uint256 timestamp
    );

    event PlatformFeeClaimed(
        address indexed recipient,
        uint256 chainId,
        uint256 amount,
        uint256 timestamp
    );

    event PlatformFeePercentageUpdated(
        uint256 oldFee,
        uint256 newFee,
        uint256 timestamp
    );

    // Custom errors
    error SolverAlreadyExists(string solverId);
    error SolverNotFound(string solverId);
    error SolverNotActive(string solverId);
    error SolverNotOnboarded(string solverId);
    error InvalidSolverAddress();
    error InsufficientBalance();
    error UnauthorizedSolver();
    error InvalidAmount();
    error EmptyString();
    error EmptyAddressList();
    error EmptyChainIdsList();
    error EmptyAmountsList();
    error ArrayLengthMismatch();
    error AddressAlreadyAssigned(string addr);
    error UnauthorizedCaller();
    error InvalidSignature();
    error SignatureExpired();
    error InvalidNonce();
    error SolverIdAlreadyValidated();
    error SolverIdNotMatching();
    error NoLiquidityOnTargetChain();
    error SolverNotValidated(string solverId);
    error InsufficientRewards(
        string solverId,
        uint256 chainId,
        uint256 requested,
        uint256 available
    );
    error InsufficientPlatformFee(
        uint256 chainId,
        uint256 requested,
        uint256 available
    );
    error ZeroAddress();

    /**
     * @dev Initializer function (replaces constructor for upgradeable contracts)
     */
    function initialize(
        address _admin,
        address _treasuryVault,
        address _validator,
        address _intentmanager
    ) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __EIP712_init("SolverManager", "1");
        require(validatorAddress != address(0), "Validator address cannot be zero");
        require(_intentmanager != address(0), "Intent manager address cannot be zero");
        require(_treasuryVault != address(0), "Treasury vault address cannot be zero");
        require(_admin != address(0), "Admin address cannot be zero");

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(MPC_ROLE, _admin);
        _grantRole(INTENT_MANAGER_ROLE, _intentmanager);

        // Initialize minimum liquidity thresholds with defaults (can be updated by admin)
        minLiquidityBTC = 600; // 600 satoshis (BTC smallest unit)
        minLiquidityTICS = 10 * 10 ** 18; // 10 TICS in wei (18 decimals)

        // Initialize solver ID counter
        solverIdCounter = 1;
        treasuryVault = _treasuryVault;
        validatorAddress = _validator;
    }

    /**
     * @dev Required by UUPSUpgradeable - only UPGRADER_ROLE can authorize upgrades
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {
        emit ContractUpgraded(newImplementation, block.timestamp);
    }

    // Modifiers
    modifier onlyOnboardedSolver(string memory solverId) {
        if (!solverExists[solverId]) revert SolverNotFound(solverId);
        if (!solvers[solverId].isOnboarded) revert SolverNotOnboarded(solverId);
        _;
    }

    modifier onlyActiveSolver(string memory solverId) {
        if (!solverExists[solverId]) revert SolverNotFound(solverId);
        if (!solvers[solverId].isActive) revert SolverNotActive(solverId);
        _;
    }

    modifier onlyAuthorizedAddress(string memory solverAddress) {
        if (!authorizedAddresses[solverAddress]) revert UnauthorizedCaller();
        _;
    }

    /**
     * @dev Check if solver meets required chain liquidity conditions
     * NOTE: Currently checks for > 0, NOT against minimum thresholds
     * @param solverId Solver's unique identifier
     * @return bool True if solver has liquidity on all required chains
     */
    function _meetsRequiredChainLiquidity(
        string memory solverId
    ) internal view returns (bool) {
        // Check if solver has minimum required liquidity on BTC (chainId = 0)
        if (
            solverChainAmounts[solverId][REQUIRED_CHAIN_BTC] < minLiquidityBTC
        ) {
            return false;
        }

        // Check if solver has minimum required liquidity on TICS (chainId = 9030)
        if (
            solverChainAmounts[solverId][REQUIRED_CHAIN_TICS] < minLiquidityTICS
        ) {
            return false;
        }

        return true;
    }

    /**
     * @dev Activate solver if requirements are met
     * @param solverId Solver's unique identifier
     */
    function _activateSolverIfEligible(string memory solverId) internal {
        // Only activate if currently inactive and meets requirements
        if (
            !solvers[solverId].isActive &&
            _meetsRequiredChainLiquidity(solverId)
        ) {
            solvers[solverId].isActive = true;
            activeSolverIds.push(solverId);
            totalActiveSolvers++;
            emit SolverActivated(solverId, block.timestamp);
        }
    }

    /**
     * @dev Deactivate solver if required chain liquidity drops to zero
     * @param solverId Solver's unique identifier
     * @param reason Reason for deactivation
     */
    function _deactivateSolverIfNeeded(
        string memory solverId,
        string memory reason
    ) internal {
        // Only deactivate if currently active and doesn't meet requirements
        if (
            solvers[solverId].isActive &&
            !_meetsRequiredChainLiquidity(solverId)
        ) {
            solvers[solverId].isActive = false;
            _removeFromActiveSolvers(solverId);
            totalActiveSolvers--;
            emit SolverDeactivated(solverId, reason, block.timestamp);
        }
    }

    function _removeFromActiveSolvers(string memory solverId) internal {
        for (uint256 i = 0; i < activeSolverIds.length; i++) {
            if (
                keccak256(abi.encodePacked(activeSolverIds[i])) ==
                keccak256(abi.encodePacked(solverId))
            ) {
                activeSolverIds[i] = activeSolverIds[
                    activeSolverIds.length - 1
                ];
                activeSolverIds.pop();
                break;
            }
        }
    }

    /**
     * @dev Hash array of strings for EIP-712
     */
    function _hashStringArray(
        string[] memory arr
    ) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            hashes[i] = keccak256(bytes(arr[i]));
        }
        return keccak256(abi.encodePacked(hashes));
    }

    /**
     * @dev Hash array of uint256 for EIP-712
     */
    function _hashUint256Array(
        uint256[] memory arr
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(arr));
    }

    /**
     * @dev Verify EIP-712 signature for solver onboarding
     */
    function _verifyOnboardSignature(
        address signer,
        string memory solverId,
        string memory solverName,
        uint256[] memory chainIds,
        string[] memory solverAddresses,
        uint256 nonce,
        uint256 deadline,
        bytes memory signature
    ) internal view returns (bool) {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (nonce != onboardNonces[signer]) revert InvalidNonce();

        bytes32 structHash = keccak256(
            abi.encode(
                ONBOARD_SOLVER_TYPEHASH,
                keccak256(bytes(solverId)),
                keccak256(bytes(solverName)),
                _hashUint256Array(chainIds),
                _hashStringArray(solverAddresses),
                nonce,
                deadline
            )
        );

        bytes32 hash = _hashTypedDataV4(structHash);
        address recoveredSigner = _recoverSigner(hash, signature);

        return recoveredSigner == signer;
    }

    function _verifyValidateSolverSignature(
        address signer,
        string memory solverId,
        uint256 nonce,
        uint256 deadline,
        bytes memory signature
    ) internal view returns (bool) {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (nonce != validateNonces[signer]) revert InvalidNonce();

        bytes32 structHash = keccak256(
            abi.encode(
                VALIDATE_SOLVER_TYPEHASH,
                keccak256(bytes(solverId)),
                nonce,
                deadline
            )
        );

        bytes32 digest = _hashTypedDataV4(structHash);
        address recoveredSigner = _recoverSigner(digest, signature);

        return recoveredSigner == signer;
    }

    /**
     * @dev Recover signer from signature
     */
    function _recoverSigner(
        bytes32 hash,
        bytes memory signature
    ) internal pure returns (address) {
        require(signature.length == 65, "Invalid signature length");

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }

        if (v < 27) {
            v += 27;
        }

        require(v == 27 || v == 28, "Invalid signature 'v' value");

        return ecrecover(hash, v, r, s);
    }

    /**
     * @dev Onboard a new solver with EIP-712 signature verification
     * @param solverId Unique identifier for the solver (will be set to empty string/null internally)
     * @param solverName Name of the solver
     * @param chainIds Array of chain IDs where solver operates
     * @param solverAddresses Array of string addresses belonging to the solver
     * @param deadline Signature expiration timestamp
     * @param signature EIP-712 signature
     */
    //same account no more than one  solver onboared
    function onboardSolver(
        string memory solverId,
        string memory solverName,
        uint256[] memory chainIds,
        string[] memory solverAddresses,
        uint256 deadline,
        bytes memory signature
    ) external {
        if (chainIds.length == 0) revert EmptyChainIdsList();
        if (solverAddresses.length == 0) revert EmptyAddressList();
        require(
            !solverOnboarded[msg.sender],
            "solver with this evm address already onboarded"
        );
        if (solverExists[solverId]) revert SolverAlreadyExists(solverId);

        // Verify EIP-712 signature
        bool isValidSignature = _verifyOnboardSignature(
            validatorAddress,
            solverId,
            solverName,
            chainIds,
            solverAddresses,
            onboardNonces[validatorAddress],
            deadline,
            signature
        );

        if (!isValidSignature) revert InvalidSignature();

        // Increment nonce for replay protection
        onboardNonces[validatorAddress]++;

        solverEvmAddress[solverId] = msg.sender;

        // Validate addresses
        for (uint256 i = 0; i < solverAddresses.length; i++) {
            if (bytes(solverAddresses[i]).length == 0)
                revert InvalidSolverAddress();
            if (bytes(addressToSolverId[solverAddresses[i]]).length != 0) {
                revert AddressAlreadyAssigned(solverAddresses[i]);
            }
        }

        // Create solver struct - STARTS AS INACTIVE BUT ONBOARDED
        solvers[solverId] = Solver({
            solverId: solverId,
            solverName: solverName,
            chainIds: chainIds,
            solverAddresses: solverAddresses,
            isActive: false, // Solver starts as INACTIVE
            isOnboarded: true, // But is ONBOARDED
            onboardedAt: block.timestamp,
            offboardedAt: 0
        });

        // Update mappings for all addresses
        for (uint256 i = 0; i < solverAddresses.length; i++) {
            addressToSolverId[solverAddresses[i]] = solverId;
            authorizedAddresses[solverAddresses[i]] = true;
        }

        // Update state
        solverExists[solverId] = true;
        solverAccount[msg.sender] = solverId;
        solverOnboarded[msg.sender] = true;
    }

    function validateSolverId(
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (solverIdValidated[msg.sender]) revert SolverIdAlreadyValidated();

        string memory solverId = solverAccount[msg.sender];
        require(
            bytes(solverId).length != bytes("").length,
            "solver has onboarded without running the node"
        );
        if (bytes(solverId).length == 0) revert UnauthorizedSolver();

        bool valid = _verifyValidateSolverSignature(
            validatorAddress,
            solverId,
            validateNonces[validatorAddress],
            deadline,
            signature
        );

        if (!valid) revert InvalidSignature();

        validateNonces[validatorAddress]++; // replay protection
        solverIdValidated[msg.sender] = true;
    }

    function invalidateSolverIds(
        string[] calldata solverIds
    ) external onlyRole(MPC_ROLE) {
        if (solverIds.length == 0) revert EmptyChainIdsList();

        for (uint256 i = 0; i < solverIds.length; i++) {
            string memory solverId = solverIds[i];

            if (!solverExists[solverId]) revert SolverNotFound(solverId);

            address solverAddr = solverEvmAddress[solverId];
            if (solverAddr == address(0)) revert UnauthorizedSolver();

            if (!solverIdValidated[solverAddr]) {
                revert SolverNotValidated(solverId);
            }

            solverIdValidated[solverAddr] = false;

            emit SolverIdInvalidated(solverId, solverAddr, block.timestamp);
        }
    }

    /**
     * @dev Add liquidity to the pool.
     *      Amount units: BTC (chainType 0) = satoshis; TICS (chainType 1) = wei (18 decimals).
     */
    function addLiquidityBatch(
        AddLiquidityBatch[] calldata deposits
    ) external onlyRole(MPC_ROLE) {
        if (deposits.length == 0) revert EmptyAmountsList();

        for (uint256 i = 0; i < deposits.length; i++) {
            AddLiquidityBatch calldata dep = deposits[i];

            string memory solverId = dep.solverId;
            uint256 amount = dep.amount;
            ChainType chainType = dep.chainType;
            string memory txId = dep.txId;

            if (amount == 0) revert InvalidAmount();
            if (!solverExists[solverId]) revert SolverNotFound(solverId);
            if (!solvers[solverId].isOnboarded)
                revert SolverNotOnboarded(solverId);

            uint256 chainId = (chainType == ChainType.BTC)
                ? REQUIRED_CHAIN_BTC
                : REQUIRED_CHAIN_TICS;

            // Accounting update
            solverChainAmounts[solverId][chainId] += amount;
            solverTotalAmounts[solverId] += amount;

            emit LiquidityAdded(
                solverId,
                chainId,
                amount,
                block.timestamp,
                txId
            );

            // Activate solver if now eligible
            _activateSolverIfEligible(solverId);
        }
    }

    function removeLiquidity(
        RemoveLiquidity[] calldata requests
    ) external onlyRole(MPC_ROLE) {
        if (requests.length == 0) revert EmptyAmountsList();

        // Max possible size = requests.length (upper bound)
        address[] memory recipients = new address[](requests.length);
        uint256[] memory amounts = new uint256[](requests.length);
        uint256 ticsCount = 0;

        for (uint256 i = 0; i < requests.length; i++) {
            RemoveLiquidity calldata req = requests[i];

            string memory solverId = req.solverId;
            uint256 amount = req.amount;
            ChainType chainType = req.chainType;

            if (amount == 0) revert InvalidAmount();
            if (!solverExists[solverId]) revert SolverNotFound(solverId);
            if (!solvers[solverId].isOnboarded)
                revert SolverNotOnboarded(solverId);

            uint256 chainId = (chainType == ChainType.BTC)
                ? REQUIRED_CHAIN_BTC
                : REQUIRED_CHAIN_TICS;

            uint256 currentBalance = solverChainAmounts[solverId][chainId];
            if (currentBalance < amount) revert InsufficientBalance();

            // Accounting update
            solverChainAmounts[solverId][chainId] = currentBalance - amount;
            solverTotalAmounts[solverId] -= amount;

            emit LiquidityRemoved(
                solverId,
                chainId,
                amount,
                block.timestamp,
                req.transactionHash
            );

            // Collect TICS transfers only
            if (chainType == ChainType.TICS) {
                recipients[ticsCount] = solverEvmAddress[solverId];
                amounts[ticsCount] = amount;
                ticsCount++;
            }

            // Deactivate solver if needed
            _deactivateSolverIfNeeded(
                solverId,
                "Required chain liquidity below minimum"
            );
        }

        // Execute batch transfer only for TICS
        if (ticsCount > 0) {
            address[] memory finalRecipients = new address[](ticsCount);
            uint256[] memory finalAmounts = new uint256[](ticsCount);

            for (uint256 i = 0; i < ticsCount; i++) {
                finalRecipients[i] = recipients[i];
                finalAmounts[i] = amounts[i];
            }

            ITreasuryVault(treasuryVault).batchTransfer(
                finalRecipients,
                finalAmounts
            );
        }
    }

    /**
     * @dev Calculate solvers reward based on liquidity and validation status.
     *      Decimals: no conversion. Amounts must be in smallest unit per chain.
     *      - BTC (chain 0): intentSourceAmount and liquidity in satoshis.
     *      - TICS (chain 9030): intentSourceAmount and liquidity in wei (18 decimals).
     * @param sourceChainId Source chain ID (0 = BTC, 9030 = TICS)
     * @param targetChainId Target chain ID (0 = BTC, 9030 = TICS)
     * @param intentSourceAmount Total reward to distribute (same unit as source chain: satoshis for BTC, wei for TICS)
     */
    function solverRewardUpdation(
        uint256 sourceChainId,
        uint256 targetChainId,
        uint256 intentSourceAmount
    ) external onlyRole(INTENT_MANAGER_ROLE) {
        if (intentSourceAmount == 0) revert InvalidAmount();

        uint256 totalLiquidity = 0;
        uint256 totalValidatedLiquidity = 0;

        // Calculate total liquidity and total validated liquidity
        for (uint256 i = 0; i < activeSolverIds.length; i++) {
            string memory solverId = activeSolverIds[i];

            if (!solvers[solverId].isActive) continue;

            uint256 liquidity = solverChainAmounts[solverId][targetChainId];
            if (liquidity == 0) continue;

            totalLiquidity += liquidity;

            address solverAddr = solverEvmAddress[solverId];
            if (solverIdValidated[solverAddr]) {
                totalValidatedLiquidity += liquidity;
            }
        }

        if (totalLiquidity == 0) return;

        uint256 basePool = (intentSourceAmount * 75) / PERCENTAGE_DIVISOR;
        uint256 bonusPool = (intentSourceAmount * 25) / PERCENTAGE_DIVISOR;

        for (uint256 i = 0; i < activeSolverIds.length; i++) {
            string memory solverId = activeSolverIds[i];

            if (!solvers[solverId].isActive) continue;

            uint256 liquidity = solverChainAmounts[solverId][targetChainId];
            if (liquidity == 0) continue;

            address solverAddr = solverEvmAddress[solverId];

            uint256 reward = 0;

            // 75% distributed to all active solvers
            reward += (liquidity * basePool * 100) / totalLiquidity;

            // 25% distributed only to validated solvers
            if (solverIdValidated[solverAddr] && totalValidatedLiquidity > 0) {
                reward +=
                    (liquidity * bonusPool * 100) /
                    totalValidatedLiquidity;
            }

            solverRewards[solverId][sourceChainId] += reward;
        }
    }

    /**
     * @dev Accrue platform fee from intent processing.
     *      Called by IntentManager alongside solverRewardUpdation.
     *      Decimals: no conversion. Amounts must be in smallest unit per chain.
     *      - BTC : feeAmount in satoshis.
     *      - TICS : feeAmount in wei (18 decimals).
     * @param sourceChainId Source chain ID (0 = BTC, 9030 = TICS)
     * @param feeAmount Fee amount to accrue (same unit as source chain)
     */
    function platformFeeUpdation(
        uint256 sourceChainId,
        uint256 feeAmount
    ) external onlyRole(INTENT_MANAGER_ROLE) {
        if (feeAmount == 0) revert InvalidAmount();

        platformFeeAccrued[sourceChainId] += feeAmount;

        emit PlatformFeeAccrued(sourceChainId, feeAmount, block.timestamp);
    }

    /**
     * @dev Claim accrued platform fee.
     *      Follows same pattern as claimRewardsBatch — accrued vs claimed check,
     *      vault batchTransfer for TICS.
     *      For BTC: only updates accounting — MPC nodes read the amount and send BTC separately.
     * @param amount Amount to claim (wei for TICS, satoshis for BTC)
     * @param chainType Chain type (BTC or TICS)
     * @param recipient Address to receive the TICS
     */
    function claimPlatformFee(
        uint256 amount,
        ChainType chainType,
        address recipient
    ) external onlyRole(MPC_ROLE) {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 chainId = (chainType == ChainType.BTC)
            ? REQUIRED_CHAIN_BTC
            : REQUIRED_CHAIN_TICS;

        // Validate available fee before claiming
        uint256 accrued = platformFeeAccrued[chainId];
        uint256 claimed = platformFeeClaimed[chainId];
        uint256 available = accrued > claimed ? accrued - claimed : 0;

        // Reject if trying to claim more than available
        if (amount > available) {
            revert InsufficientPlatformFee(chainId, amount, available);
        }

        // Update claimed fee accounting
        platformFeeClaimed[chainId] += amount;

        // Transfer TICS from vault to recipient
        if (chainType == ChainType.TICS) {
            address[] memory recipients = new address[](1);
            uint256[] memory amounts = new uint256[](1);
            recipients[0] = recipient;
            amounts[0] = amount;

            ITreasuryVault(treasuryVault).batchTransfer(recipients, amounts);
        }
        // For BTC: no transfer here — MPC nodes will read getPlatformUnclaimedFee(0)
        // and send BTC to the recipient separately

        emit PlatformFeeClaimed(recipient, chainId, amount, block.timestamp);
    }

    function claimRewardsBatch(
        RewardClaim[] calldata claims
    ) external onlyRole(MPC_ROLE) {
        if (claims.length == 0) revert EmptyAmountsList();

        address[] memory recipients = new address[](claims.length);
        uint256[] memory amounts = new uint256[](claims.length);
        uint256 ticsCount = 0;

        for (uint256 i = 0; i < claims.length; i++) {
            RewardClaim calldata claim = claims[i];

            address solverAddr = claim.solver;
            uint256 amount = claim.amount;
            ChainType chainType = claim.chainType;

            if (amount == 0) revert InvalidAmount();

            string memory solverId = solverAccount[solverAddr];
            if (bytes(solverId).length == 0) revert SolverNotFound("");

            uint256 chainId = (chainType == ChainType.BTC)
                ? REQUIRED_CHAIN_BTC
                : REQUIRED_CHAIN_TICS;

            // Validate available rewards before claiming
            uint256 accruedRewards = solverRewards[solverId][chainId];
            uint256 alreadyClaimed = solverClaimedRewards[solverId][chainId];
            uint256 availableRewards = accruedRewards > alreadyClaimed
                ? accruedRewards - alreadyClaimed
                : 0;

            // Reject if trying to claim more than available
            if (amount > availableRewards) {
                revert InsufficientRewards(
                    solverId,
                    chainId,
                    amount,
                    availableRewards
                );
            }

            // Update claimed rewards accounting
            solverClaimedRewards[solverId][chainId] += amount;
            emit SolverRewardClaimed(
                solverAddr,
                solverId,
                chainId,
                amount,
                block.timestamp
            );

            // Collect TICS transfers only
            if (chainType == ChainType.TICS) {
                recipients[ticsCount] = solverAddr;
                amounts[ticsCount] = amount;
                ticsCount++;
            }
        }

        // Execute vault transfer only for TICS
        if (ticsCount > 0) {
            address[] memory finalRecipients = new address[](ticsCount);
            uint256[] memory finalAmounts = new uint256[](ticsCount);

            for (uint256 i = 0; i < ticsCount; i++) {
                finalRecipients[i] = recipients[i];
                finalAmounts[i] = amounts[i];
            }

            ITreasuryVault(treasuryVault).batchTransfer(
                finalRecipients,
                finalAmounts
            );
        }
    }

    function changeValidatorAddress(
        address _validatorAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        validatorAddress = _validatorAddress;
    }

    function setMinimumLiquidityBTC(
        uint256 newMinimum
    ) external onlyRole(ADMIN_ROLE) {
        uint256 oldMinimum = minLiquidityBTC;
        minLiquidityBTC = newMinimum;
        emit MinimumLiquidityUpdated(
            REQUIRED_CHAIN_BTC,
            oldMinimum,
            newMinimum,
            block.timestamp
        );
    }

    function setMinimumLiquidityTICS(
        uint256 newMinimum
    ) external onlyRole(ADMIN_ROLE) {
        uint256 oldMinimum = minLiquidityTICS;
        minLiquidityTICS = newMinimum;
        emit MinimumLiquidityUpdated(
            REQUIRED_CHAIN_TICS,
            oldMinimum,
            newMinimum,
            block.timestamp
        );
    }

    /**
     * @param newFee Fee in basis points (bps). 10000 = 100%, 100 = 1%, 50 = 0.5%.
     *              Used as (sourceAmount * newFee) / 10000 for solver reward.
     */
    function setSolverFeePercentage(
        uint256 newFee
    ) external onlyRole(ADMIN_ROLE) {
        uint256 oldFee = solverFeePercentage;
        solverFeePercentage = newFee;

        emit SolverFeeUpdated(oldFee, newFee, block.timestamp);
    }

    /**
     * @param newFee Fee in basis points (bps). 10000 = 100%, 100 = 1%, 250 = 2.5%.
     *              Used as (sourceAmount * newFee) / 10000 for platform fee.
     */
    function setPlatformFeePercentage(
        uint256 newFee
    ) external onlyRole(ADMIN_ROLE) {
        uint256 oldFee = platformFeePercentage;
        platformFeePercentage = newFee;

        emit PlatformFeePercentageUpdated(oldFee, newFee, block.timestamp);
    }

    // View functions

    /**
     * @dev Get current onboarding nonce for validator (used when signing onboardSolver)
     */
    function getOnboardNonce(address account) external view returns (uint256) {
        return onboardNonces[account];
    }

    // /**
    //  * @dev Get current validation nonce for validator (used when signing validateSolverId)
    //  */
    function getValidateNonce(address account) external view returns (uint256) {
        return validateNonces[account];
    }

    /**
     * @dev Get the domain separator for EIP-712
     * @return bytes32 Domain separator
     */
    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @dev Get solver details
     */
    function getSolver(
        string memory solverId
    ) external view returns (Solver memory) {
        if (!solverExists[solverId]) revert SolverNotFound(solverId);
        return solvers[solverId];
    }

    /**
     * @dev Check if solver has validated their ID
     * @param solverId Solver ID to check
     * @return bool True if solver has validated their ID
     */
    function isSolverIdValidated(
        string memory solverId
    ) external view returns (bool) {
        return solverIdValidated[solverEvmAddress[solverId]];
    }

    /**
     * @dev Get all unique chain IDs across all active solvers
     * @return chainIds Array of unique chain IDs
     */
    function getAllActiveChainIds() external view returns (uint256[] memory) {
        uint256[] memory tempChainIds = new uint256[](1000);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < activeSolverIds.length; i++) {
            string memory solverId = activeSolverIds[i];

            if (solvers[solverId].isActive) {
                uint256[] memory solverChainIds = solvers[solverId].chainIds;

                for (uint256 j = 0; j < solverChainIds.length; j++) {
                    uint256 chainId = solverChainIds[j];

                    bool exists = false;
                    for (uint256 k = 0; k < uniqueCount; k++) {
                        if (tempChainIds[k] == chainId) {
                            exists = true;
                            break;
                        }
                    }

                    if (!exists) {
                        tempChainIds[uniqueCount] = chainId;
                        uniqueCount++;
                    }
                }
            }
        }

        uint256[] memory chainIds = new uint256[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount; i++) {
            chainIds[i] = tempChainIds[i];
        }

        return chainIds;
    }

    function getSolverEvmAddress(
        string memory solverId
    ) external view returns (address) {
        return solverEvmAddress[solverId];
    }

    /**
     * @dev Get total liquidity for all chains
     * @return liquidities Array of corresponding liquidity amounts
     */
    function getAllChainLiquidities()
        external
        view
        returns (uint256[] memory liquidities)
    {
        uint256[] memory chainIds = this.getAllActiveChainIds();
        liquidities = new uint256[](chainIds.length);

        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainLiquidity = 0;

            for (uint256 j = 0; j < activeSolverIds.length; j++) {
                string memory solverId = activeSolverIds[j];

                if (solvers[solverId].isActive) {
                    chainLiquidity += solverChainAmounts[solverId][chainIds[i]];
                }
            }

            liquidities[i] = chainLiquidity;
        }

        return liquidities;
    }

    function getSolverClaimedReward(
        string memory solverId,
        uint256 chainId
    ) external view returns (uint256) {
        return solverClaimedRewards[solverId][chainId];
    }

    function getSolverChainAmount(
        string memory solverId,
        uint256 chainId
    ) external view returns (uint256) {
        return solverChainAmounts[solverId][chainId];
    }

    function getSolverAddresses(
        string memory solverId
    ) external view returns (string[] memory) {
        if (!solverExists[solverId]) revert SolverNotFound(solverId);
        return solvers[solverId].solverAddresses;
    }

    function getSolverAllChainAmounts(
        string memory solverId
    ) external view returns (uint256[] memory amounts) {
        if (!solverExists[solverId]) revert SolverNotFound(solverId);

        uint256[] memory chainIds = solvers[solverId].chainIds;
        amounts = new uint256[](chainIds.length);

        for (uint256 i = 0; i < chainIds.length; i++) {
            amounts[i] = solverChainAmounts[solverId][chainIds[i]];
        }

        return amounts;
    }

    function getActiveSolvers() external view returns (string[] memory) {
        return activeSolverIds;
    }

    function isSolverActive(
        string memory solverId
    ) external view returns (bool) {
        return solverExists[solverId] && solvers[solverId].isActive;
    }

    function isSolverOnboarded(
        string memory solverId
    ) external view returns (bool) {
        return solverExists[solverId] && solvers[solverId].isOnboarded;
    }

    function getTotalActiveSolvers() external view returns (uint256) {
        return totalActiveSolvers;
    }

    function getSolverId(address solver) external view returns (string memory) {
        return solverAccount[solver];
    }

    function getMinimumLiquidityBTC() external view returns (uint256) {
        return minLiquidityBTC;
    }

    function getMinimumLiquidityTICS() external view returns (uint256) {
        return minLiquidityTICS;
    }

    function getSolverFeePercentage() external view returns (uint256) {
        return solverFeePercentage;
    }

    function getPlatformFeePercentage() external view returns (uint256) {
        return platformFeePercentage;
    }

    function getPlatformUnclaimedFee(
        uint256 chainId
    ) external view returns (uint256) {
        uint256 accrued = platformFeeAccrued[chainId];
        uint256 claimed = platformFeeClaimed[chainId];
        return accrued > claimed ? accrued - claimed : 0;
    }

    function getPlatformClaimedFee(
        uint256 chainId
    ) external view returns (uint256) {
        return platformFeeClaimed[chainId];
    }

    function getSolversUnclaimedRewards(
        string[] calldata solverIds
    ) external view returns (SolverUnclaimedRewards[] memory rewards) {
        rewards = new SolverUnclaimedRewards[](solverIds.length);

        for (uint256 i = 0; i < solverIds.length; i++) {
            string memory solverId = solverIds[i];

            if (!solverExists[solverId]) {
                rewards[i] = SolverUnclaimedRewards({
                    solverId: solverId,
                    btcUnclaimed: 0,
                    ticsUnclaimed: 0
                });
                continue;
            }

            uint256 btcAccrued = solverRewards[solverId][REQUIRED_CHAIN_BTC];
            uint256 btcClaimed = solverClaimedRewards[solverId][
                REQUIRED_CHAIN_BTC
            ];

            uint256 ticsAccrued = solverRewards[solverId][REQUIRED_CHAIN_TICS];
            uint256 ticsClaimed = solverClaimedRewards[solverId][
                REQUIRED_CHAIN_TICS
            ];

            rewards[i] = SolverUnclaimedRewards({
                solverId: solverId,
                btcUnclaimed: btcAccrued > btcClaimed
                    ? btcAccrued - btcClaimed
                    : 0,
                ticsUnclaimed: ticsAccrued > ticsClaimed
                    ? ticsAccrued - ticsClaimed
                    : 0
            });
        }
    }
}
