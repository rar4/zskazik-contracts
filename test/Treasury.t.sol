// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {CasinoToken} from "../contracts/CasinoToken.sol";
import {Treasury} from "../contracts/Treasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Treasury test suite: bankroll, escrow/settle, 50/50 split, caps, rescue.
contract TreasuryTest is Test {
    CasinoToken internal token;
    Treasury internal treasury;

    address internal owner;
    address internal game;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant OWNER_PK = 0x1234567890abcdef;
    uint256 internal constant ALICE_PK = 0xA11CE123;
    uint256 internal constant GAME_PK = 0x6A9E5;

    uint256 internal constant MIN_BET = 10 wei;
    uint256 internal constant MAX_BET = 1_000_000 * 1e18;
    uint256 internal constant MAX_PAYOUT = 10_000_000 * 1e18;
    uint256 internal constant MULTIPLIER = 10;
    uint256 internal constant MAX_EXPOSURE = 5_000_000 * 1e18;
    uint256 internal constant BANKROLL = 20_000_000 * 1e18;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 internal nonce;

    function setUp() public {
        owner = vm.addr(OWNER_PK);
        game = vm.addr(GAME_PK);
        // Alice needs a known PK for permit tests; re-derive address from it.
        alice = vm.addr(ALICE_PK);

        token = new CasinoToken(owner);
        treasury = new Treasury(
            address(token), owner, MIN_BET, MAX_BET, MAX_PAYOUT, MULTIPLIER, MAX_EXPOSURE
        );

        vm.startPrank(owner);
        treasury.authorizeGame(game);
        token.transfer(alice, 2_000_000 * 1e18);
        token.transfer(bob, 1_000_000 * 1e18);
        token.approve(address(treasury), BANKROLL);
        treasury.deposit(BANKROLL);
        // Wire circulation exclusion like production.
        token.setTreasury(address(treasury));
        vm.stopPrank();

        vm.startPrank(alice);
        token.approve(address(treasury), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        token.approve(address(treasury), type(uint256).max);
        vm.stopPrank();
    }

    function _betId() internal returns (bytes32) {
        nonce += 1;
        return keccak256(abi.encode(game, alice, nonce, block.timestamp));
    }

    function _signPermit(uint256 pk, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address signer = vm.addr(pk);
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, signer, spender, value, token.nonces(signer), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    // ========================================================================
    // Deployment / admin
    // ========================================================================

    function test_Deployment_LinksAndCaps() public view {
        assertEq(address(treasury.token()), address(token));
        assertEq(treasury.owner(), owner);
        assertEq(treasury.minBet(), MIN_BET);
        assertEq(treasury.maxBet(), MAX_BET);
        assertEq(treasury.maxPayout(), MAX_PAYOUT);
        assertEq(treasury.maxWinMultiplier(), MULTIPLIER);
        assertEq(treasury.maxTotalExposure(), MAX_EXPOSURE);
        assertEq(treasury.burnThreshold(), 20_000_000 * 1e18);
        assertTrue(treasury.isGame(game));
        assertEq(treasury.bankroll(), BANKROLL);
        assertEq(token.treasury(), address(treasury));
    }

    function test_Deployment_ZeroTokenReverts() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(0), owner, MIN_BET, MAX_BET, MAX_PAYOUT, MULTIPLIER, MAX_EXPOSURE);
    }

    function test_Deployment_ZeroOwnerReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Treasury(address(token), address(0), MIN_BET, MAX_BET, MAX_PAYOUT, MULTIPLIER, MAX_EXPOSURE);
    }

    function test_Admin_AuthorizeRevoke() public {
        // helper address without checksum issues
        address g2 = address(0x1234);
        vm.expectEmit(true, false, false, true);
        emit Treasury.GameAuthorized(g2);
        vm.prank(owner);
        treasury.authorizeGame(g2);
        assertTrue(treasury.isGame(g2));

        vm.expectEmit(true, false, false, true);
        emit Treasury.GameRevoked(g2);
        vm.prank(owner);
        treasury.revokeGame(g2);
        assertFalse(treasury.isGame(g2));
    }

    function test_Admin_NonOwnerCannotAuthorize() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        treasury.authorizeGame(bob);
    }

    function test_Admin_SetBurnThreshold() public {
        vm.expectEmit(false, false, false, true);
        emit Treasury.BurnThresholdUpdated(20_000_000 * 1e18, 30_000_000 * 1e18);
        vm.prank(owner);
        treasury.setBurnThreshold(30_000_000 * 1e18);
        assertEq(treasury.burnThreshold(), 30_000_000 * 1e18);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        treasury.setBurnThreshold(1);
    }

    function test_Admin_SetLimits() public {
        vm.expectEmit(false, false, false, true);
        emit Treasury.LimitsUpdated(1, 2, 3, 4, 5);
        vm.prank(owner);
        treasury.setLimits(1, 2, 3, 4, 5);
        assertEq(treasury.minBet(), 1);
        assertEq(treasury.maxBet(), 2);
        assertEq(treasury.maxPayout(), 3);
        assertEq(treasury.maxWinMultiplier(), 4);
        assertEq(treasury.maxTotalExposure(), 5);
    }

    // ========================================================================
    // Bankroll
    // ========================================================================

    function test_Deposit_BasicFlow() public {
        uint256 amount = 50_000 * 1e18;
        vm.prank(bob);
        // bob already max-approved in setUp; approve exact to be explicit
        treasury.deposit(amount);
        assertEq(treasury.bankroll(), BANKROLL + amount);
    }

    function test_Deposit_ZeroReverts() public {
        vm.expectRevert(Treasury.ZeroAmount.selector);
        vm.prank(bob);
        treasury.deposit(0);
    }

    function test_Deposit_WorksWhilePaused() public {
        vm.prank(owner);
        treasury.pause();
        vm.prank(bob);
        treasury.deposit(1_000 * 1e18);
        assertEq(treasury.bankroll(), BANKROLL + 1_000 * 1e18);
        vm.prank(owner);
        treasury.unpause();
    }

    function test_DepositWithPermit_NoPriorApprove() public {
        uint256 pk = 0xD0E9;
        address p = vm.addr(pk);
        vm.prank(owner);
        token.transfer(p, 100_000 * 1e18);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, address(treasury), 10_000 * 1e18, deadline);
        // No approve tx: depositor submits their own permit + deposit in one call.
        vm.prank(p);
        treasury.depositWithPermit(10_000 * 1e18, deadline, v, r, s);
        assertEq(treasury.bankroll(), BANKROLL + 10_000 * 1e18);
    }

    function test_Withdraw_OwnerOk() public {
        uint256 amount = 100_000 * 1e18;
        uint256 ownerBefore = token.balanceOf(owner);
        vm.prank(owner);
        treasury.withdraw(owner, amount);
        assertEq(token.balanceOf(owner), ownerBefore + amount);
        assertEq(treasury.bankroll(), BANKROLL - amount);
    }

    function test_Withdraw_NonOwnerReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        treasury.withdraw(alice, 1e18);
    }

    function test_Withdraw_GuardsActiveEscrow() public {
        bytes32 id = _betId();
        uint256 wager = 100_000 * 1e18;
        vm.prank(game);
        treasury.escrowBet(alice, wager, id);

        // Withdrawing everything would steal escrowed stakes.
        vm.expectRevert(
            abi.encodeWithSelector(
                Treasury.WouldLeaveInsolvent.selector, BANKROLL + wager - (BANKROLL + wager), wager
            )
        );
        vm.prank(owner);
        treasury.withdraw(owner, BANKROLL + wager);

        // Withdrawing surplus above activeWager is fine.
        vm.prank(owner);
        treasury.withdraw(owner, BANKROLL);
        assertEq(treasury.bankroll(), wager);
    }

    // ========================================================================
    // Escrow
    // ========================================================================

    function test_Escrow_BasicFlow() public {
        uint256 wager = 10_000 * 1e18;
        uint256 aliceBefore = token.balanceOf(alice);
        bytes32 id = _betId();

        vm.expectEmit(true, true, false, true);
        emit Treasury.BetEscrowed(id, alice, wager);
        vm.prank(game);
        treasury.escrowBet(alice, wager, id);

        assertEq(token.balanceOf(alice), aliceBefore - wager);
        assertEq(treasury.bankroll(), BANKROLL + wager);
        assertEq(treasury.activeWager(), wager);
        assertEq(treasury.activeBetCount(), 1);
        (address p, uint256 w, bool s) = treasury.bets(id);
        assertEq(p, alice);
        assertEq(w, wager);
        assertFalse(s);
    }

    function test_Escrow_NonGameReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Treasury.UnauthorizedGame.selector, alice));
        vm.prank(alice);
        treasury.escrowBet(alice, 1_000 * 1e18, _betId());
    }

    function test_Escrow_BelowMinReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Treasury.BelowMinBet.selector, MIN_BET - 1, MIN_BET));
        vm.prank(game);
        treasury.escrowBet(alice, MIN_BET - 1, _betId());
    }

    function test_Escrow_ExceedsMaxReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(Treasury.ExceedsMaxBet.selector, MAX_BET + 1, MAX_BET)
        );
        vm.prank(game);
        treasury.escrowBet(alice, MAX_BET + 1, _betId());
    }

    function test_Escrow_DuplicateBetIdReverts() public {
        bytes32 id = _betId();
        vm.prank(game);
        treasury.escrowBet(alice, 1_000 * 1e18, id);
        vm.expectRevert(abi.encodeWithSelector(Treasury.BetAlreadyExists.selector, id));
        vm.prank(game);
        treasury.escrowBet(alice, 1_000 * 1e18, id);
    }

    function test_Escrow_ExposureCapReverts() public {
        vm.prank(owner);
        treasury.setLimits(MIN_BET, MAX_BET, MAX_PAYOUT, MULTIPLIER, 5_000 * 1e18);
        bytes32 id1 = _betId();
        vm.prank(game);
        treasury.escrowBet(alice, 5_000 * 1e18, id1);
        vm.expectRevert(
            abi.encodeWithSelector(Treasury.ExceedsTotalExposure.selector, 6_000 * 1e18, 5_000 * 1e18)
        );
        vm.prank(game);
        treasury.escrowBet(alice, 1_000 * 1e18, _betId());
    }

    function test_Escrow_PausedReverts() public {
        vm.prank(owner);
        treasury.pause();
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vm.prank(game);
        treasury.escrowBet(alice, 1_000 * 1e18, _betId());
        vm.prank(owner);
        treasury.unpause();
    }

    function test_EscrowWithPermit_Works() public {
        uint256 pk = 0xBE77;
        address p = vm.addr(pk);
        vm.prank(owner);
        token.transfer(p, 200_000 * 1e18);

        bytes32 id = keccak256(abi.encode(game, p, uint256(1)));
        uint256 wager = 25_000 * 1e18;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, address(treasury), wager, deadline);

        assertEq(token.allowance(p, address(treasury)), 0);
        vm.prank(game);
        treasury.escrowBetWithPermit(p, wager, id, deadline, v, r, s);
        assertEq(treasury.activeWager(), wager);
        (address stored,,) = treasury.bets(id);
        assertEq(stored, p);
    }

    // ========================================================================
    // Settle: wins
    // ========================================================================

    function test_Settle_WinPaysOut() public {
        uint256 wager = 10_000 * 1e18;
        uint256 payout = 20_000 * 1e18; // 2x
        bytes32 id = _betId();
        vm.prank(game);
        treasury.escrowBet(alice, wager, id);

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bankBefore = treasury.bankroll();

        vm.expectEmit(true, true, false, true);
        emit Treasury.BetSettled(id, alice, wager, payout, 0);
        vm.prank(game);
        treasury.settleBet(id, payout);

        assertEq(token.balanceOf(alice), aliceBefore + payout);
        assertEq(treasury.bankroll(), bankBefore - payout);
        assertEq(treasury.activeWager(), 0);
        assertEq(treasury.totalPaidOut(), payout);
        (, , bool settled) = treasury.bets(id);
        assertTrue(settled);
    }

    function test_Settle_WinExceedsMaxPayoutReverts() public {
        bytes32 id = _betId();
        vm.prank(game);
        treasury.escrowBet(alice, 1_000 * 1e18, id);
        vm.expectRevert(
            abi.encodeWithSelector(
                Treasury.ExceedsMaxPayout.selector, MAX_PAYOUT + 1, MAX_PAYOUT
            )
        );
        vm.prank(game);
        treasury.settleBet(id, MAX_PAYOUT + 1);
    }

    function test_Settle_WinExceedsMultiplierReverts() public {
        bytes32 id = _betId();
        uint256 wager = 1_000 * 1e18;
        vm.prank(game);
        treasury.escrowBet(alice, wager, id);
        uint256 bad = wager * MULTIPLIER + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                Treasury.ExceedsWinMultiplier.selector, bad, wager * MULTIPLIER
            )
        );
        vm.prank(game);
        treasury.settleBet(id, bad);
    }

    function test_Settle_DoubleSettleReverts() public {
        bytes32 id = _betId();
        vm.prank(game);
        treasury.escrowBet(alice, 1_000 * 1e18, id);
        vm.prank(game);
        treasury.settleBet(id, 0);
        vm.expectRevert(abi.encodeWithSelector(Treasury.BetAlreadySettled.selector, id));
        vm.prank(game);
        treasury.settleBet(id, 0);
    }

    function test_Settle_UnknownBetReverts() public {
        bytes32 id = keccak256("nope");
        vm.expectRevert(abi.encodeWithSelector(Treasury.BetNotFound.selector, id));
        vm.prank(game);
        treasury.settleBet(id, 0);
    }

    function test_Settle_InsolventReverts() public {
        // Tiny bankroll treasury: payout exceeds balance.
        Treasury small = new Treasury(
            address(token), owner, MIN_BET, MAX_BET, MAX_PAYOUT, MULTIPLIER, 0
        );
        vm.prank(owner);
        small.authorizeGame(game);
        vm.prank(alice);
        token.approve(address(small), type(uint256).max);
        vm.prank(owner);
        token.transfer(address(small), 1_000 * 1e18);
        bytes32 id = keccak256(abi.encode(game, alice, uint256(999)));
        // Fund alice approval already max; escrow 500, try pay 5000 (>1500 bank).
        vm.prank(game);
        small.escrowBet(alice, 500 * 1e18, id);
        // 5000 <= maxPayout and <= 500*10=5000 multiplier, but bank is 1500.
        vm.expectRevert(
            abi.encodeWithSelector(Treasury.InsolventBankroll.selector, 5_000 * 1e18, 1_500 * 1e18)
        );
        vm.prank(game);
        small.settleBet(id, 5_000 * 1e18);
    }

    // ========================================================================
    // Settle: losses (threshold burn: keep full below 20M, burn excess above)
    // ========================================================================

    function test_Settle_LossAtThresholdBurnsExcess() public {
        uint256 wager = 100_000 * 1e18;
        bytes32 id = _betId();
        vm.prank(game);
        treasury.escrowBet(alice, wager, id);

        uint256 burnedBefore = token.totalBurned();

        vm.prank(game);
        treasury.settleBet(id, 0);

        // Bankroll was at the 20M threshold, escrow pushed it above, so
        // the full wager (the excess) is burned and the bank stays at 20M.
        assertEq(token.totalBurned(), burnedBefore + wager);
        assertEq(treasury.totalBurnedViaTreasury(), wager);
        assertEq(treasury.bankroll(), BANKROLL);
        assertEq(treasury.activeWager(), 0);
    }

    function test_Settle_LossBelowThresholdKeepsFullNoBurn() public {
        // Drop below the threshold first.
        vm.prank(owner);
        treasury.withdraw(owner, 1_000_000 * 1e18);
        assertEq(treasury.bankroll(), BANKROLL - 1_000_000 * 1e18);

        uint256 wager = 100_000 * 1e18;
        bytes32 id = _betId();
        vm.prank(game);
        treasury.escrowBet(alice, wager, id);

        uint256 burnedBefore = token.totalBurned();
        uint256 bankBefore = treasury.bankroll();

        vm.prank(game);
        treasury.settleBet(id, 0);

        // Below 20M: nothing burned, Treasury keeps the full wager.
        assertEq(token.totalBurned(), burnedBefore);
        assertEq(treasury.totalBurnedViaTreasury(), 0);
        assertEq(treasury.bankroll(), bankBefore);
        assertEq(treasury.activeWager(), 0);
    }

    function test_Settle_LossCrossingThresholdBurnsOnlyExcess() public {
        // Bankroll 100 ZSK below the threshold: only part of the wager is excess.
        vm.prank(owner);
        treasury.withdraw(owner, 100 * 1e18);

        uint256 wager = 1_000 * 1e18;
        bytes32 id = _betId();
        vm.prank(game);
        treasury.escrowBet(alice, wager, id);

        vm.prank(game);
        treasury.settleBet(id, 0);

        // Kept 100 to reach 20M, burned the remaining 900 excess.
        assertEq(treasury.bankroll(), BANKROLL);
        assertEq(treasury.totalBurnedViaTreasury(), 900 * 1e18);
    }

    function test_Settle_LossOddWei() public {
        uint256 wager = 101 wei;
        // minBet is 10 wei so 101 passes
        vm.prank(owner);
        token.transfer(bob, 1000);
        bytes32 id = keccak256(abi.encode(game, bob, uint256(4242)));
        vm.prank(game);
        treasury.escrowBet(bob, wager, id);
        vm.prank(game);
        treasury.settleBet(id, 0);
        // At the threshold the whole odd wager is excess and is burned.
        assertEq(treasury.totalBurnedViaTreasury(), 101);
    }

    function test_SplitLossDirect_PullAndBurnExcess() public {
        uint256 amount = 40_000 * 1e18;
        bytes32 id = _betId();
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bankBefore = treasury.bankroll();

        // _burnExcessOverThreshold emits ExcessBurned before LossSplit.
        vm.expectEmit(false, false, false, true);
        emit Treasury.ExcessBurned(amount, bankBefore);
        vm.expectEmit(true, true, false, true);
        emit Treasury.LossSplit(id, alice, amount, amount, 0);
        vm.prank(game);
        treasury.splitLossDirect(alice, amount, id);

        assertEq(token.balanceOf(alice), aliceBefore - amount);
        // bank: +amount in, -amount burned (all excess over 20M)
        assertEq(treasury.bankroll(), bankBefore);
        (, , bool settled) = treasury.bets(id);
        assertTrue(settled);
        assertEq(treasury.activeWager(), 0); // never entered active set
    }

    function test_BurnExcess_ManualOwnerOnly() public {
        // Deposit does not auto-burn; the excess is visible and trimmable.
        vm.prank(bob);
        treasury.deposit(50_000 * 1e18);
        assertEq(treasury.bankroll(), BANKROLL + 50_000 * 1e18);
        assertEq(treasury.excessOverThreshold(), 50_000 * 1e18);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        treasury.burnExcessOverThreshold();

        vm.prank(owner);
        uint256 burned = treasury.burnExcessOverThreshold();
        assertEq(burned, 50_000 * 1e18);
        assertEq(treasury.bankroll(), BANKROLL);
        assertEq(treasury.excessOverThreshold(), 0);
    }

    function test_BurnExcess_NeverBelowActiveWager() public {
        // Lower the threshold below the escrow: burn must stop at activeWager.
        vm.prank(owner);
        treasury.setBurnThreshold(1_000 * 1e18);
        bytes32 id = _betId();
        uint256 wager = 100_000 * 1e18;
        vm.prank(game);
        treasury.escrowBet(alice, wager, id);

        assertEq(treasury.excessOverThreshold(), BANKROLL + wager - wager);
        vm.prank(owner);
        treasury.burnExcessOverThreshold();
        assertEq(treasury.bankroll(), wager);
        assertEq(treasury.activeWager(), wager);
    }

    function test_BurnExcess_DisabledAtZero() public {
        vm.prank(owner);
        treasury.setBurnThreshold(0);
        vm.prank(bob);
        treasury.deposit(50_000 * 1e18);
        assertEq(treasury.excessOverThreshold(), 0);
        vm.prank(owner);
        assertEq(treasury.burnExcessOverThreshold(), 0);
        assertEq(treasury.bankroll(), BANKROLL + 50_000 * 1e18);
    }

    // ========================================================================
    // Cancel / rescue
    // ========================================================================

    function test_Cancel_GameRefundsFullWager() public {
        uint256 wager = 5_000 * 1e18;
        bytes32 id = _betId();
        vm.prank(game);
        treasury.escrowBet(alice, wager, id);
        uint256 aliceBefore = token.balanceOf(alice);

        vm.expectEmit(true, true, false, true);
        emit Treasury.BetCancelled(id, alice, wager, game);
        vm.prank(game);
        treasury.cancelBet(id);

        assertEq(token.balanceOf(alice), aliceBefore + wager);
        assertEq(treasury.activeWager(), 0);
        assertEq(treasury.totalRefunded(), wager);
    }

    function test_EmergencyRefund_OwnerRescuesAfterRevoke() public {
        uint256 wager = 7_000 * 1e18;
        bytes32 id = _betId();
        vm.prank(game);
        treasury.escrowBet(alice, wager, id);

        vm.prank(owner);
        treasury.revokeGame(game);

        // Game can no longer act...
        vm.expectRevert(abi.encodeWithSelector(Treasury.UnauthorizedGame.selector, game));
        vm.prank(game);
        treasury.settleBet(id, 0);

        // ...but owner refunds the player, even while paused.
        vm.prank(owner);
        treasury.pause();
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(owner);
        treasury.emergencyRefundBet(id);
        assertEq(token.balanceOf(alice), aliceBefore + wager);
        assertEq(treasury.activeWager(), 0);
        vm.prank(owner);
        treasury.unpause();
    }

    function test_EmergencyRefund_NonOwnerReverts() public {
        bytes32 id = _betId();
        vm.prank(game);
        treasury.escrowBet(alice, 1_000 * 1e18, id);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        treasury.emergencyRefundBet(id);
    }

    // ========================================================================
    // Fuzz accounting
    // ========================================================================

    function testFuzz_LossAccounting(uint256 wager) public {
        wager = bound(wager, MIN_BET, 500_000 * 1e18);
        // ensure alice funded for fuzzed size (cap keeps it in balance)
        vm.prank(owner);
        token.transfer(alice, wager);
        bytes32 id = keccak256(abi.encode(game, alice, wager, nonce++));
        uint256 bankBefore = treasury.bankroll();

        vm.prank(game);
        treasury.escrowBet(alice, wager, id);
        vm.prank(game);
        treasury.settleBet(id, 0);

        // Bankroll starts at the 20M threshold, so the whole wager is excess
        // and is burned; the bank returns to bankBefore.
        assertEq(treasury.bankroll(), bankBefore);
        assertEq(treasury.activeWager(), 0);
    }

    function testFuzz_WinAccounting(uint256 wager, uint256 mult) public {
        wager = bound(wager, MIN_BET, 100_000 * 1e18);
        mult = bound(mult, 1, MULTIPLIER); // payout > 0 (0 = loss path with burn)
        uint256 payout = wager * mult;
        // cap payout by bankroll for fuzz
        vm.assume(payout <= treasury.bankroll() + wager);
        vm.prank(owner);
        token.transfer(alice, wager);
        bytes32 id = keccak256(abi.encode(game, alice, wager, mult, nonce++));
        uint256 bankBefore = treasury.bankroll();

        vm.prank(game);
        treasury.escrowBet(alice, wager, id);
        vm.prank(game);
        treasury.settleBet(id, payout);

        assertEq(treasury.bankroll(), bankBefore + wager - payout);
        assertEq(treasury.activeWager(), 0);
    }
}
