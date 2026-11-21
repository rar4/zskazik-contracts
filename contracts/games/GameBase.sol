// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Treasury} from "../Treasury.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

/// @title GameBase — shared plumbing for ZSKazik games
/// @dev Testnet randomness: keccak(treasuryBetId, block.prevrandao, placeBlock),
///      resolvable only in a LATER block (no same-tx outcome manipulation).
///      PRODUCTION MUST REPLACE `_random` with Chainlink VRF: validator-influenced
///      prevrandao is biasable for large payouts. Structure is VRF-ready:
///      swap `_random` source + add fulfillRandomWords callback, keep escrow/settle.
///      ERC-2771: bets can arrive via TrustedForwarder (session-key meta-tx);
///      _msgSender() then returns the real player, so direct and meta bets are
///      indistinguishable to the game logic below.
abstract contract GameBase is Ownable2Step, Pausable, ReentrancyGuard, ERC2771Context {
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

    constructor(address treasuryAddr, address initialOwner, address trustedForwarder_)
        Ownable(initialOwner)
        ERC2771Context(trustedForwarder_)
    {
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

    // Diamond-inheritance resolution: ERC2771Context already overrides these
    // from Context — GameBase must take the ERC2771 versions explicitly.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address) {
        return super._msgSender();
    }

    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return super._msgData();
    }

    function _contextSuffixLength() internal view override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
    }
}
