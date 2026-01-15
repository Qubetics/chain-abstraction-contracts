// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";


contract SolverManager is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
 bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
 bytes32 public constant MPC_ROLE = keccak256("MPC_ROLE");
 bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

 // Required chains for solver activation
 uint256 public constant REQUIRED_CHAIN_BTC = 0;
 uint256 public constant REQUIRED_CHAIN_TICS = 9029;

 struct Solver {
 string solverId;
 string solverName;
 uint256[] chainIds;
 string[] solverAddresses; 
 bool isActive;
 bool isOnboarded; // Track if solver is onboarded vs offboarded
 uint256 onboardedAt;
 uint256 offboardedAt;
 }

 struct LiquidityDeposit {
 uint256 amount;
 uint256 chainId;
 uint256 timestamp;
 bool isDeposit; 
 }

 // Storage variables
 mapping(string => Solver) private solvers;
 mapping(string => bool) private solverExists;
 mapping(string => string) private addressToSolverId; 
 mapping(string => uint256) private solverTotalAmounts; 
 mapping(string => mapping(uint256 => uint256)) private solverChainAmounts; 
 mapping(string => LiquidityDeposit[]) private solverDeposits;
 mapping(string => address) private solverEvmAddress;
 mapping(string => mapping(uint256 => uint256)) private solverChainRewards;
 mapping(string => uint256) private solverTotalRewards;
 mapping(address => string) private solverAccount;

 // Minimum liquidity thresholds for required chains (stored but not enforced yet)
 uint256 private minLiquidityBTC;
 uint256 private minLiquidityTICS;
 
 string[] private activeSolverIds;
 uint256 private totalActiveSolvers;
 
 // Reserve storage slots for future upgrades
 uint256[47] private __gap;
 
 // Events
 event SolverOnboarded(
 string solverId,
 string solverName,
 uint256[] chainIds,
 string[] solverAddresses,
 uint256 timestamp
 );
 
 event SolverOffboarded(
 string solverId,
 string[] solverAddresses,
 uint256 timestamp
 );

 event SolverActivated(
 string solverId,
 uint256 timestamp
 );
 
 event SolverDeactivated(
 string solverId,
 string reason,
 uint256 timestamp
 );
 
 event LiquidityAdded(
 string solverId,
 uint256 chainId,
 uint256 amount,
 uint256 timestamp
 );
 
 event LiquidityRemoved(
 string solverId,
 uint256 chainId,
 uint256 amount,
 uint256 timestamp,
 string transactionHash
 );

 event RewardUpdated(
 string solverId,
 uint256[] rewards,
 string transactionHash,
 address solverAddress
 );

 event ContractUpgraded(address indexed newImplementation, uint256 timestamp);

 event MinimumLiquidityUpdated(
 uint256 chainId,
 uint256 oldMinimum,
 uint256 newMinimum,
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
error AddressAlreadyOnboarded(address addr);

constructor() {
    _disableInitializers();
}

 /**
 * @dev Initializer function (replaces constructor for upgradeable contracts)
 */
 function initialize(address _admin) external initializer {
  __AccessControl_init();
  __UUPSUpgradeable_init();
 
 _grantRole(DEFAULT_ADMIN_ROLE, _admin);
 _grantRole(ADMIN_ROLE, _admin);
 _grantRole(UPGRADER_ROLE, _admin);
 _grantRole(MPC_ROLE, _admin);
 
 // Initialize minimum liquidity thresholds with defaults (can be updated by admin)
 minLiquidityBTC = 600; // 600 satoshi
 minLiquidityTICS = 10 * 10**18; // 10 TICS (with 18 decimals) 
 }

 /**
 * @dev Required by UUPSUpgradeable - only UPGRADER_ROLE can authorize upgrades
 */
 function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
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


 modifier validAmount(uint256 amount) {
 if (amount == 0) revert InvalidAmount();
 _;
 }

 /**
 * @dev Check if solver meets required chain liquidity conditions
 * NOTE: Currently checks for > 0, NOT against minimum thresholds
 * @param solverId Solver's unique identifier
 * @return bool True if solver has liquidity on all required chains
 */
 function _meetsRequiredChainLiquidity(string memory solverId) internal view returns (bool) {
 // Check if solver has liquidity on BTC (chainId = 0)
 if (solverChainAmounts[solverId][REQUIRED_CHAIN_BTC] == 0) {
 return false;
 }
 
 // Check if solver has liquidity on TICS (chainId = 9029)
 if (solverChainAmounts[solverId][REQUIRED_CHAIN_TICS] == 0) {
 return false;
 }
 
 return true;
 }

 /**
 * @dev Check if both required chains have zero liquidity
 * @param solverId Solver's unique identifier
 * @return bool True if both BTC and TICS have zero liquidity
 */
 function _bothRequiredChainsZero(string memory solverId) internal view returns (bool) {
 return solverChainAmounts[solverId][REQUIRED_CHAIN_BTC] == 0 && 
 solverChainAmounts[solverId][REQUIRED_CHAIN_TICS] == 0;
 }

 /**
 * @dev Activate solver if requirements are met
 * @param solverId Solver's unique identifier
 */
 function _activateSolverIfEligible(string memory solverId) internal {
 // Only activate if currently inactive and meets requirements
 if (!solvers[solverId].isActive && _meetsRequiredChainLiquidity(solverId)) {
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
 function _deactivateSolverIfNeeded(string memory solverId, string memory reason) internal {
 // Only deactivate if currently active and doesn't meet requirements
 if (solvers[solverId].isActive && !_meetsRequiredChainLiquidity(solverId)) {
 solvers[solverId].isActive = false;
 _removeFromActiveSolvers(solverId);
 totalActiveSolvers--;
 emit SolverDeactivated(solverId, reason, block.timestamp);
 }
 }


 /**
 * @dev Onboard a new solver 
 * @param solverId Unique identifier for the solver
 * @param solverName Name of the solver
 * @param chainIds Array of chain IDs where solver operates
 * @param solverAddresses Array of string addresses belonging to the solver
 */
function onboardSolver(
    string memory solverId,
    string memory solverName,
    uint256[] memory chainIds,
    string[] memory solverAddresses
) 
external
{
    // Ensure each EVM address can only onboard once
    if (bytes(solverAccount[msg.sender]).length != 0) {
        revert AddressAlreadyOnboarded(msg.sender);
    }
    if (solverExists[solverId]) revert SolverAlreadyExists(solverId);
    if (chainIds.length == 0) revert EmptyChainIdsList();
    if (solverAddresses.length == 0) revert EmptyAddressList();
    require(bytes(solverId).length != 0, "Solver ID cannot be empty");

 solverEvmAddress[solverId] = msg.sender;
 
 // Validate addresses
 for (uint256 i = 0; i < solverAddresses.length; i++) {
 if (bytes(solverAddresses[i]).length == 0) revert InvalidSolverAddress();
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
 }
 
 // Update state
 solverExists[solverId] = true;
 solverAccount[msg.sender] = solverId;
 
 // Note: Solver is NOT added to activeSolverIds yet
 // Will be added automatically when they add required liquidity
 
 emit SolverOnboarded(solverId, solverName, chainIds, solverAddresses, block.timestamp);
 }

 
 /**
 * @dev Add liquidity by solver for specific chain
 * @param solverId Solver's unique identifier
 * @param chainId Chain ID where liquidity is added
 * @param amount Amount to add
 */ 
 function addLiquidity(
 string memory solverId,
 uint256 chainId,
 uint256 amount
 ) 
 external 
 onlyOnboardedSolver(solverId)
 validAmount(amount)
onlyRole(MPC_ROLE)
 {

 // Update chain-specific amounts
 solverChainAmounts[solverId][chainId] += amount;
 solverTotalAmounts[solverId] += amount;
 
 // Record deposit
 solverDeposits[solverId].push(LiquidityDeposit({
 amount: amount,
 chainId: chainId,
 timestamp: block.timestamp,
 isDeposit: true
 }));
 
 emit LiquidityAdded(solverId, chainId, amount, block.timestamp);

 // Check if solver should be activated (after adding liquidity)
 _activateSolverIfEligible(solverId);
 }

 /**
 * @dev Remove liquidity by solver from specific chain
 * @param solverId Solver's unique identifier
 * @param chainId Chain ID from where liquidity is removed
 * @param amount Amount to remove
 */
 function removeLiquidity(
 string memory solverId,
 uint256 chainId,
 uint256 amount,
 string memory transactionHash
 ) 
 external 
 onlyOnboardedSolver(solverId)
 validAmount(amount)
 onlyRole(MPC_ROLE)
 {

 if (solverChainAmounts[solverId][chainId] < amount) {
 revert InsufficientBalance();
 }
 
 // Update chain-specific amounts
 solverChainAmounts[solverId][chainId] -= amount;
 solverTotalAmounts[solverId] -= amount;
 
 // Record withdrawal
 solverDeposits[solverId].push(LiquidityDeposit({
 amount: amount,
 chainId: chainId,
 timestamp: block.timestamp,
 isDeposit: false
 }));

 emit LiquidityRemoved(solverId, chainId, amount, block.timestamp, transactionHash);

 // Step 1: Check if any required chain becomes zero → DEACTIVATE
 if (!_meetsRequiredChainLiquidity(solverId)) {
 _deactivateSolverIfNeeded(solverId, "Required chain liquidity became zero");
 }

 }

 /**
 * @dev Update solver rewards across all chainIds (POOL_ROLE only)
 * @param solverAddress Address belonging to the solver
 * @param rewards Array of rewards matching solver chainIds order
 */
 function updateSolverRewards(
 address solverAddress,
 uint256[] memory rewards,
 string memory transactionHash
 )
 external
 onlyRole(MPC_ROLE)
 {
 string memory solverId = solverAccount[solverAddress];
 if (bytes(solverId).length == 0) revert UnauthorizedSolver();
 if (!solvers[solverId].isActive) revert SolverNotActive(solverId);

 uint256[] memory chainIds = solvers[solverId].chainIds;

 if (rewards.length == 0) revert EmptyAmountsList();
 if (chainIds.length != rewards.length) revert ArrayLengthMismatch();

 uint256 newTotal = 0;

 // Update reward per chain
 for (uint256 i = 0; i < chainIds.length; i++) {
 uint256 chainId = chainIds[i];
 solverChainRewards[solverId][chainId] = rewards[i];
 newTotal += rewards[i];
 }

 // Update total reward
 solverTotalRewards[solverId] = newTotal;
 emit RewardUpdated(solverId, rewards, transactionHash, solverAddress);
 }

 // View functions
 /**
 * @dev Get solver details
 */
 function getSolver(string memory solverId) external view returns (Solver memory) {
 if (!solverExists[solverId]) revert SolverNotFound(solverId);
 return solvers[solverId];
 }

 /**
 * @dev Get all unique chain IDs across all active solvers
 * @return chainIds Array of unique chain IDs
 */
 function getAllActiveChainIds() external view returns (uint256[] memory) {
 uint256[] memory tempChainIds = new uint256[](1000); // Temporary array with max size
 uint256 uniqueCount = 0;
 
 // Collect all chain IDs from active solvers
 for (uint256 i = 0; i < activeSolverIds.length; i++) {
 string memory solverId = activeSolverIds[i];
 
 if (solvers[solverId].isActive) {
 uint256[] memory solverChainIds = solvers[solverId].chainIds;
 
 for (uint256 j = 0; j < solverChainIds.length; j++) {
 uint256 chainId = solverChainIds[j];
 
 // Check if chainId already exists in our temp array
 bool exists = false;
 for (uint256 k = 0; k < uniqueCount; k++) {
 if (tempChainIds[k] == chainId) {
 exists = true;
 break;
 }
 }
 
 // If not exists, add to temp array
 if (!exists) {
 tempChainIds[uniqueCount] = chainId;
 uniqueCount++;
 }
 }
 }
 }
 
 // Create result array with exact size
 uint256[] memory chainIds = new uint256[](uniqueCount);
 for (uint256 i = 0; i < uniqueCount; i++) {
 chainIds[i] = tempChainIds[i];
 }
 
 return chainIds;
 }

 function get_solver_evm_address(string memory solverId) external view returns(address){
 return solverEvmAddress[solverId];
 }

 function getSolverAllChainRewards(string memory solverAddress)
 external
 view
 returns (uint256[] memory rewards)
 {
 // Resolve solverId from address
 string memory solverId = addressToSolverId[solverAddress];
 if (bytes(solverId).length == 0) revert UnauthorizedSolver();
 if (!solvers[solverId].isActive) revert SolverNotActive(solverId);

 uint256[] memory chainIds = solvers[solverId].chainIds;
 rewards = new uint256[](chainIds.length);

 for (uint256 i = 0; i < chainIds.length; i++) {
 rewards[i] = solverChainRewards[solverId][chainIds[i]];
 }

 return rewards;
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
 // Get all unique chain IDs first
 uint256[] memory chainIds = this.getAllActiveChainIds();
 liquidities = new uint256[](chainIds.length);
 
 // Calculate liquidity for each chain
 for (uint256 i = 0; i < chainIds.length; i++) {
 uint256 chainLiquidity = 0;
 
 // Sum liquidity across all active solvers for this chain
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

 /**
 * @dev Get solver total amount across all chains
 */
 function getSolverTotalAmount(string memory solverId) 
 external 
 view 
 returns (uint256) 
 {
 return solverTotalAmounts[solverId];
 }

 /**
 * @dev Get solver amount for specific chain
 */
 function getSolverChainAmount(string memory solverId, uint256 chainId) 
 external 
 view 
 returns (uint256) 
 {
 return solverChainAmounts[solverId][chainId];
 }

 /**
 * @dev Get solver addresses
 */
 function getSolverAddresses(string memory solverId) 
 external 
 view 
 returns (string[] memory) 
 {
 if (!solverExists[solverId]) revert SolverNotFound(solverId);
 return solvers[solverId].solverAddresses;
 }

 /**
 * @dev Get amounts for all chains of a solver
 */
 function getSolverAllChainAmounts(string memory solverId) 
 external 
 view 
 returns (uint256[] memory amounts) 
 {
 if (!solverExists[solverId]) revert SolverNotFound(solverId);
 
 uint256[] memory chainIds = solvers[solverId].chainIds;
 amounts = new uint256[](chainIds.length);
 
 for (uint256 i = 0; i < chainIds.length; i++) {
 amounts[i] = solverChainAmounts[solverId][chainIds[i]];
 }
 
 return amounts;
 }

 /**
 * @dev Get all active solver IDs
 */
 function getActiveSolvers() external view returns (string[] memory) {
 return activeSolverIds;
 }
 
 /**
 * @dev Get solver deposit history
 */
 function getSolverDeposits(string memory solverId) 
 external 
 view 
 returns (LiquidityDeposit[] memory) 
 {
 return solverDeposits[solverId];
 }

 /**
 * @dev Check if solver is active
 */
 function isSolverActive(string memory solverId) external view returns (bool) {
 return solverExists[solverId] && solvers[solverId].isActive;
 }

 /**
 * @dev Check if solver is onboarded
 */
 function isSolverOnboarded(string memory solverId) external view returns (bool) {
 return solverExists[solverId] && solvers[solverId].isOnboarded;
 }

 /**
 * @dev Get total number of active solvers
 */
 function getTotalActiveSolvers() external view returns (uint256) {
 return totalActiveSolvers;
 }

 /**
 * @dev Get solver id for solver onboarded evm address
 */
 function getSolverId(address solver) external view returns (string memory){
 return solverAccount[solver];
 }

 /**
 * @dev Get solver ID for a given address
 */
 function getSolverIdByAddress(string memory solverAddress) 
 external 
 view 
 returns (string memory) 
 {
 return addressToSolverId[solverAddress];
 }

 /**
 * @dev Check if solver meets required chain liquidity (public view function)
 * @param solverId Solver's unique identifier
 * @return bool True if solver has liquidity on all required chains
 */
 function meetsRequiredChainLiquidity(string memory solverId) 
 external 
 view 
 returns (bool) 
 {
 if (!solverExists[solverId]) revert SolverNotFound(solverId);
 return _meetsRequiredChainLiquidity(solverId);
 }

 /**
 * @dev Check if both required chains have zero liquidity (public view function)
 * @param solverId Solver's unique identifier
 * @return bool True if both BTC and TICS have zero liquidity
 */
 function bothRequiredChainsZero(string memory solverId) 
 external 
 view 
 returns (bool) 
 {
 if (!solverExists[solverId]) revert SolverNotFound(solverId);
 return _bothRequiredChainsZero(solverId);
 }

 /**
 * @dev Set minimum liquidity for BTC chain (ADMIN_ROLE only)
 * NOTE: Currently stored but NOT enforced in activation logic
 * @param newMinimum New minimum liquidity threshold for BTC
 */
 function setMinimumLiquidityBTC(uint256 newMinimum) 
 external 
 onlyRole(ADMIN_ROLE) 
 {
 uint256 oldMinimum = minLiquidityBTC;
 minLiquidityBTC = newMinimum;
 emit MinimumLiquidityUpdated(REQUIRED_CHAIN_BTC, oldMinimum, newMinimum, block.timestamp);
 }

 /**
 * @dev Set minimum liquidity for TICS chain (ADMIN_ROLE only)
 * NOTE: Currently stored but NOT enforced in activation logic
 * @param newMinimum New minimum liquidity threshold for TICS
 */
 function setMinimumLiquidityTICS(uint256 newMinimum) 
 external 
 onlyRole(ADMIN_ROLE) 
 {
 uint256 oldMinimum = minLiquidityTICS;
 minLiquidityTICS = newMinimum;
 emit MinimumLiquidityUpdated(REQUIRED_CHAIN_TICS, oldMinimum, newMinimum, block.timestamp);
 }

 /**
 * @dev Get minimum liquidity threshold for BTC chain
 * @return uint256 Minimum liquidity required for BTC
 */
 function getMinimumLiquidityBTC() external view returns (uint256) {
 return minLiquidityBTC;
 }

 /**
 * @dev Get minimum liquidity threshold for TICS chain
 * @return uint256 Minimum liquidity required for TICS
 */
 function getMinimumLiquidityTICS() external view returns (uint256) {
 return minLiquidityTICS;
 }

 // Internal functions
 function _removeFromActiveSolvers(string memory solverId) internal {
 for (uint256 i = 0; i < activeSolverIds.length; i++) {
 if (keccak256(abi.encodePacked(activeSolverIds[i])) == keccak256(abi.encodePacked(solverId))) {
 activeSolverIds[i] = activeSolverIds[activeSolverIds.length - 1];
 activeSolverIds.pop();
 break;
 }
 }
 }
}