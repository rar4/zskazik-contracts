// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GameBase} from "./GameBase.sol";

/// @title Plinko — 8/12/16 rows, binomial bins, table multipliers (~98-99% RTP)
/// @dev Ball path: bit i of randomness = bounce right at row i. Bin = #rights.
///      Payout = wager * multBps(bin) / 10000. Max 16x -> Treasury
///      maxWinMultiplier must be >= 16 and maxPayout must cover wager * 16.
contract Plinko is GameBase {
    struct Drop {
        address player;
        uint256 wager;
        bytes32 treasuryBetId;
        uint64 placeBlock;
        uint8 rows;
        bool settled;
        uint8 bin;
        uint256 payout;
    }

    mapping(bytes32 => Drop) public drops;

    event DropPlaced(
        bytes32 indexed gameBetId, address indexed player, uint256 wager, uint8 rows
    );
    event DropResolved(
        bytes32 indexed gameBetId,
        address indexed player,
        uint8 bin,
        uint256 multBps,
        uint256 payout
    );
    event DropCancelled(bytes32 indexed gameBetId, address indexed player, uint256 wager);

    constructor(address treasuryAddr, address initialOwner, address trustedForwarder_)
        GameBase(treasuryAddr, initialOwner, trustedForwarder_)
    {}

    /// @notice Bin multiplier in bps (10000 = 1x). Pure table, medium-risk curve.
    function multBps(uint8 rows, uint8 bin) public pure returns (uint256) {
        if (rows == 8) {
            require(bin <= 8);
            uint256[9] memory t = [
                uint256(56_000),
                uint256(21_000),
                uint256(11_000),
                uint256(10_000),
                uint256(5_000),
                uint256(10_000),
                uint256(11_000),
                uint256(21_000),
                uint256(56_000)
            ];
            return t[bin];
        }
        if (rows == 12) {
            require(bin <= 12);
            uint256[13] memory t = [
                uint256(100_000),
                uint256(30_000),
                uint256(16_000),
                uint256(14_000),
                uint256(11_000),
                uint256(10_000),
                uint256(5_000),
                uint256(10_000),
                uint256(11_000),
                uint256(14_000),
                uint256(16_000),
                uint256(30_000),
                uint256(100_000)
            ];
            return t[bin];
        }
        if (rows == 16) {
            require(bin <= 16);
            uint256[17] memory t = [
                uint256(160_000),
                uint256(90_000),
                uint256(20_000),
                uint256(14_000),
                uint256(14_000),
                uint256(12_000),
                uint256(11_000),
                uint256(10_000),
                uint256(5_000),
                uint256(10_000),
                uint256(11_000),
                uint256(12_000),
                uint256(14_000),
                uint256(14_000),
                uint256(20_000),
                uint256(90_000),
                uint256(160_000)
            ];
            return t[bin];
        }
        revert BadTarget();
    }

    /// @notice Max table multiplier for a row count (cap pre-check at placement).
    function maxMultBps(uint8 rows) public pure returns (uint256) {
        if (rows == 8) return 56_000;
        if (rows == 12) return 100_000;
        if (rows == 16) return 160_000;
        revert BadTarget();
    }

    function drop(uint8 rows, uint256 wager)
        external
        nonReentrant
        whenNotPaused
        returns (bytes32 gameBetId)
    {
        if (wager == 0) revert ZeroWager();
        if (rows != 8 && rows != 12 && rows != 16) revert BadTarget();
        // Fail fast at placement instead of stranding at settle.
        uint256 worst = (wager * maxMultBps(rows)) / 10_000;
        require(worst <= treasury.maxPayout(), "plinko: exceeds maxPayout");
        require(worst <= wager * treasury.maxWinMultiplier(), "plinko: exceeds multiplier");
        bytes32 treasuryBetId;
        (gameBetId, treasuryBetId) = _nextIds(_msgSender());
        drops[gameBetId] = Drop({
            player: _msgSender(),
            wager: wager,
            treasuryBetId: treasuryBetId,
            placeBlock: uint64(_l2BlockNumber()),
            rows: rows,
            settled: false,
            bin: 0,
            payout: 0
        });
        treasury.escrowBet(_msgSender(), wager, treasuryBetId);
        emit DropPlaced(gameBetId, _msgSender(), wager, rows);
    }

    function resolve(bytes32 gameBetId) external nonReentrant whenNotPaused {
        Drop storage d = drops[gameBetId];
        if (d.player == address(0)) revert BetNotFound();
        if (d.settled) revert AlreadySettled();
        _requireResolvable(d.placeBlock);
        d.settled = true;

        uint256 r = _random(d.treasuryBetId, d.placeBlock);
        uint256 rights;
        for (uint8 i; i < d.rows; i++) {
            if (((r >> i) & 1) == 1) rights += 1;
        }
        uint8 bin = uint8(rights);
        uint256 mult = multBps(d.rows, bin);
        uint256 payout = (d.wager * mult) / 10_000;
        d.bin = bin;
        d.payout = payout;
        treasury.settleBet(d.treasuryBetId, payout);
        emit DropResolved(gameBetId, d.player, bin, mult, payout);
    }

    function refund(bytes32 gameBetId) external nonReentrant {
        Drop storage d = drops[gameBetId];
        if (d.player == address(0)) revert BetNotFound();
        if (d.settled) revert AlreadySettled();
        if (_msgSender() != d.player && _msgSender() != owner()) revert NotBetOwner();
        if (_msgSender() != owner() && _l2BlockNumber() <= d.placeBlock + REFUND_TIMEOUT_BLOCKS) {
            revert RefundTooEarly();
        }
        d.settled = true;
        treasury.cancelBet(d.treasuryBetId);
        emit DropCancelled(gameBetId, d.player, d.wager);
    }
}
