// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

contract TreasuryVault is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    uint256 public totalBalance;

    bytes32 public constant INTENT_MANAGER_ROLE =
        keccak256("INTENT_MANAGER_ROLE");
    bytes32 public constant SOLVER_MANAGER_ROLE =
        keccak256("SOLVER_MANAGER_ROLE");

    event Deposit(address indexed from, uint256 amount);
    event Transfer(address indexed to, uint256 amount);
    event BatchTransfer(uint256 totalAmount, uint256 recipientCount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract (replaces constructor for upgradeable contracts)
     */
    function initialize() public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Required by UUPSUpgradeable - authorizes upgrades
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @dev Modifier to check if caller has either INTENT_MANAGER or SOLVER_MANAGER role
     */
    modifier onlyManagers() {
        require(
            hasRole(INTENT_MANAGER_ROLE, msg.sender) ||
                hasRole(SOLVER_MANAGER_ROLE, msg.sender),
            "Caller is not a manager"
        );
        _;
    }

    // Receive TICS deposits
    receive() external payable {
        totalBalance += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    // Fallback function
    fallback() external payable {
        totalBalance += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @dev Batch transfer function to send TICS to multiple addresses
     * @param recipients Array of recipient addresses
     * @param amounts Array of amounts to send (in wei)
     */
    function batchTransfer(
        address[] memory recipients,
        uint256[] memory amounts
    )
        external
        onlyManagers
        whenNotPaused
        nonReentrant
    {
        require(recipients.length == amounts.length, "Arrays length mismatch");
        require(recipients.length > 0, "No recipients provided");

        uint256 totalAmount = 0;

        // Calculate total amount needed
        for (uint256 i = 0; i < amounts.length; i++) {
            require(recipients[i] != address(0), "Invalid recipient address");
            require(amounts[i] > 0, "Amount must be greater than 0");
            totalAmount += amounts[i];
        }

        require(address(this).balance >= totalAmount, "Insufficient balance");

        // Execute transfers
        for (uint256 i = 0; i < recipients.length; i++) {
            (bool success, ) = recipients[i].call{value: amounts[i]}("");
            require(success, "Transfer failed");
            emit Transfer(recipients[i], amounts[i]);
        }

        totalBalance = address(this).balance;
        emit BatchTransfer(totalAmount, recipients.length);
    }

    /**
     * @dev Grant Intent Manager role to an address
     * @param account Address to grant role to
     */
    function grantIntentManagerRole(
        address account
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(INTENT_MANAGER_ROLE, account);
    }

    /**
     * @dev Grant Solver Manager role to an address
     * @param account Address to grant role to
     */
    function grantSolverManagerRole(
        address account
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(SOLVER_MANAGER_ROLE, account);
    }

    /**
     * @dev Revoke Intent Manager role from an address
     * @param account Address to revoke role from
     */
    function revokeIntentManagerRole(
        address account
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(INTENT_MANAGER_ROLE, account);
    }

    /**
     * @dev Revoke Solver Manager role from an address
     * @param account Address to revoke role from
     */
    function revokeSolverManagerRole(
        address account
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(SOLVER_MANAGER_ROLE, account);
    }

    /**
     * @dev Check if an address has Intent Manager role
     * @param account Address to check
     */
    function isIntentManager(address account) external view returns (bool) {
        return hasRole(INTENT_MANAGER_ROLE, account);
    }

    /**
     * @dev Check if an address has Solver Manager role
     * @param account Address to check
     */
    function isSolverManager(address account) external view returns (bool) {
        return hasRole(SOLVER_MANAGER_ROLE, account);
    }

    /**
     * @dev Get contract balance
     */
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function deposit(uint256 amount) external payable {}

    /**
     * @dev Get implementation version
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}