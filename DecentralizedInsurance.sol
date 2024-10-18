// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract DecentralizedInsurance is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    IERC20Upgradeable public paymentToken;

    struct Policy {
        uint256 coverageAmount;
        uint256 premium;
        uint256 startDate;
        uint256 endDate;
        bool isActive;
    }

    struct Claim {
        uint256 amount;
        uint256 fileDate;
        ClaimStatus status;
    }

    enum ClaimStatus { Pending, Approved, Rejected }

    mapping(address => Policy) public policies;
    mapping(address => Claim[]) public claims;

    uint256 public constant COVERAGE_PERIOD = 365 days;
    uint256 public constant CLAIM_REVIEW_PERIOD = 7 days;
    uint256 public totalPremiumPool;
    uint256 public claimProcessingFee;
    uint256 public maxCoverageAmount;
    uint256 public minCoverageAmount;

    event PolicyPurchased(address indexed policyholder, uint256 coverageAmount, uint256 premium);
    event ClaimFiled(address indexed policyholder, uint256 claimId, uint256 amount);
    event ClaimProcessed(address indexed policyholder, uint256 claimId, ClaimStatus status);
    event PolicyCancelled(address indexed policyholder, uint256 refundAmount);
    event ClaimProcessingFeeUpdated(uint256 newFee);
    event CoverageLimitsUpdated(uint256 newMinCoverage, uint256 newMaxCoverage);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _paymentToken,
        uint256 _claimProcessingFee,
        uint256 _minCoverageAmount,
        uint256 _maxCoverageAmount
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        paymentToken = IERC20Upgradeable(_paymentToken);
        claimProcessingFee = _claimProcessingFee;
        minCoverageAmount = _minCoverageAmount;
        maxCoverageAmount = _maxCoverageAmount;
    }

    function purchasePolicy(uint256 _coverageAmount) external nonReentrant {
        require(_coverageAmount >= minCoverageAmount && _coverageAmount <= maxCoverageAmount, "Invalid coverage amount");
        require(!policies[msg.sender].isActive, "Active policy already exists");

        uint256 premium = calculatePremium(_coverageAmount);
        require(paymentToken.transferFrom(msg.sender, address(this), premium), "Premium payment failed");

        policies[msg.sender] = Policy({
            coverageAmount: _coverageAmount,
            premium: premium,
            startDate: block.timestamp,
            endDate: block.timestamp + COVERAGE_PERIOD,
            isActive: true
        });

        totalPremiumPool += premium;

        emit PolicyPurchased(msg.sender, _coverageAmount, premium);
    }

    function fileClaim(uint256 _amount) external nonReentrant {
        Policy storage policy = policies[msg.sender];
        require(policy.isActive, "No active policy found");
        require(block.timestamp < policy.endDate, "Policy has expired");
        require(_amount <= policy.coverageAmount, "Claim amount exceeds coverage");
        require(paymentToken.transferFrom(msg.sender, address(this), claimProcessingFee), "Claim processing fee payment failed");

        uint256 claimId = claims[msg.sender].length;
        claims[msg.sender].push(Claim({
            amount: _amount,
            fileDate: block.timestamp,
            status: ClaimStatus.Pending
        }));

        emit ClaimFiled(msg.sender, claimId, _amount);
    }

    function processClaim(address _policyholder, uint256 _claimId, bool _approve) external onlyOwner nonReentrant {
        require(_claimId < claims[_policyholder].length, "Invalid claim ID");
        Claim storage claim = claims[_policyholder][_claimId];
        require(claim.status == ClaimStatus.Pending, "Claim already processed");
        require(block.timestamp <= claim.fileDate + CLAIM_REVIEW_PERIOD, "Claim review period expired");

        if (_approve) {
            claim.status = ClaimStatus.Approved;
            require(paymentToken.transfer(_policyholder, claim.amount), "Claim payment failed");
            totalPremiumPool -= claim.amount;
            policies[_policyholder].coverageAmount -= claim.amount;
            if (policies[_policyholder].coverageAmount == 0) {
                policies[_policyholder].isActive = false;
            }
        } else {
            claim.status = ClaimStatus.Rejected;
        }

        emit ClaimProcessed(_policyholder, _claimId, claim.status);
    }

    function cancelPolicy() external nonReentrant {
        Policy storage policy = policies[msg.sender];
        require(policy.isActive, "No active policy found");

        uint256 timeRemaining = policy.endDate - block.timestamp;
        uint256 refundAmount = (policy.premium * timeRemaining) / COVERAGE_PERIOD;

        policy.isActive = false;
        totalPremiumPool -= refundAmount;

        require(paymentToken.transfer(msg.sender, refundAmount), "Refund transfer failed");

        emit PolicyCancelled(msg.sender, refundAmount);
    }

    function calculatePremium(uint256 _coverageAmount) public pure returns (uint256) {
        // Simplified premium calculation (5% of coverage amount)
        return (_coverageAmount * 5) / 100;
    }

    function getPolicyDetails(address _policyholder) external view returns (Policy memory) {
        return policies[_policyholder];
    }

    function getClaimsCount(address _policyholder) external view returns (uint256) {
        return claims[_policyholder].length;
    }

    function getClaim(address _policyholder, uint256 _claimId) external view returns (Claim memory) {
        require(_claimId < claims[_policyholder].length, "Invalid claim ID");
        return claims[_policyholder][_claimId];
    }

    function withdrawExcessFunds(uint256 _amount) external onlyOwner {
        require(_amount <= totalPremiumPool, "Insufficient funds in the pool");
        require(paymentToken.transfer(owner(), _amount), "Withdrawal failed");
        totalPremiumPool -= _amount;
    }

    function setClaimProcessingFee(uint256 _newFee) external onlyOwner {
        claimProcessingFee = _newFee;
        emit ClaimProcessingFeeUpdated(_newFee);
    }

    function setCoverageLimits(uint256 _newMinCoverage, uint256 _newMaxCoverage) external onlyOwner {
        require(_newMinCoverage < _newMaxCoverage, "Invalid coverage limits");
        minCoverageAmount = _newMinCoverage;
        maxCoverageAmount = _newMaxCoverage;
        emit CoverageLimitsUpdated(_newMinCoverage, _newMaxCoverage);
    }

    function getTotalPremiumPool() external view returns (uint256) {
        return totalPremiumPool;
    }

}