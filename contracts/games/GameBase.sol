// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Treasury} from "../Treasury.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GameBase — shared plumbing for ZSKazik games
/// @dev Testnet randomness: keccak(treasuryBetId, block.prevrandao, placeBlock),
///      resolvable only in a LATER block (no same-tx outcome manipulation).
///      PRODUCTION MUST REPLACE `_random` with Chainlink VRF: validator-influenced
///      prevrandao is biasable for large payouts. Structure is VRF-ready:
///      swap `_random` source + add fulfillRandomWords callback, keep escrow/settle.
abstract contract GameBase is Ownable2Step, Pausable, ReentrancyGuard {
    Treasury public immutable treasury;
    uint256 public gameNonce;

    /// @notice Refund opens this many blocks after placement (stuck-bet escape).
    uint256 public constant REFUND_TIMEOUT_BLOCKS = 7200;

    error ZeroWager();
    error BetNotFound();
    error AlreadySettled();
    error NotBetOwner();
    error TooEarly();
    error RefundTooEarly();
    error BadTarget();

    constructor(address treasuryAddr, address initialOwner) Ownable(initialOwner) {
        require(treasuryAddr != address(0));
        require(initialOwner != address(0));
        treasury = Treasury(treasuryAddr);
    }

    function _nextIds(address player)
        internal
        returns (bytes32 gameBetId, bytes32 treasuryBetId)
    {
        gameNonce += 1;
        gameBetId = keccak256(abi.encode(address(this), player, gameNonce, block.number));
        treasuryBetId = keccak256(abi.encode(address(this), gameBetId));
    }

    function _random(bytes32 treasuryBetId, uint256 placeBlock) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(treasuryBetId, block.prevrandao, placeBlock)));
    }

    function _requireResolvable(uint256 placeBlock) internal view {
        if (block.number <= placeBlock) revert TooEarly();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
