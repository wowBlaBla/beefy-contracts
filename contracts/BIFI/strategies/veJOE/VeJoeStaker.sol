// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin-4/contracts/utils/math/SafeMath.sol";
import "@openzeppelin-4/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-4/contracts/security/ReentrancyGuard.sol";

import "./IJoeChef.sol";
import "./IVeJoe.sol";
import "./ChefManager.sol";

interface IRewarder {
    function rewardToken() external view returns (address);
    function isNative() external view returns (bool);
}

contract VeJoeStaker is ERC20, ReentrancyGuard, ChefManager {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Addresses used
    IERC20 public want;
    IVeJoe public veJoe;
    address public native;

    // Our reserve integers 
    uint16 public constant MAX = 10000;
    uint256 public reserveRate; 

    event DepositWant(uint256 tvl);
    event Withdraw(uint256 tvl);
    event RecoverTokens(address token, uint256 amount);
    event UpdatedReserveRate(uint256 newRate);

    constructor(
        address _veJoe,
        address _keeper,
        uint256 _reserveRate,
        address _joeBatch, 
        uint256 _beJoeShare,
        address _native,
        string memory _name,
        string memory _symbol
    ) ChefManager(_keeper, _joeBatch, _beJoeShare) ERC20(_name, _symbol) {
        veJoe = IVeJoe(_veJoe);
        want = IERC20(veJoe.joe());
        reserveRate = _reserveRate;
        native = _native;

        want.safeApprove(address(veJoe), type(uint256).max);
    }

    // helper function for depositing full balance of want
    function depositAll() external {
        _deposit(want.balanceOf(msg.sender));
    }

    // deposit an amount of want
    function deposit(uint256 _amount) external {
        _deposit(_amount);
    }

    // Deposits Joes and mint beJOE, harvests and checks for veJOE deposit opportunities first. 
    function _deposit(uint256 _amount) internal nonReentrant whenNotPaused {
        harvestAndDepositJoe();
        uint256 _pool = balanceOfWant();
        want.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 _after = balanceOfWant();
        _amount = _after.sub(_pool); // Additional check for deflationary tokens

        if (_amount > 0) {
            _mint(msg.sender, _amount);
            emit DepositWant(totalJoes());
        }
    }

    // Withdraw capable if we have enough JOEs in the contract. 
    function withdraw(uint256 _amount) public {
        require(_amount <= balanceOfWant(), "Not enough JOEs");
            _burn(msg.sender, _amount);
            want.safeTransfer(msg.sender, _amount);
            emit Withdraw(totalJoes());
    }

    // We harvest veJOE on every deposit, if we can deposit to earn more veJOE we deposit based on required reserve and bonus
    function harvestAndDepositJoe() public { 
        if (totalJoes() > 0) {
            if (balanceOfWant() > requiredReserve()) {
                uint256 avaialableBalance = balanceOfWant().sub(requiredReserve());
                // we want the bonus for depositing more than 5% of our already deposited joes
                uint256 joesNeededForBonus = balanceOfJoeInVe().mul(veJoe.speedUpThreshold()).div(100);
                if (avaialableBalance > joesNeededForBonus) {
                    veJoe.deposit(avaialableBalance);
                } 
            }
            _harvestVeJoe();
        }
    }

    // claim the veJoes
    function _harvestVeJoe() internal {
        veJoe.claim();
    }

    // Our required JOEs held in the contract to enable withdraw capabilities
    function requiredReserve() public view returns (uint256 reqReserve) {
        // We calculate allocation for reserve of the total staked JOEs.
        reqReserve = balanceOfJoeInVe().mul(reserveRate).div(MAX);
    }

    // Total Joes in veJOE contract and beJOE contract. 
    function totalJoes() public view returns (uint256) {
        return balanceOfWant().add(balanceOfJoeInVe());
    }

    // Calculate how much 'want' is held by this contract
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    // Calculate how much 'veWant' is held by this contract
    function balanceOfVe() public view returns (uint256) {
        return IERC20(veJoe.veJoe()).balanceOf(address(this));
    }

    // How many joes we got earning ve? 
    function balanceOfJoeInVe() public view returns (uint256 joes) {
        (joes,,,) = veJoe.userInfos(address(this));
    }

     // Whats the speed up timing
    function speedUpTimestamp() public view returns (uint256 time) {
        (,,,time) = veJoe.userInfos(address(this));
    }

    // Prevent any further 'want' deposits and remove approval
    function pause() public onlyManager {
        _pause();
        want.safeApprove(address(veJoe), 0);
    }

    // allow 'want' deposits again and reinstate approval
    function unpause() external onlyManager {
        _unpause();
        want.safeApprove(address(veJoe), type(uint256).max);
        uint256 reserveAmt = balanceOfWant().mul(reserveRate).div(MAX);
        if (reserveAmt > 0) {
            veJoe.deposit(balanceOfWant().sub(reserveAmt));
        }
    }

    // panic beJOE, pause deposits and withdraw JOEs from veJoe, we lose all accrued veJOE 
    function panic() external onlyManager {
        pause();
        veJoe.withdraw(balanceOfJoeInVe());
    }

    // pass through a deposit to a boosted chef 
    function deposit(address _joeChef, uint256 _pid, uint256 _amount) external onlyWhitelist(_joeChef, _pid) {
        // Grab needed pool info
        (address _underlying,,,,, address _rewarder,,,) = IJoeChef(_joeChef).poolInfo(_pid);

        // Take before balances snapshot and transfer want from strat
        uint256 joeBefore = balanceOfWant(); // How many Joe's the strategy holds    
        IERC20(_underlying).safeTransferFrom(msg.sender, address(this), _amount);

        // Handle a second reward via a rewarder
        address rewardToken;
        uint256 rewardBefore; 
        uint256 nativeBefore;
        if (_rewarder != address(0)) {
            rewardToken = IRewarder(_rewarder).rewardToken();
            rewardBefore = IERC20(rewardToken).balanceOf(address(this));
            if (IRewarder(_rewarder).isNative()) {
                nativeBefore = address(this).balance;
            } 
        }

        IJoeChef(_joeChef).deposit(_pid, _amount);
        uint256 joeDiff = balanceOfWant().sub(joeBefore); // Amount of Joes the Chef sent us
        
        // Send beJoe Batch their JOEs
        if (joeDiff > 0) {
            uint256 batchJoes = joeDiff.mul(beJoeShare).div(MAX);
            want.safeTransfer(joeBatch, batchJoes);

            uint256 remaining = joeDiff.sub(batchJoes);
            want.safeTransfer(msg.sender, remaining);
        }

        // Transfer the second reward
        if (_rewarder != address(0)) {
            if (IRewarder(_rewarder).isNative()) {
                uint256 nativeDiff = address(this).balance.sub(nativeBefore);
                (bool sent,) = msg.sender.call{value: nativeDiff}("");
                require(sent, "Failed to send Ether");
            } else {
                uint256 rewardDiff = IERC20(rewardToken).balanceOf(address(this)).sub(rewardBefore);
                IERC20(rewardToken).safeTransfer(msg.sender, rewardDiff);
            }
        }
    }

    // Pass through a withdrawal from boosted chef
    function withdraw(address _joeChef, uint256 _pid, uint256 _amount) external onlyWhitelist(_joeChef, _pid) {
        // Grab needed pool info
        (address _underlying,,,,, address _rewarder,,,) = IJoeChef(_joeChef).poolInfo(_pid);

        uint256 joeBefore = balanceOfWant(); // How many Joe's strategy the holds  

        // Handle a second reward via a rewarder
        address rewardToken;
        uint256 rewardBefore; 
        uint256 nativeBefore;
        if (_rewarder != address(0)) {
            rewardToken = IRewarder(_rewarder).rewardToken();
            rewardBefore = IERC20(rewardToken).balanceOf(address(this));
            if (IRewarder(_rewarder).isNative()) {
                nativeBefore = address(this).balance;
            } 
        }
        
        IJoeChef(_joeChef).withdraw(_pid, _amount);
        uint256 joeDiff = balanceOfWant().sub(joeBefore); // Amount of Joes the Chef sent us
        IERC20(_underlying).safeTransfer(msg.sender, _amount);

        // Transfer the second reward
        if (_rewarder != address(0)) {
            if (IRewarder(_rewarder).isNative()) {
                uint256 nativeDiff = address(this).balance.sub(nativeBefore);
                (bool sent,) = msg.sender.call{value: nativeDiff}("");
                require(sent, "Failed to send Ether");
            } else {
                uint256 rewardDiff = IERC20(rewardToken).balanceOf(address(this)).sub(rewardBefore);
                IERC20(rewardToken).safeTransfer(msg.sender, rewardDiff);
            }
        }

        if (joeDiff > 0) {
            // Send beJoe Batch their JOEs
            uint256 batchJoes = joeDiff.mul(beJoeShare).div(MAX);
            want.safeTransfer(joeBatch, batchJoes);

            uint256 remaining = joeDiff.sub(batchJoes);
            want.safeTransfer(msg.sender, remaining); 
        }
    }

    // emergency withdraw losing all JOE rewards from boosted chef
    function emergencyWithdraw(address _joeChef, uint256 _pid) external onlyWhitelist(_joeChef, _pid) {
        (address _underlying,,,,,,,,) = IJoeChef(_joeChef).poolInfo(_pid);
        uint256 _before = IERC20(_underlying).balanceOf(address(this));
        IJoeChef(_joeChef).emergencyWithdraw(_pid);
        uint256 _balance = IERC20(_underlying).balanceOf(address(this)).sub(_before);
        IERC20(_underlying).safeTransfer(msg.sender, _balance);
    }

    // Adjust reserve rate 
    function adjustReserve(uint256 _rate) external onlyOwner { 
        require(_rate <= MAX, "Higher than max");
        reserveRate = _rate;
        emit UpdatedReserveRate(_rate);
    }

    // recover any tokens sent on error
    function inCaseTokensGetStuck(address _token, bool _native) external onlyOwner {
        require(_token != address(want), "!token");

        if (_native) {
            uint256 _nativeAmount = address(this).balance;
            (bool sent,) = msg.sender.call{value: _nativeAmount}("");
            require(sent, "Failed to send Ether");
            emit RecoverTokens(_token, _nativeAmount);
        } else {
            uint256 _amount = IERC20(_token).balanceOf(address(this));
            IERC20(_token).safeTransfer(msg.sender, _amount);
            emit RecoverTokens(_token, _amount);
        }
    }

    receive () external payable {}
}
