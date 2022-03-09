// SPDX-License-Identifier: MIT

pragma solidity ^0.8.12;

import {BaseTestHarness, console} from "./utils/BaseTestHarness.sol";

// Interfaces
import {IBeefyVaultV6} from "./interfaces/IBeefyVaultV6.sol";
import {IStrategyComplete} from "./interfaces/IStrategyComplete.sol";
import {IERC20Like} from "./interfaces/IERC20Like.sol";

// Users
import {VaultUser} from "./users/VaultUser.sol";

contract ProdVaultTest is BaseTestHarness {

    // Input your vault to test here.
    IBeefyVaultV6 constant vault = IBeefyVaultV6(0x1313b9C550bbDF55Fc06f63a41D8BDC719d056A6);
    IStrategyComplete strategy;

    // Users
    VaultUser user;
    address constant keeper = 0x10aee6B5594942433e7Fc2783598c979B030eF3D;
    address constant vaultOwner = 0x4560a83b7eED32EB78C48A5bedE9B608F3184df0; // fantom
    address constant strategyOwner = 0x847298aC8C28A9D66859E750456b92C2A67b876D; // fantom

    IERC20Like want;
    uint256 slot; // Storage slot that holds `balanceOf` mapping.
    bool slotSet;
    // Input amount of test want.
    uint256 wantStartingAmount = 50 ether;
    uint256 delay = 1000 seconds; // Time to wait after depositing before harvesting.


    function setUp() public {
        want = IERC20Like(vault.want());
        strategy = IStrategyComplete(vault.strategy());
        
        user = new VaultUser();

        // Slot set is for performance speed up.
        if (slotSet) {
            modifyBalanceWithKnownSlot(vault.want(), address(user), wantStartingAmount, slot);
        } else {
            slot = modifyBalance(vault.want(), address(user), wantStartingAmount);
            slotSet = true;
        }
    }

    function test_depositAndWithdraw() external {
        _unpauseIfPaused();

        _depositIntoVault(user);
        
        shift(100 seconds);

        console.log("Withdrawing all want from vault");
        user.withdrawAll(vault);

        uint256 wantBalanceFinal = want.balanceOf(address(user));
        console.log("Final user want balance", wantBalanceFinal);
        assertTrue(wantBalanceFinal <= wantStartingAmount, "Expected wantBalanceFinal <= wantStartingAmount");
        assertTrue(wantBalanceFinal > wantStartingAmount * 99 / 100, "Expected wantBalanceFinal > wantStartingAmount * 99 / 100");
    }

    function test_harvest() external {
        _unpauseIfPaused();
        
        _depositIntoVault(user);

        uint256 vaultBalance = vault.balance();
        uint256 pricePerFullShare = vault.getPricePerFullShare();
        uint256 lastHarvest = strategy.lastHarvest();

        uint256 timestampBeforeHarvest = block.timestamp;
        shift(delay);

        console.log("Harvesting vault.");
        bool didHarvest = _harvest();
        assertTrue(didHarvest, "Harvest failed.");

        uint256 vaultBalanceAfterHarvest = vault.balance();
        uint256 pricePerFullShareAfterHarvest = vault.getPricePerFullShare();
        uint256 lastHarvestAfterHarvest = strategy.lastHarvest();

        console.log("Withdrawing all want.");
        user.withdrawAll(vault);

        uint256 wantBalanceFinal = want.balanceOf(address(user));

        assertTrue(vaultBalanceAfterHarvest > vaultBalance, "Expected vaultBalanceAfterHarvest > vaultBalance");
        assertTrue(pricePerFullShareAfterHarvest > pricePerFullShare, "Expected pricePerFullShareAfterHarvest > pricePerFullShare");
        assertTrue(wantBalanceFinal > wantStartingAmount * 99 / 100, "Expected wantBalanceFinal > wantStartingAmount * 99 / 100");
        assertTrue(lastHarvestAfterHarvest > lastHarvest, "Expected lastHarvestAfterHarvest > lastHarvest");
        assertTrue(lastHarvestAfterHarvest == timestampBeforeHarvest + delay, "Expected lastHarvestAfterHarvest == timestampBeforeHarvest + delay");
    }

    function test_panic() external {
        _unpauseIfPaused();
        
        _depositIntoVault(user);

        uint256 vaultBalance = vault.balance();
        uint256 balanceOfPool = strategy.balanceOfPool();
        uint256 balanceOfWant = strategy.balanceOfWant();

        assertTrue(balanceOfPool > balanceOfWant);
        
        console.log("Calling panic()");
        FORGE_VM.prank(keeper);
        strategy.panic();

        uint256 vaultBalanceAfterPanic = vault.balance();
        uint256 balanceOfPoolAfterPanic = strategy.balanceOfPool();
        uint256 balanceOfWantAfterPanic = strategy.balanceOfWant();

        assertTrue(vaultBalanceAfterPanic > vaultBalance  * 99 / 100, "Expected vaultBalanceAfterPanic > vaultBalance");
        assertTrue(balanceOfWantAfterPanic > balanceOfPoolAfterPanic, "Expected balanceOfWantAfterPanic > balanceOfPoolAfterPanic");

        console.log("Getting user more want.");
        modifyBalanceWithKnownSlot(vault.want(), address(user), wantStartingAmount, slot);
        console.log("Approving more want.");
        user.approve(address(want), address(vault), wantStartingAmount);
        
        // Users can't deposit.
        console.log("Trying to deposit while panicked.");
        FORGE_VM.expectRevert("Pausable: paused");
        user.depositAll(vault);
        
        // User can still withdraw
        console.log("User withdraws all.");
        user.withdrawAll(vault);

        uint256 wantBalanceFinal = want.balanceOf(address(user));
        assertTrue(wantBalanceFinal > wantStartingAmount * 99 / 100, "Expected wantBalanceFinal > wantStartingAmount * 99 / 100");
    }

    function test_multipleUsers() external {
        _unpauseIfPaused();
        
        _depositIntoVault(user);

        // Setup second user.
        VaultUser user2 = new VaultUser();
        console.log("Getting want for user2.");
        modifyBalanceWithKnownSlot(address(want), address(user2), wantStartingAmount, slot);

        uint256 pricePerFullShare = vault.getPricePerFullShare();

        shift(delay);

        console.log("User2 depositAll.");
        _depositIntoVault(user2);
        
        uint256 pricePerFullShareAfterUser2Deposit = vault.getPricePerFullShare();

        shift(delay);

        console.log("User1 withdrawAll.");
        user.withdrawAll(vault);

        uint256 user1WantBalanceFinal = want.balanceOf(address(user));
        uint256 pricePerFullShareAfterUser1Withdraw = vault.getPricePerFullShare();

        assertTrue(pricePerFullShareAfterUser2Deposit >= pricePerFullShare, "Expected pricePerFullShareAfterUser2Deposit >= pricePerFullShare");
        assertTrue(pricePerFullShareAfterUser1Withdraw >= pricePerFullShareAfterUser2Deposit, "Expected pricePerFullShareAfterUser1Withdraw >= pricePerFullShareAfterUser2Deposit");
        assertTrue(user1WantBalanceFinal > wantStartingAmount * 99 / 100, "Expected user1WantBalanceFinal > wantStartingAmount * 99 / 100");
    }

    function test_correctOwnerAndKeeper() external {
        assertTrue(vault.owner() == vaultOwner, "Wrong vault owner.");
        assertTrue(strategy.owner() == strategyOwner, "Wrong strategy owner.");
        assertTrue(strategy.keeper() == keeper, "Wrong keeper.");
    }

    function test_harvestOnDeposit() external {
        bool harvestOnDeposit = strategy.harvestOnDeposit();
        if (harvestOnDeposit) {
            console.log("Vault is harvestOnDeposit.");
            assertTrue(strategy.withdrawalFee() == 0, "Vault is harvestOnDeposit but has withdrawal fee.");
        } else {
            console.log("Vault is NOT harvestOnDeposit.");
            assertTrue(strategy.keeper() == keeper, "Vault is not harvestOnDeposit but doesn't have withdrawal fee.");
        }
    }

    /*         */
    /* Helpers */
    /*         */

    function _unpauseIfPaused() internal {
        if (strategy.paused()) {
            console.log("Unpausing vault.");
            FORGE_VM.prank(keeper);
            strategy.unpause();
        }
    }

    function _depositIntoVault(VaultUser user_) internal {
        console.log("Approving want spend.");
        user_.approve(address(want), address(vault), wantStartingAmount);
        console.log("Depositing all want into vault", wantStartingAmount);
        user_.depositAll(vault);
    }

    function _harvest() internal returns (bool didHarvest_) {
        // Retry a few times
        uint256 retryTimes = 5;
        for (uint256 i = 0; i < retryTimes; i++) {
            try strategy.harvest(address(user)) {
                didHarvest_ = true;
                break;
            } catch Error(string memory reason) {
                console.log("Harvest failed with", reason);
            } catch Panic(uint256 errorCode) {
                console.log("Harvest panicked, failed with", errorCode);
            } catch (bytes memory) {
                console.log("Harvest failed.");
            }
            if (i != retryTimes - 1) {
                console.log("Trying harvest again.");
                shift(delay);
            }
        }
    }
}