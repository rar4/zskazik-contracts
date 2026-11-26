// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GameBase} from "./GameBase.sol";

/// @title CoinFlip — pick a side, 1.96x on win (2% edge)
/// @dev V1 testnet randomness (see GameBase). Player = _msgSender(), must have
///      approved the TREASURY (not this contract) for the wager.
contract CoinFlip is GameBase {
    /// @notice 19600 bps = 1.96x payout on win.
    uint256 public constant PAYOUT_BPS = 19_600;

    struct Flip {
        address player;
        uint256 wager;
        bytes32 treasuryBetId;
        uint64 placeBlock;
        bool choiceHeads;
        bool settled;
        uint256 payout;
    }

    mapping(bytes32 => Flip) public flips;

    event FlipPlaced(
        bytes32 indexed gameBetId, address indexed player, uint256 wager, bool choiceHeads
    );
    event FlipResolved(
        bytes32 indexed gameBetId, address indexed player, bool won, uint256 payout
    );
    event FlipCancelled(bytes32 indexed gameBetId, address indexed player, uint256 wager);

    constructor(address treasuryAddr, address initialOwner, address trustedForwarder_)
        GameBase(treasuryAddr, initialOwner, trustedForwarder_)
    {}

    /// @notice Place a flip. Returns the game bet id for tracking/resolve.
    function flip(bool choiceHeads, uint256 wager)
        external
        nonReentrant
        whenNotPaused
        returns (bytes32 gameBetId)
    {
        if (wager == 0) revert ZeroWager();
        // Fail fast at placement instead of stranding at settle (same
        // pre-check Plinko does): if the max win would exceed Treasury
        // caps, settleBet would revert forever and the stake would sit
        // in escrow until the refund timeout.
        uint256 worst = (wager * PAYOUT_BPS) / 10_000;
        require(worst <= treasury.maxPayout(), "flip: exceeds maxPayout");
        require(worst <= wager * treasury.maxWinMultiplier(), "flip: exceeds multiplier");
        bytes32 treasuryBetId;
        (gameBetId, treasuryBetId) = _nextIds(_msgSender());
        flips[gameBetId] = Flip({
            player: _msgSender(),
            wager: wager,
            treasuryBetId: treasuryBetId,
            placeBlock: uint64(_l2BlockNumber()),
            choiceHeads: choiceHeads,
            settled: false,
            payout: 0
        });
        treasury.escrowBet(_msgSender(), wager, treasuryBetId);
        emit FlipPlaced(gameBetId, _msgSender(), wager, choiceHeads);
    }

    /// @notice Resolve a flip. Permissionless after the placing block.
    function resolve(bytes32 gameBetId) external nonReentrant whenNotPaused {
        Flip storage f = flips[gameBetId];
        if (f.player == address(0)) revert BetNotFound();
        if (f.settled) revert AlreadySettled();
        _requireResolvable(f.placeBlock);
        f.settled = true;

        bool isHeads = _random(f.treasuryBetId, f.placeBlock) % 2 == 0;
        bool won = (isHeads == f.choiceHeads);
        uint256 payout = won ? (f.wager * PAYOUT_BPS) / 10_000 : 0;
        treasury.settleBet(f.treasuryBetId, payout);
        f.payout = payout;
        emit FlipResolved(gameBetId, f.player, won, payout);
    }

    /// @notice Refund an unsettled flip: player after timeout, owner anytime.
    /// @dev Cancels the Treasury escrow (stake back to player, no burn).
    function refund(bytes32 gameBetId) external nonReentrant {
        Flip storage f = flips[gameBetId];
        if (f.player == address(0)) revert BetNotFound();
        if (f.settled) revert AlreadySettled();
        if (_msgSender() != f.player && _msgSender() != owner()) revert NotBetOwner();
        if (_msgSender() != owner() && _l2BlockNumber() <= f.placeBlock + REFUND_TIMEOUT_BLOCKS) {
            revert RefundTooEarly();
        }
        f.settled = true;
        treasury.cancelBet(f.treasuryBetId);
        emit FlipCancelled(gameBetId, f.player, f.wager);
    }
}
