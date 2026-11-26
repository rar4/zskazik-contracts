// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GameBase} from "./GameBase.sol";

/// @title Dice — roll-over 1..99, payout = wager * 98 / (100 - target) (2% edge)
/// @dev Example: target 50 -> 50% chance, 1.96x. Target 90 -> 10% chance, 9.8x.
///      Target 99 -> 1% chance, 98x (Treasury maxWinMultiplier must be >= 98).
///      Player = _msgSender(), must have approved the TREASURY for the wager.
contract Dice is GameBase {
    uint8 public constant MIN_TARGET = 1;
    uint8 public constant MAX_TARGET = 99;
    /// @notice Numerator of the 98% RTP payout: payout = wager * 98 / (100 - target).
    uint256 public constant PAYOUT_NUM = 98;

    struct Roll {
        address player;
        uint256 wager;
        bytes32 treasuryBetId;
        uint64 placeBlock;
        uint8 target;
        bool settled;
        uint256 payout;
        uint8 roll;
    }

    mapping(bytes32 => Roll) public rolls;

    event RollPlaced(
        bytes32 indexed gameBetId, address indexed player, uint256 wager, uint8 target
    );
    event RollResolved(
        bytes32 indexed gameBetId,
        address indexed player,
        uint8 roll,
        bool won,
        uint256 payout
    );
    event RollCancelled(bytes32 indexed gameBetId, address indexed player, uint256 wager);

    constructor(address treasuryAddr, address initialOwner, address trustedForwarder_)
        GameBase(treasuryAddr, initialOwner, trustedForwarder_)
    {}

    function roll(uint8 target, uint256 wager)
        external
        nonReentrant
        whenNotPaused
        returns (bytes32 gameBetId)
    {
        if (wager == 0) revert ZeroWager();
        if (target < MIN_TARGET || target > MAX_TARGET) revert BadTarget();
        // Fail fast at placement instead of stranding at settle (same
        // pre-check Plinko does): at target 99 the payout is 98x, so a
        // large wager can exceed maxPayout and settleBet would revert
        // forever, stranding the stake until the refund timeout.
        uint256 worst = (wager * PAYOUT_NUM) / (100 - target);
        require(worst <= treasury.maxPayout(), "dice: exceeds maxPayout");
        require(worst <= wager * treasury.maxWinMultiplier(), "dice: exceeds multiplier");
        bytes32 treasuryBetId;
        (gameBetId, treasuryBetId) = _nextIds(_msgSender());
        rolls[gameBetId] = Roll({
            player: _msgSender(),
            wager: wager,
            treasuryBetId: treasuryBetId,
            placeBlock: uint64(_l2BlockNumber()),
            target: target,
            settled: false,
            payout: 0,
            roll: 0
        });
        treasury.escrowBet(_msgSender(), wager, treasuryBetId);
        emit RollPlaced(gameBetId, _msgSender(), wager, target);
    }

    function resolve(bytes32 gameBetId) external nonReentrant whenNotPaused {
        Roll storage r = rolls[gameBetId];
        if (r.player == address(0)) revert BetNotFound();
        if (r.settled) revert AlreadySettled();
        _requireResolvable(r.placeBlock);
        r.settled = true;

        uint8 outcome = uint8(_random(r.treasuryBetId, r.placeBlock) % 100);
        r.roll = outcome;
        bool won = outcome >= r.target;
        uint256 payout = won ? (r.wager * PAYOUT_NUM) / (100 - r.target) : 0;
        treasury.settleBet(r.treasuryBetId, payout);
        r.payout = payout;
        emit RollResolved(gameBetId, r.player, outcome, won, payout);
    }

    function refund(bytes32 gameBetId) external nonReentrant {
        Roll storage r = rolls[gameBetId];
        if (r.player == address(0)) revert BetNotFound();
        if (r.settled) revert AlreadySettled();
        if (_msgSender() != r.player && _msgSender() != owner()) revert NotBetOwner();
        if (_msgSender() != owner() && _l2BlockNumber() <= r.placeBlock + REFUND_TIMEOUT_BLOCKS) {
            revert RefundTooEarly();
        }
        r.settled = true;
        treasury.cancelBet(r.treasuryBetId);
        emit RollCancelled(gameBetId, r.player, r.wager);
    }
}
