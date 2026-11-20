// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {CasinoToken} from "../contracts/CasinoToken.sol";
import {Treasury} from "../contracts/Treasury.sol";
import {CoinFlip} from "../contracts/games/CoinFlip.sol";
import {Dice} from "../contracts/games/Dice.sol";
import {Plinko} from "../contracts/games/Plinko.sol";
import {GameBase} from "../contracts/games/GameBase.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice End-to-end tests: player -> game -> treasury escrow/settle.
contract GamesTest is Test {
    CasinoToken internal token;
    Treasury internal treasury;
    CoinFlip internal flip;
    Dice internal dice;
    Plinko internal plinko;

    address internal owner;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant OWNER_PK = 0x1234567890abcdef;

    function setUp() public {
        owner = vm.addr(OWNER_PK);
        token = new CasinoToken(owner);
        // multiplier 20 covers dice 19.6x + plinko 16x
        treasury = new Treasury(address(token), owner, 1e12, 1_000_000 * 1e18, 50_000_000 * 1e18, 20, 0);
        flip = new CoinFlip(address(treasury), owner);
        dice = new Dice(address(treasury), owner);
        plinko = new Plinko(address(treasury), owner);

        vm.startPrank(owner);
        treasury.authorizeGame(address(flip));
        treasury.authorizeGame(address(dice));
        treasury.authorizeGame(address(plinko));
        // bankroll 50M
        token.approve(address(treasury), 50_000_000 * 1e18);
        treasury.deposit(50_000_000 * 1e18);
        token.transfer(alice, 2_000_000 * 1e18);
        token.transfer(bob, 2_000_000 * 1e18);
        vm.stopPrank();

        vm.prank(alice);
        token.approve(address(treasury), type(uint256).max);
        vm.prank(bob);
        token.approve(address(treasury), type(uint256).max);
    }

    // --- helpers: find a prevrandao that forces win/loss for a pending bet ---

    function _forceCoinflip(bytes32 tBetId, uint256 placeBlock, bool wantHeads)
        internal
        returns (bytes32)
    {
        for (uint256 i = 1; i < 2000; i++) {
            bytes32 pr = bytes32(i * 0x9e3779b97f4a7c15);
            bool heads = uint256(keccak256(abi.encode(tBetId, pr, placeBlock))) % 2 == 0;
            if (heads == wantHeads) return pr;
        }
        revert("no coin randomness");
    }

    function _resolveFlip(bytes32 gameId, bool wantWin, bool choiceHeads) internal {
        (bytes32 tBetId, uint256 placeBlock,) = _flipSeed(gameId);
        bool wantHeads = wantWin ? choiceHeads : !choiceHeads;
        bytes32 pr = _forceCoinflip(tBetId, placeBlock, wantHeads);
        vm.roll(block.number + 1);
        vm.prevrandao(pr);
        flip.resolve(gameId);
    }

    function _flipSeed(bytes32 id) internal view returns (bytes32 tBetId, uint256 placeBlock, bool choice) {
        (, , bytes32 t, uint64 pb, bool ch,,) = flip.flips(id);
        return (t, pb, ch);
    }

    function _flipPayout(bytes32 id) internal view returns (uint256 pay) {
        (,,,,,, pay) = flip.flips(id);
    }

    // ========================================================================
    // CoinFlip
    // ========================================================================

    function test_Flip_WinPays196() public {
        vm.prank(alice);
        bytes32 id = flip.flip(true, 10_000 * 1e18);
        _resolveFlip(id, true, true);
        uint256 pay = _flipPayout(id);
        assertEq(pay, (10_000 * 1e18 * 19_600) / 10_000);
        assertEq(token.balanceOf(alice), 2_000_000 * 1e18 - 10_000 * 1e18 + pay);
    }

    function test_Flip_LossBurnsHalf() public {
        uint256 burnedBefore = token.totalBurned();
        uint256 bankBefore = treasury.bankroll();
        vm.prank(alice);
        bytes32 id = flip.flip(true, 10_000 * 1e18);
        _resolveFlip(id, false, true);
        assertEq(token.totalBurned(), burnedBefore + 5_000 * 1e18);
        assertEq(treasury.bankroll(), bankBefore + 5_000 * 1e18); // kept half
    }

    function test_Flip_SameBlockResolveReverts() public {
        vm.prank(alice);
        bytes32 id = flip.flip(true, 1_000 * 1e18);
        vm.expectRevert(GameBase.TooEarly.selector);
        flip.resolve(id);
    }

    function test_Flip_DoubleResolveReverts() public {
        vm.prank(alice);
        bytes32 id = flip.flip(true, 1_000 * 1e18);
        _resolveFlip(id, true, true);
        vm.expectRevert(GameBase.AlreadySettled.selector);
        flip.resolve(id);
    }

    function test_Flip_RefundAfterTimeout() public {
        vm.prank(alice);
        bytes32 id = flip.flip(true, 5_000 * 1e18);
        uint256 balBefore = token.balanceOf(alice);
        vm.roll(block.number + 7201);
        vm.prank(alice);
        flip.refund(id);
        assertEq(token.balanceOf(alice), balBefore + 5_000 * 1e18);
    }

    function test_Flip_RefundTooEarlyReverts() public {
        vm.prank(alice);
        bytes32 id = flip.flip(true, 5_000 * 1e18);
        vm.expectRevert(GameBase.RefundTooEarly.selector);
        vm.prank(alice);
        flip.refund(id);
    }

    // ========================================================================
    // Dice
    // ========================================================================

    function test_Dice_WinMath() public {
        // target 50 -> 1.96x
        vm.prank(bob);
        bytes32 id = dice.roll(50, 10_000 * 1e18);
        (,,,, uint8 target,,,) = dice.rolls(id);
        assertEq(target, 50);
        // force win: find prevrandao with roll >= 50
        (bytes32 tBetId, uint256 pb) = _diceSeed(id);
        bytes32 pr = _forceDice(tBetId, pb, 50, true);
        vm.roll(block.number + 1);
        vm.prevrandao(pr);
        dice.resolve(id);
        (,,,,,, uint256 pay,) = dice.rolls(id);
        assertEq(pay, (10_000 * 1e18 * 98) / 50);
    }

    function test_Dice_LossBurns() public {
        uint256 burnedBefore = token.totalBurned();
        vm.prank(bob);
        bytes32 id = dice.roll(90, 5_000 * 1e18); // 10% chance
        (bytes32 tBetId, uint256 pb) = _diceSeed(id);
        bytes32 pr = _forceDice(tBetId, pb, 90, false);
        vm.roll(block.number + 1);
        vm.prevrandao(pr);
        dice.resolve(id);
        assertEq(token.totalBurned(), burnedBefore + 2_500 * 1e18);
    }

    function test_Dice_BadTargetReverts() public {
        vm.expectRevert(GameBase.BadTarget.selector);
        vm.prank(bob);
        dice.roll(4, 1_000 * 1e18);
        vm.expectRevert(GameBase.BadTarget.selector);
        vm.prank(bob);
        dice.roll(96, 1_000 * 1e18);
    }

    function _diceInfo(bytes32 id)
        internal
        view
        returns (address, uint256, bytes32, uint64, uint8, bool, uint256, uint8)
    {
        return dice.rolls(id);
    }

    function _diceSeed(bytes32 id) internal view returns (bytes32, uint256) {
        (,, bytes32 t, uint64 pb,,,,) = dice.rolls(id);
        return (t, pb);
    }

    function _forceDice(bytes32 tBetId, uint256 pb, uint8 target, bool wantWin)
        internal
        returns (bytes32)
    {
        for (uint256 i = 1; i < 5000; i++) {
            bytes32 pr = bytes32(i * 0x9e3779b97f4a7c15 + 7);
            uint8 r = uint8(uint256(keccak256(abi.encode(tBetId, pr, pb))) % 100);
            if ((r >= target) == wantWin) return pr;
        }
        revert("no dice randomness");
    }

    // ========================================================================
    // Plinko
    // ========================================================================

    function test_Plinko_TablesSane() public view {
        assertEq(plinko.multBps(8, 0), 56_000);
        assertEq(plinko.multBps(8, 4), 5_000);
        assertEq(plinko.multBps(12, 0), 100_000);
        assertEq(plinko.multBps(16, 0), 160_000);
        assertEq(plinko.multBps(16, 8), 5_000);
    }

    function test_Plinko_BadRowsReverts() public {
        vm.expectRevert(GameBase.BadTarget.selector);
        vm.prank(alice);
        plinko.drop(10, 1_000 * 1e18);
    }

    function test_Plinko_PlaceAndResolve() public {
        vm.prank(alice);
        bytes32 id = plinko.drop(8, 10_000 * 1e18);
        uint256 bankAfterEscrow = treasury.bankroll();
        vm.roll(block.number + 1);
        plinko.resolve(id);
        (address p, uint256 w,,,, bool s, uint8 bin, uint256 pay) = plinko.drops(id);
        assertEq(p, alice);
        assertTrue(s);
        assertEq(pay, (w * plinko.multBps(8, bin)) / 10_000);
        // bankAfterEscrow already includes the escrowed wager; win pays out of it,
        // loss burns half of the wager from it.
        uint256 burned = pay == 0 ? w / 2 : 0;
        assertEq(treasury.bankroll(), bankAfterEscrow - pay - burned);
    }

    function _burnedFor(uint256 wager, uint256 payout) internal pure returns (uint256) {
        return payout == 0 ? wager / 2 : 0;
    }

    function test_Plinko_ExceedsPayoutRevertsAtPlace() public {
        // 16x on huge wager exceeds 50M maxPayout -> place reverts, no stuck funds
        vm.expectRevert("plinko: exceeds maxPayout");
        vm.prank(alice);
        plinko.drop(16, 10_000_000 * 1e18);
    }

    function test_Plinko_OwnerCanRefund() public {
        vm.prank(alice);
        bytes32 id = plinko.drop(8, 5_000 * 1e18);
        uint256 before = token.balanceOf(alice);
        vm.prank(owner);
        plinko.refund(id);
        assertEq(token.balanceOf(alice), before + 5_000 * 1e18);
    }

    // ========================================================================
    // Cross-game security
    // ========================================================================

    function test_Games_NonGameCannotEscrowDirectly() public {
        // Treasury onlyGame gate still holds for raw calls
        vm.expectRevert(
            abi.encodeWithSelector(Treasury.UnauthorizedGame.selector, alice)
        );
        vm.prank(alice);
        treasury.escrowBet(alice, 1_000 * 1e18, keccak256("x"));
    }

    function test_Games_PausedBlocksPlacement() public {
        vm.prank(owner);
        flip.pause();
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vm.prank(alice);
        flip.flip(true, 1_000 * 1e18);
    }

    function test_Games_TreasuryRevokeContains() public {
        vm.prank(owner);
        treasury.revokeGame(address(flip));
        assertFalse(treasury.isGame(address(flip)));
        vm.expectRevert(
            abi.encodeWithSelector(Treasury.UnauthorizedGame.selector, address(flip))
        );
        vm.prank(alice);
        flip.flip(true, 1_000 * 1e18);
    }
}
