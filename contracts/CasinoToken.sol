// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title CasinoToken (ZSKAZIK)
/// @notice Fixed-supply, deflationary ERC20 token forming the base asset layer
///         of the future casino ecosystem (Treasury -> Dice / Plinko / CoinFlip).
/// @dev Token layer ONLY. This contract intentionally contains NO betting logic,
///      treasury accounting, RTP calculations, payouts, randomness, or game mechanics.
///      Those live in future contracts (Treasury.sol, game contracts) which will call
///      into this token via the standard ERC20 interface (transferFrom / burn / burnFrom).
///
///      Deflation model (enforced OFF-chain / in future contracts, not here):
///        Player loses 100 ZSKAZIK -> 50 ZSKAZIK burned + 50 ZSKAZIK sent to Treasury.
///      The token itself only guarantees: fixed mint-once supply, permissionless
///      burning, and owner-controlled emergency pause of transfers.
///
///      v2 fixes vs v1 audit:
///        - Ownable -> Ownable2Step (typo-safe ownership transfer).
///        - Custom _update + custom pause events -> audited ERC20Pausable +
///          standard Pausable Paused/Unpaused events (indexer-compatible).
///        - circulatingSupply() now excludes treasury holdings (honest aggregator math).
///        - Basis-points analytics (10000) alongside legacy 0-100 percent wrappers.
///        - Public VERSION / CONTRACT_TYPE constants (gas-cheap) + compat getters.
///        - Owner-settable treasury with TreasuryUpdated event.
contract CasinoToken is ERC20, ERC20Burnable, ERC20Permit, Ownable2Step, ERC20Pausable {
    // ------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------

    /// @notice Human-readable token name.
    string private constant _TOKEN_NAME = "ZSKazik";

    /// @notice Token symbol.
    string private constant _TOKEN_SYMBOL = "ZSKAZIK";

    /// @notice Fixed total supply minted once in the constructor: 1,000,000,000 ZSKAZIK (18 decimals).
    uint256 public constant FIXED_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice Denominator for basis-points analytics (100% = 10_000 bps).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Contract version for off-chain integrations (gas-cheap constant).
    string public constant VERSION = "2.0.0";

    /// @notice Contract type identifier for off-chain integrations (gas-cheap constant).
    string public constant CONTRACT_TYPE = "ZSKAZIK_TOKEN";

    // ------------------------------------------------------------------------
    // Tokenomics analytics storage
    // ------------------------------------------------------------------------

    /// @notice Supply minted in the constructor. Immutable: supply can never grow past this.
    /// @dev Always equals FIXED_SUPPLY. Kept for off-chain compat; prefer FIXED_SUPPLY on-chain.
    uint256 public immutable initialSupply;

    /// @notice Cumulative amount of ZSKAZIK burned via burn() / burnFrom(). Only ever increases.
    uint256 public totalBurned;

    /// @notice Bankroll / Treasury address excluded from circulatingSupply().
    /// @dev Zero means "no exclusion yet" (circulating == total). Set post-deploy
    ///      via setTreasury() so the token can be deployed directly to a multisig
    ///      owner and the Treasury wired later without a second token deployment.
    address public treasury;

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------

    /// @notice Emitted whenever tokens are burned.
    /// @param account The holder whose tokens were burned.
    /// @param amount The amount burned (18 decimals).
    /// @dev Complements the standard ERC20 Transfer(from, address(0), amount);
    ///      kept for burn-leaderboard indexers that filter on a dedicated topic.
    event TokensBurned(address indexed account, uint256 amount);

    /// @notice Emitted when the circulating-supply exclusion address changes.
    /// @param oldTreasury Previous treasury (address(0) if unset).
    /// @param newTreasury New treasury (address(0) if cleared).
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // NOTE: pause/unpause emit OZ Pausable's standard `Paused` / `Unpaused` events.
    // v1 custom ContractPaused/ContractUnpaused were removed: indexers, explorers
    // and multisig tooling expect the standard events.

    // ------------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------------

    /// @notice Mints the entire fixed supply to the initial owner exactly once.
    /// @dev No mint function exists anywhere else in this contract: supply is
    ///      fixed at construction and can only decrease via burning.
    ///      Treasury is intentionally NOT set here so deployment can go directly
    ///      to a multisig owner in one tx; call setTreasury() after Treasury deploys.
    /// @param initialOwner Receives the full 1,000,000,000 ZSKAZIK supply and
    ///        becomes the owner (pause/unpause authority). Must not be address(0)
    ///        (enforced by Ownable with OwnableInvalidOwner).
    constructor(
        address initialOwner
    )
        ERC20(_TOKEN_NAME, _TOKEN_SYMBOL)
        ERC20Permit(_TOKEN_NAME)
        Ownable(initialOwner)
    {
        initialSupply = FIXED_SUPPLY;
        _mint(initialOwner, FIXED_SUPPLY);
    }

    // ------------------------------------------------------------------------
    // Emergency pause (owner only) + treasury wiring
    // ------------------------------------------------------------------------

    /// @notice Pauses all token transfers (transfer / transferFrom / burn / burnFrom).
    /// @dev Approvals (approve / allowance / permit) keep working while paused so
    ///      users can always revoke allowances during an incident. This is the
    ///      standard ERC20Pausable semantic. Emits Pausable.Paused (no custom event).
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses token transfers.
    /// @dev Emits Pausable.Unpaused. Ownership is 2-step (Ownable2Step): plan
    ///      multisig custody and a public unpause timelock policy off-chain so a
    ///      permit granted during a pause cannot be frontrun at unpause blindly.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Sets/clears the Treasury address excluded from circulatingSupply().
    /// @dev Only owner. Passing address(0) clears the exclusion.
    /// @param newTreasury Treasury/bankroll holder to exclude (or address(0)).
    // forge-lint: disable-next-line(missing-zero-check)
    function setTreasury(address newTreasury) external onlyOwner {
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    // ------------------------------------------------------------------------
    // Tokenomics analytics
    // ------------------------------------------------------------------------

    /// @notice Current live supply. Alias of totalSupply() (kept for compat).
    function currentSupply() external view returns (uint256) {
        return totalSupply();
    }

    /// @notice Circulating supply = totalSupply() minus Treasury holdings.
    /// @dev At deployment (treasury == address(0)) this equals totalSupply().
    ///      Once Treasury is wired, bankroll holdings are excluded so aggregators
    ///      (CMC/CG) see honest circulation. No vesting/lock logic lives here.
    function circulatingSupply() external view returns (uint256) {
        address t = treasury;
        uint256 supply = totalSupply();
        if (t == address(0)) return supply;
        uint256 locked = balanceOf(t);
        return supply >= locked ? supply - locked : 0;
    }

    /// @notice Basis points of the initial supply burned so far (0-10000, integer floor).
    /// @dev Preferred over burnedPercentage(): 1 bps = 0.01%, 1% = 100 bps.
    ///      10M ZSKAZIK = 1% = 100 bps is now visible instead of rounding to 0%.
    function burnedBasisPoints() public view returns (uint256) {
        return (totalBurned * BPS_DENOMINATOR) / initialSupply;
    }

    /// @notice Basis points of the initial supply still in existence (0-10000, floor).
    function remainingBasisPoints() public view returns (uint256) {
        return (totalSupply() * BPS_DENOMINATOR) / initialSupply;
    }

    /// @notice Whole-percent of the initial supply burned so far (0-100, integer division).
    /// @dev Legacy compat wrapper: burnedBasisPoints() / 100. Frontends needing
    ///      precision must use burnedBasisPoints() or totalBurned/initialSupply raw.
    function burnedPercentage() external view returns (uint256) {
        return burnedBasisPoints() / 100;
    }

    /// @notice Whole-percent of the initial supply still in existence (0-100, floor).
    /// @dev Legacy compat wrapper: remainingBasisPoints() / 100. Note bps/percent
    ///      flooring means burnedPercentage()+remainingSupplyPercentage() can read 99
    ///      for dust amounts; use bps sums (== 10000) for exact dashboards.
    function remainingSupplyPercentage() external view returns (uint256) {
        return remainingBasisPoints() / 100;
    }

    /// @notice Contract version string (compat getter for VERSION constant).
    function version() external pure returns (string memory) {
        return VERSION;
    }

    /// @notice Contract type identifier string (compat getter for CONTRACT_TYPE constant).
    function contractType() external pure returns (string memory) {
        return CONTRACT_TYPE;
    }

    // ------------------------------------------------------------------------
    // Internal hooks
    // ------------------------------------------------------------------------

    /// @dev Audited ERC20Pausable path: super._update() enforces whenNotPaused
    ///      (transfers AND burns revert while paused). Burn detection
    ///      (to == address(0), from != address(0)) feeds deflation analytics.
    ///      Approval/permit never touch _update, so they keep working by design.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        super._update(from, to, value);
        if (to == address(0) && from != address(0)) {
            totalBurned += value;
            emit TokensBurned(from, value);
        }
    }
}
