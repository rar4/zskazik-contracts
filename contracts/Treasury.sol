// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {CasinoToken} from "./CasinoToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ZSKazik Treasury — bankroll + threshold burn above 20M
/// @notice Accounting layer for the casino. Holds ZSKAZIK bankroll, escrows bets
///         from authorized game contracts, pays wins, and keeps the full lost
///         wager. Nothing is burned while the bankroll is at or below
///         burnThreshold (20M ZSK); on settle, only the amount above the
///         threshold is burned, so the bankroll grows steadily up to 20M
///         and any surplus above it is burned instead of accumulating.
/// @dev Games depend on Treasury; Treasury depends only on CasinoToken.
///      Randomness/RTP live in game contracts (use Chainlink VRF, never
///      block.timestamp alone). Treasury only enforces: auth, limits, solvency,
///      no-double-settle, CEI + reentrancy guard.
///
///      Bet lifecycle: escrowBet (locks stake) -> settleBet (win pays / loss keeps)
///      or splitLossDirect (pull+keep in one, no escrow). Stuck escrows (VRF fail,
///      revoked game) are recoverable via cancelBet (game) / emergencyRefundBet
///      (owner -> player, works even while paused).
///      Threshold burn: after a settle, any bankroll above burnThreshold is
///      burned (never below activeWager). Deposits and escrows do not auto-burn
///      — raise burnThreshold first if the bankroll must be funded above it.
contract Treasury is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The ZSKAZIK token (burnable, pausable).
    CasinoToken public immutable token;

    /// @notice Game contracts allowed to escrow/settle (Dice/Plinko/CoinFlip).
    mapping(address => bool) public isGame;

    /// @notice Single bet lifecycle. Escrowed on bet, settled exactly once.
    struct Bet {
        address player;
        uint256 wager;
        bool settled;
    }

    /// @notice betId => Bet. betId must be unique per bet, e.g.
    ///         keccak256(abi.encode(game, player, nonce)).
    mapping(bytes32 => Bet) public bets;

    /// @notice Lifetime stats (indexers/dashboards).
    uint256 public totalWagered;
    uint256 public totalPaidOut;
    uint256 public totalBurnedViaTreasury;
    uint256 public totalRefunded;

    /// @notice Currently escrowed, unsettled stake (bankroll already holds it).
    uint256 public activeWager;
    /// @notice Count of unsettled escrowed bets.
    uint256 public activeBetCount;

    /// @notice Risk caps (owner-set).
    uint256 public minBet;
    uint256 public maxBet;
    uint256 public maxPayout;
    /// @notice Max payout as a multiple of wager (e.g. 100 = 100x). 0 disables wins.
    uint256 public maxWinMultiplier;
    /// @notice Max sum of unsettled wagers. 0 = uncapped (not recommended).
    uint256 public maxTotalExposure;

    /// @notice Bankroll cap for the threshold burn. 20M ZSK (18 decimals).
    /// @dev Below or at this amount nothing is burned on settle; only the
    ///      amount above it is burned. Owner-settable; 0 disables the burn.
    uint256 public burnThreshold;

    // ------------------------------------------------------------------------
    // Errors / events
    // ------------------------------------------------------------------------

    error UnauthorizedGame(address caller);
    error BetAlreadyExists(bytes32 betId);
    error BetNotFound(bytes32 betId);
    error BetAlreadySettled(bytes32 betId);
    error ZeroAmount();
    error ZeroAddress();
    error BelowMinBet(uint256 wager, uint256 minBet);
    error ExceedsMaxBet(uint256 wager, uint256 maxBet);
    error ExceedsMaxPayout(uint256 payout, uint256 maxPayout);
    error ExceedsWinMultiplier(uint256 payout, uint256 maxAllowed);
    error ExceedsTotalExposure(uint256 active, uint256 maxTotalExposure);
    error InsolventBankroll(uint256 payout, uint256 bankroll);
    error WouldLeaveInsolvent(uint256 remaining, uint256 activeWager);

    event GameAuthorized(address indexed game);
    event GameRevoked(address indexed game);
    event LimitsUpdated(
        uint256 minBet, uint256 maxBet, uint256 maxPayout, uint256 maxWinMultiplier, uint256 maxTotalExposure
    );
    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event BetEscrowed(bytes32 indexed betId, address indexed player, uint256 wager);
    event BetSettled(
        bytes32 indexed betId, address indexed player, uint256 wager, uint256 payout, uint256 burned
    );
    event BetCancelled(
        bytes32 indexed betId, address indexed player, uint256 wager, address indexed caller
    );
    event LossSplit(
        bytes32 indexed betId, address indexed player, uint256 wager, uint256 burned, uint256 kept
    );
    event BurnThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event ExcessBurned(uint256 burned, uint256 bankrollAfter);

    modifier onlyGame() {
        if (!isGame[msg.sender]) revert UnauthorizedGame(msg.sender);
        _;
    }

    /// @param tokenAddr Deployed CasinoToken address.
    /// @param initialOwner Multisig that owns pause/limits/game-list. Must not be 0.
    /// @param minBet_ Minimum wager (dust guard).
    /// @param maxBet_ Per-bet wager cap.
    /// @param maxPayout_ Per-bet absolute payout cap.
    /// @param maxWinMultiplier_ Per-bet relative cap (payout <= wager * multiplier).
    /// @param maxTotalExposure_ Cap on sum of unsettled wagers (0 = uncapped).
    constructor(
        address tokenAddr,
        address initialOwner,
        uint256 minBet_,
        uint256 maxBet_,
        uint256 maxPayout_,
        uint256 maxWinMultiplier_,
        uint256 maxTotalExposure_
    ) Ownable(initialOwner) {
        if (tokenAddr == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();
        token = CasinoToken(tokenAddr);
        minBet = minBet_;
        maxBet = maxBet_;
        maxPayout = maxPayout_;
        maxWinMultiplier = maxWinMultiplier_;
        maxTotalExposure = maxTotalExposure_;
        burnThreshold = 20_000_000 * 1e18;
        emit LimitsUpdated(minBet_, maxBet_, maxPayout_, maxWinMultiplier_, maxTotalExposure_);
    }

    // ------------------------------------------------------------------------
    // Admin (multisig only)
    // ------------------------------------------------------------------------

    /// @notice Whitelist a game contract.
    function authorizeGame(address game) external onlyOwner {
        if (game == address(0)) revert ZeroAddress();
        isGame[game] = true;
        emit GameAuthorized(game);
    }

    /// @notice Remove a game contract (instant containment, no token halt).
    /// @dev Existing escrows from that game stay settleable/cancellable so funds
    ///      never strand; use emergencyRefundBet to release them to players.
    function revokeGame(address game) external onlyOwner {
        isGame[game] = false;
        emit GameRevoked(game);
    }

    /// @notice Update all risk caps in one tx.
    function setLimits(
        uint256 minBet_,
        uint256 maxBet_,
        uint256 maxPayout_,
        uint256 maxWinMultiplier_,
        uint256 maxTotalExposure_
    ) external onlyOwner {
        minBet = minBet_;
        maxBet = maxBet_;
        maxPayout = maxPayout_;
        maxWinMultiplier = maxWinMultiplier_;
        maxTotalExposure = maxTotalExposure_;
        emit LimitsUpdated(minBet_, maxBet_, maxPayout_, maxWinMultiplier_, maxTotalExposure_);
    }

    /// @notice Update the threshold-burn cap. 0 disables the threshold burn.
    /// @dev Raise this before funding the bankroll above the current
    ///      threshold, or the excess will be burned on the next settle.
    function setBurnThreshold(uint256 newThreshold) external onlyOwner {
        uint256 oldThreshold = burnThreshold;
        burnThreshold = newThreshold;
        emit BurnThresholdUpdated(oldThreshold, newThreshold);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ------------------------------------------------------------------------
    // Bankroll funding
    // ------------------------------------------------------------------------

    /// @notice Fund the bankroll. Caller must approve Treasury first.
    /// @dev Deliberately NOT pausable: recapitalization must work in incidents.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice One-tx fund via EIP-2612 permit (no prior approve tx).
    function depositWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        if (IERC20(address(token)).allowance(msg.sender, address(this)) < amount) {
            token.permit(msg.sender, address(this), amount, deadline, v, r, s);
        }
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice Owner withdraws surplus bankroll (e.g. profits).
    /// @dev Never touches escrowed stakes: remaining bankroll must cover activeWager.
    function withdraw(address to, uint256 amount) external nonReentrant onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 bank = token.balanceOf(address(this));
        if (amount > bank) revert InsolventBankroll(amount, bank);
        if (bank - amount < activeWager) revert WouldLeaveInsolvent(bank - amount, activeWager);
        IERC20(address(token)).safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }

    /// @notice Live bankroll = token balance of this contract.
    function bankroll() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// @notice Bankroll not covering unsettled escrows.
    function availableBankroll() external view returns (uint256) {
        uint256 bank = token.balanceOf(address(this));
        return bank >= activeWager ? bank - activeWager : 0;
    }

    /// @notice Amount that would be burned now under the threshold rule.
    /// @dev 0 when disabled, at/below threshold, or when activeWager alone
    ///      already exceeds the threshold (escrows are never burned).
    function excessOverThreshold() external view returns (uint256) {
        uint256 threshold = burnThreshold;
        if (threshold == 0) return 0;
        uint256 bank = token.balanceOf(address(this));
        if (bank <= threshold) return 0;
        uint256 floor = threshold > activeWager ? threshold : activeWager;
        return bank > floor ? bank - floor : 0;
    }

    /// @notice Manually burn the amount above burnThreshold (owner only).
    /// @dev Auto-burn already runs on settle; this trims a bankroll that was
    ///      funded above the threshold via deposit. Returns amount burned.
    function burnExcessOverThreshold() external nonReentrant onlyOwner returns (uint256) {
        return _burnExcessOverThreshold();
    }

    /// @dev Burn bankroll above burnThreshold, never below activeWager.
    ///      Returns 0 when disabled or at/below threshold.
    function _burnExcessOverThreshold() internal returns (uint256 burned) {
        uint256 threshold = burnThreshold;
        if (threshold == 0) return 0;
        uint256 bank = token.balanceOf(address(this));
        if (bank <= threshold) return 0;
        uint256 floor = threshold > activeWager ? threshold : activeWager;
        if (bank <= floor) return 0;
        burned = bank - floor;
        totalBurnedViaTreasury += burned;
        token.burn(burned);
        emit ExcessBurned(burned, bank - burned);
    }

    // ------------------------------------------------------------------------
    // Betting lifecycle (games only)
    // ------------------------------------------------------------------------

    /// @notice Pull player stake into escrow. Player must approve (or use permit variant).
    /// @dev One escrow per betId. Wager stays in Treasury until settle/cancel.
    function escrowBet(address player, uint256 wager, bytes32 betId)
        external
        nonReentrant
        onlyGame
        whenNotPaused
    {
        _escrowBet(player, wager, betId);
    }

    /// @notice One-tx escrow via EIP-2612 permit signed by the player.
    function escrowBetWithPermit(
        address player,
        uint256 wager,
        bytes32 betId,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant onlyGame whenNotPaused {
        if (IERC20(address(token)).allowance(player, address(this)) < wager) {
            token.permit(player, address(this), wager, deadline, v, r, s);
        }
        _escrowBet(player, wager, betId);
    }

    function _escrowBet(address player, uint256 wager, bytes32 betId) internal {
        if (player == address(0)) revert ZeroAddress();
        if (wager == 0) revert ZeroAmount();
        if (wager < minBet) revert BelowMinBet(wager, minBet);
        if (wager > maxBet) revert ExceedsMaxBet(wager, maxBet);
        if (bets[betId].player != address(0)) revert BetAlreadyExists(betId);
        if (maxTotalExposure > 0 && activeWager + wager > maxTotalExposure) {
            revert ExceedsTotalExposure(activeWager + wager, maxTotalExposure);
        }

        bets[betId] = Bet({player: player, wager: wager, settled: false});
        totalWagered += wager;
        activeWager += wager;
        activeBetCount += 1;

        IERC20(address(token)).safeTransferFrom(player, address(this), wager);
        // forge-lint: disable-next-line(reentrancy-events)
        emit BetEscrowed(betId, player, wager);
    }

    /// @notice Settle an escrowed bet exactly once.
    /// @param betId Bet created by escrowBet().
    /// @param payout 0 = loss (Treasury keeps full wager); >0 = win (transfer payout).
    /// @dev Payout INCLUDES returned stake (bet 100 at 2x -> payout 200).
    ///      After the payout/keep, any bankroll above burnThreshold is burned
    ///      (never below the remaining activeWager). Below the threshold
    ///      nothing is burned, so the bankroll keeps the full loss.
    ///      CEI: settled + active decremented BEFORE external calls.
    function settleBet(bytes32 betId, uint256 payout)
        external
        nonReentrant
        onlyGame
        whenNotPaused
    {
        Bet storage b = bets[betId];
        if (b.player == address(0)) revert BetNotFound(betId);
        if (b.settled) revert BetAlreadySettled(betId);
        b.settled = true;
        activeWager -= b.wager;
        activeBetCount -= 1;

        if (payout > 0) {
            if (payout > maxPayout) revert ExceedsMaxPayout(payout, maxPayout);
            if (payout > b.wager * maxWinMultiplier) {
                revert ExceedsWinMultiplier(payout, b.wager * maxWinMultiplier);
            }
            uint256 bank = token.balanceOf(address(this));
            if (payout > bank) revert InsolventBankroll(payout, bank);
            totalPaidOut += payout;
            IERC20(address(token)).safeTransfer(b.player, payout);
            uint256 burned = _burnExcessOverThreshold();
            // forge-lint: disable-next-line(reentrancy-events)
            emit BetSettled(betId, b.player, b.wager, payout, burned);
        } else {
            // Loss: Treasury keeps the full wager. Only the amount above
            // burnThreshold is burned; below it nothing is burned.
            uint256 burned = _burnExcessOverThreshold();
            uint256 kept = burned >= b.wager ? 0 : b.wager - burned;
            // forge-lint: disable-next-line(reentrancy-events)
            emit LossSplit(betId, b.player, b.wager, burned, kept);
            // forge-lint: disable-next-line(reentrancy-events)
            emit BetSettled(betId, b.player, b.wager, 0, burned);
        }
    }

    /// @notice Game-initiated cancel: full stake back to player (VRF fail, voided round).
    function cancelBet(bytes32 betId) external nonReentrant onlyGame whenNotPaused {
        Bet storage b = bets[betId];
        if (b.player == address(0)) revert BetNotFound(betId);
        if (b.settled) revert BetAlreadySettled(betId);
        b.settled = true;
        activeWager -= b.wager;
        activeBetCount -= 1;
        totalRefunded += b.wager;
        IERC20(address(token)).safeTransfer(b.player, b.wager);
        // forge-lint: disable-next-line(reentrancy-events)
        emit BetCancelled(betId, b.player, b.wager, msg.sender);
    }

    /// @notice Owner rescue for stranded escrows (revoked/abandoned game).
    /// @dev Returns stake to PLAYER (never to owner). Works while paused; still
    ///      reverts if the TOKEN itself is paused (transfer frozen at token layer).
    function emergencyRefundBet(bytes32 betId) external nonReentrant onlyOwner {
        Bet storage b = bets[betId];
        if (b.player == address(0)) revert BetNotFound(betId);
        if (b.settled) revert BetAlreadySettled(betId);
        b.settled = true;
        activeWager -= b.wager;
        activeBetCount -= 1;
        totalRefunded += b.wager;
        IERC20(address(token)).safeTransfer(b.player, b.wager);
        // forge-lint: disable-next-line(reentrancy-events)
        emit BetCancelled(betId, b.player, b.wager, msg.sender);
    }

    /// @notice No-escrow path: pull stake and keep loss in ONE tx.
    /// @dev For simple games that skip escrow. Requires full allowance.
    ///      Transfers full amount in, keeps it, burns only the amount above
    ///      burnThreshold. Marked settled at creation.
    function splitLossDirect(address player, uint256 amount, bytes32 betId)
        external
        nonReentrant
        onlyGame
        whenNotPaused
    {
        if (player == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount < minBet) revert BelowMinBet(amount, minBet);
        if (amount > maxBet) revert ExceedsMaxBet(amount, maxBet);
        if (bets[betId].player != address(0)) revert BetAlreadyExists(betId);

        bets[betId] = Bet({player: player, wager: amount, settled: true});
        totalWagered += amount;

        IERC20(address(token)).safeTransferFrom(player, address(this), amount);

        uint256 burned = _burnExcessOverThreshold();
        uint256 kept = burned >= amount ? 0 : amount - burned;
        // forge-lint: disable-next-line(reentrancy-events)
        emit LossSplit(betId, player, amount, burned, kept);
        // forge-lint: disable-next-line(reentrancy-events)
        emit BetSettled(betId, player, amount, 0, burned);
    }
}
