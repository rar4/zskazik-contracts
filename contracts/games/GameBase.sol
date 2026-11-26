// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Treasury} from "../Treasury.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

/// @title GameBase — shared plumbing for ZSKazik games
/// @dev Testnet randomness: keccak(treasuryBetId, randomnessWord, placeBlock),
///      resolvable only in a LATER block (no same-tx outcome manipulation).
///      Randomness word source is chain-dependent (see _randomWord):
///      - Arbitrum: ArbSys.arbBlockHash(l2BlockNumber - 1). block.prevrandao
///        is the constant 1 on Arbitrum Nitro, so it must NOT be used there.
///      - Other chains (Base/OP Stack, local anvil): block.prevrandao.
///      Block numbering is likewise chain-dependent (see _l2BlockNumber):
///      on Arbitrum, block.number is the L1 block number (ticks every ~12s),
///      so placement/resolvability must use the L2 block number from ArbSys
///      or resolve would wait for the next L1 block instead of the next
///      L2 block (250ms). The ArbSys staticcall falls back to block.number
///      where the precompile does not exist, keeping Base/anvil behaviour.
///      PRODUCTION MUST REPLACE `_random` with Chainlink VRF: sequencer-/
///      validator-influenced randomness is biasable for large payouts.
///      Structure is VRF-ready: swap `_random` source + add
///      fulfillRandomWords callback, keep escrow/settle.
///      ERC-2771: bets can arrive via TrustedForwarder (session-key meta-tx);
///      _msgSender() then returns the real player, so direct and meta bets are
///      indistinguishable to the game logic below.
abstract contract GameBase is Ownable2Step, Pausable, ReentrancyGuard, ERC2771Context {
    Treasury public immutable treasury;
    uint256 public gameNonce;

    /// @notice Refund opens this many blocks after placement (stuck-bet escape).
    /// @dev 7200 L2 blocks: ~4h on Base (2s blocks), ~30min on Arbitrum (250ms).
    uint256 public constant REFUND_TIMEOUT_BLOCKS = 7200;

    /// @dev Arbitrum system contract (same address on Arbitrum One/Sepolia).
    address private constant ARB_SYS = 0x0000000000000000000000000000000000000064;

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
        gameBetId = keccak256(abi.encode(address(this), player, gameNonce, _l2BlockNumber()));
        treasuryBetId = keccak256(abi.encode(address(this), gameBetId));
    }

    /// @notice L2 block number: ArbSys on Arbitrum, block.number elsewhere.
    function _l2BlockNumber() internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            ARB_SYS.staticcall(abi.encodeWithSignature("arbBlockNumber()"));
        if (ok && ret.length == 32) return abi.decode(ret, (uint256));
        return block.number;
    }

    /// @notice Randomness word: previous L2 block hash on Arbitrum
    ///       (arbBlockHash), block.prevrandao elsewhere. Both are unknown
    ///       at placement time for a later resolve block and are
    ///       reproducible off-chain for the Plinko path replay.
    function _randomWord() internal view returns (bytes32) {
        uint256 l2Num = _l2BlockNumber();
        if (l2Num > 0) {
            (bool ok, bytes memory ret) = ARB_SYS.staticcall(
                abi.encodeWithSignature("arbBlockHash(uint256)", l2Num - 1)
            );
            if (ok && ret.length == 32) {
                bytes32 h = abi.decode(ret, (bytes32));
                if (h != bytes32(0)) return h;
            }
        }
        return bytes32(block.prevrandao);
    }

    function _random(bytes32 treasuryBetId, uint256 placeBlock) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(treasuryBetId, _randomWord(), placeBlock)));
    }

    function _requireResolvable(uint256 placeBlock) internal view {
        if (_l2BlockNumber() <= placeBlock) revert TooEarly();
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
