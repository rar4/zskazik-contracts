// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {CasinoToken} from "../contracts/CasinoToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Comprehensive test suite for CasinoToken v2 (ZSKazik / ZSKAZIK).
contract CasinoTokenTest is Test {
    CasinoToken internal token;

    address internal owner;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant OWNER_PK = 0x1234567890abcdef;
    uint256 internal constant FIXED_SUPPLY = 1_000_000_000 * 1e18;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        owner = vm.addr(OWNER_PK);
        token = new CasinoToken(owner);
        // Fund test users from the owner (sole initial holder).
        vm.startPrank(owner);
        token.transfer(alice, 1_000_000 * 1e18);
        token.transfer(bob, 500_000 * 1e18);
        vm.stopPrank();
    }

    // ========================================================================
    // Deployment
    // ========================================================================

    function test_Deployment_Metadata() public view {
        assertEq(token.name(), "ZSKazik");
        assertEq(token.symbol(), "ZSKAZIK");
        assertEq(token.decimals(), 18);
        assertEq(token.version(), "2.0.0");
        assertEq(token.VERSION(), "2.0.0");
        assertEq(token.contractType(), "ZSKAZIK_TOKEN");
        assertEq(token.CONTRACT_TYPE(), "ZSKAZIK_TOKEN");
        assertEq(token.BPS_DENOMINATOR(), 10_000);
        assertEq(token.treasury(), address(0));
    }

    function test_Deployment_FixedSupplyMintedOnce() public view {
        assertEq(token.totalSupply(), FIXED_SUPPLY);
        assertEq(token.initialSupply(), FIXED_SUPPLY);
        assertEq(token.balanceOf(owner), FIXED_SUPPLY - 1_500_000 * 1e18);
        assertEq(token.owner(), owner);
        assertEq(token.totalBurned(), 0);
        assertEq(token.currentSupply(), FIXED_SUPPLY);
        assertEq(token.circulatingSupply(), FIXED_SUPPLY);
        assertEq(token.burnedPercentage(), 0);
        assertEq(token.remainingSupplyPercentage(), 100);
        assertEq(token.burnedBasisPoints(), 0);
        assertEq(token.remainingBasisPoints(), 10_000);
        assertFalse(token.paused());
    }

    function test_Deployment_ZeroOwnerReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CasinoToken(address(0));
    }

    // ========================================================================
    // Fixed supply (no minting, no inflation)
    // ========================================================================

    function test_FixedSupply_TransfersDoNotChangeSupply() public {
        vm.prank(alice);
        token.transfer(bob, 100 * 1e18);
        assertEq(token.totalSupply(), FIXED_SUPPLY);
        assertEq(token.initialSupply(), FIXED_SUPPLY);
    }

    function test_FixedSupply_BurnOnlyDecreases() public {
        uint256 burnAmount = 250_000 * 1e18;
        vm.prank(alice);
        token.burn(burnAmount);
        assertEq(token.totalSupply(), FIXED_SUPPLY - burnAmount);
        // initialSupply is immutable: the ceiling never moves.
        assertEq(token.initialSupply(), FIXED_SUPPLY);
    }

    function test_FixedSupply_NoMintSelector() public {
        // The contract exposes no mint function: any call to mint(bytes) must fail.
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", bob, 1));
        assertFalse(ok);
    }

    // ========================================================================
    // Burn mechanics
    // ========================================================================

    function test_Burn_ReducesBalanceAndSupply() public {
        uint256 amount = 100_000 * 1e18;
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        token.burn(amount);

        assertEq(token.balanceOf(alice), 1_000_000 * 1e18 - amount);
        assertEq(token.totalSupply(), supplyBefore - amount);
        assertEq(token.totalBurned(), amount);
        assertEq(token.currentSupply(), supplyBefore - amount);
        assertEq(token.circulatingSupply(), supplyBefore - amount);
    }

    function test_Burn_EmitsTokensBurned() public {
        uint256 amount = 10 * 1e18;
        vm.expectEmit(true, false, false, true);
        emit CasinoToken.TokensBurned(alice, amount);
        vm.prank(alice);
        token.burn(amount);
    }

    function test_Burn_BurnEntireBalance() public {
        uint256 full = token.balanceOf(bob);
        vm.prank(bob);
        token.burn(full);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalBurned(), full);
    }

    function test_Burn_MoreThanBalanceReverts() public {
        // Cache the balance first: vm.prank only covers the NEXT external call,
        // so reading balanceOf inside the burn() arguments would consume the prank.
        uint256 aliceBal = token.balanceOf(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                alice,
                aliceBal,
                aliceBal + 1
            )
        );
        vm.prank(alice);
        token.burn(aliceBal + 1);
    }

    function test_BurnFrom_WithAllowance() public {
        uint256 amount = 50_000 * 1e18;
        vm.prank(alice);
        token.approve(bob, amount);

        vm.prank(bob);
        token.burnFrom(alice, amount);

        assertEq(token.balanceOf(alice), 1_000_000 * 1e18 - amount);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.totalBurned(), amount);
    }

    function test_BurnFrom_WithoutAllowanceReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1e18)
        );
        vm.prank(bob);
        token.burnFrom(alice, 1e18);
    }

    function test_Burn_AnalyticsPercentages() public {
        // Burn exactly 10% of the initial supply from the owner.
        uint256 tenPercent = FIXED_SUPPLY / 10;
        vm.prank(owner);
        token.burn(tenPercent);

        assertEq(token.burnedPercentage(), 10);
        assertEq(token.remainingSupplyPercentage(), 90);
        assertEq(token.burnedPercentage() + token.remainingSupplyPercentage(), 100);
        assertEq(token.burnedBasisPoints(), 1000);
        assertEq(token.remainingBasisPoints(), 9000);
        assertEq(token.burnedBasisPoints() + token.remainingBasisPoints(), 10_000);
    }

    function test_Burn_BpsGranularity() public {
        // 1M tokens = 0.1% -> rounds to 0% but reads 10 bps. Proves bps fix.
        uint256 amount = 1_000_000 * 1e18;
        vm.prank(alice);
        token.burn(amount);
        assertEq(token.burnedPercentage(), 0);
        assertEq(token.burnedBasisPoints(), 10);
        assertGt(token.burnedBasisPoints(), 0);
    }

    function test_Burn_MultipleBurnsAccumulate() public {
        vm.prank(alice);
        token.burn(1 * 1e18);
        vm.prank(bob);
        token.burn(2 * 1e18);
        assertEq(token.totalBurned(), 3 * 1e18);
    }

    // ========================================================================
    // Treasury / circulating supply (v2 fix)
    // ========================================================================

    function test_Treasury_DefaultZeroCirculatingEqualsTotal() public view {
        assertEq(token.treasury(), address(0));
        assertEq(token.circulatingSupply(), token.totalSupply());
    }

    function test_Treasury_SetAndExclude() public {
        address t = address(0x7EA5);
        vm.prank(owner);
        token.transfer(t, 100_000 * 1e18);

        vm.expectEmit(true, true, false, false);
        emit CasinoToken.TreasuryUpdated(address(0), t);
        vm.prank(owner);
        token.setTreasury(t);

        assertEq(token.treasury(), t);
        assertEq(token.circulatingSupply(), token.totalSupply() - 100_000 * 1e18);
    }

    function test_Treasury_ClearRestores() public {
        address t = address(0x7EA5);
        vm.prank(owner);
        token.setTreasury(t);
        vm.prank(owner);
        token.setTreasury(address(0));
        assertEq(token.circulatingSupply(), token.totalSupply());
    }

    function test_Treasury_NonOwnerReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        token.setTreasury(bob);
    }

    // ========================================================================
    // Pause / unpause (standard OZ events)
    // ========================================================================

    function test_Pause_OwnerCanPauseAndUnpause() public {
        vm.expectEmit(false, false, false, true);
        emit Pausable.Paused(owner);
        vm.prank(owner);
        token.pause();
        assertTrue(token.paused());

        vm.expectEmit(false, false, false, true);
        emit Pausable.Unpaused(owner);
        vm.prank(owner);
        token.unpause();
        assertFalse(token.paused());
    }

    function test_Pause_NonOwnerReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        token.pause();

        vm.prank(owner);
        token.pause();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        token.unpause();
    }

    function test_Pause_TransferRevertsWhilePaused() public {
        vm.prank(owner);
        token.pause();

        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_Pause_TransferFromRevertsWhilePaused() public {
        vm.prank(alice);
        token.approve(bob, 1e18);

        vm.prank(owner);
        token.pause();

        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vm.prank(bob);
        token.transferFrom(alice, bob, 1e18);
    }

    function test_Pause_BurnRevertsWhilePaused() public {
        vm.prank(owner);
        token.pause();

        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vm.prank(alice);
        token.burn(1e18);
    }

    function test_Pause_ApproveStillWorksWhilePaused() public {
        vm.prank(owner);
        token.pause();

        vm.prank(alice);
        token.approve(bob, 42e18);
        assertEq(token.allowance(alice, bob), 42e18);
    }

    function test_Pause_PermitStillWorksWhilePaused() public {
        uint256 pk = 0xBEEF;
        address signer = vm.addr(pk);
        vm.prank(owner);
        token.transfer(signer, 10e18);

        vm.prank(owner);
        token.pause();

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, bob, 5e18, block.timestamp + 1 hours);
        token.permit(signer, bob, 5e18, block.timestamp + 1 hours, v, r, s);
        assertEq(token.allowance(signer, bob), 5e18);
    }

    function test_Pause_UnpauseRestoresTransfers() public {
        vm.prank(owner);
        token.pause();
        vm.prank(owner);
        token.unpause();

        vm.prank(alice);
        token.transfer(bob, 7e18);
        assertEq(token.balanceOf(bob), 500_000 * 1e18 + 7e18);
    }

    // ========================================================================
    // EIP-2612 Permit
    // ========================================================================

    function _signPermit(
        uint256 pk,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        address signer = vm.addr(pk);
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, signer, spender, value, token.nonces(signer), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    function test_Permit_SetsAllowance() public {
        uint256 pk = 0xABCD;
        address signer = vm.addr(pk);
        vm.prank(owner);
        token.transfer(signer, 100e18);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, bob, 25e18, deadline);

        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(signer, bob, 25e18);
        token.permit(signer, bob, 25e18, deadline, v, r, s);

        assertEq(token.allowance(signer, bob), 25e18);
        assertEq(token.nonces(signer), 1);
    }

    function test_Permit_TransferFromAfterPermit() public {
        uint256 pk = 0xABCD;
        address signer = vm.addr(pk);
        vm.prank(owner);
        token.transfer(signer, 100e18);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, bob, 25e18, deadline);
        token.permit(signer, bob, 25e18, deadline, v, r, s);

        vm.prank(bob);
        token.transferFrom(signer, bob, 25e18);
        assertEq(token.balanceOf(bob), 500_000 * 1e18 + 25e18);
    }

    function test_Permit_ExpiredDeadlineReverts() public {
        uint256 pk = 0xABCD;
        address signer = vm.addr(pk);
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, bob, 1e18, deadline);

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(signer, bob, 1e18, deadline, v, r, s);
    }

    function test_Permit_WrongSignerReverts() public {
        uint256 pk = 0xABCD;
        address signer = vm.addr(pk);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, bob, 1e18, deadline);

        // Attacker replays the same signature but claims a different owner.
        // ecrecover over the mismatched struct hash yields an unrelated address,
        // so the call must revert either way.
        bool reverted;
        try token.permit(alice, bob, 1e18, deadline, v, r, s) {
            reverted = false;
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "permit with mismatched owner must revert");
        // The legitimate owner's nonce is untouched.
        assertEq(token.nonces(signer), 0);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_Permit_ReplayReverts() public {
        uint256 pk = 0xABCD;
        address signer = vm.addr(pk);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, bob, 1e18, deadline);
        token.permit(signer, bob, 1e18, deadline, v, r, s);

        // Same signature replayed: the nonce moved to 1, so the recovered
        // signer no longer matches and the call reverts.
        vm.expectRevert();
        token.permit(signer, bob, 1e18, deadline, v, r, s);

        assertEq(token.nonces(signer), 1);
    }

    // ========================================================================
    // Transfers
    // ========================================================================

    function test_Transfer_BasicFlow() public {
        vm.prank(alice);
        token.transfer(bob, 100e18);
        assertEq(token.balanceOf(alice), 1_000_000 * 1e18 - 100e18);
        assertEq(token.balanceOf(bob), 500_000 * 1e18 + 100e18);
    }

    function test_Transfer_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(alice, bob, 5e18);
        vm.prank(alice);
        token.transfer(bob, 5e18);
    }

    function test_Transfer_InsufficientBalanceReverts() public {
        uint256 bobBal = token.balanceOf(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                bob,
                bobBal,
                bobBal + 1
            )
        );
        vm.prank(bob);
        token.transfer(alice, bobBal + 1);
    }

    function test_Transfer_ToZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transfer(address(0), 1e18);
    }

    function test_TransferFrom_BasicFlow() public {
        vm.prank(alice);
        token.approve(bob, 200e18);

        vm.prank(bob);
        token.transferFrom(alice, bob, 150e18);

        assertEq(token.balanceOf(alice), 1_000_000 * 1e18 - 150e18);
        assertEq(token.balanceOf(bob), 500_000 * 1e18 + 150e18);
        assertEq(token.allowance(alice, bob), 50e18);
    }

    function test_TransferFrom_ExceedingAllowanceReverts() public {
        vm.prank(alice);
        token.approve(bob, 10e18);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 10e18, 11e18)
        );
        vm.prank(bob);
        token.transferFrom(alice, bob, 11e18);
    }

    // ========================================================================
    // Approvals
    // ========================================================================

    function test_Approve_SetsAndOverwrites() public {
        vm.prank(alice);
        token.approve(bob, 100e18);
        assertEq(token.allowance(alice, bob), 100e18);

        vm.prank(alice);
        token.approve(bob, 5e18);
        assertEq(token.allowance(alice, bob), 5e18);

        vm.prank(alice);
        token.approve(bob, 0);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_Approve_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(alice, bob, 9e18);
        vm.prank(alice);
        token.approve(bob, 9e18);
    }

    function test_Approve_ZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(alice);
        token.approve(address(0), 1e18);
    }

    // ========================================================================
    // Security edge cases (Ownable2Step)
    // ========================================================================

    function test_Security_TotalBurnedNeverExceedsInitialSupply() public {
        // Cache balances first so pranks apply to the burn() calls, not to balanceOf().
        uint256 aliceBal = token.balanceOf(alice);
        uint256 bobBal = token.balanceOf(bob);
        uint256 ownerBal = token.balanceOf(owner);

        // Burn everything held by all funded accounts.
        vm.prank(alice);
        token.burn(aliceBal);
        vm.prank(bob);
        token.burn(bobBal);
        vm.prank(owner);
        token.burn(ownerBal);

        assertEq(token.totalSupply(), 0);
        assertEq(token.totalBurned(), FIXED_SUPPLY);
        assertEq(token.burnedPercentage(), 100);
        assertEq(token.remainingSupplyPercentage(), 0);
        assertEq(token.burnedBasisPoints(), 10_000);
        assertEq(token.remainingBasisPoints(), 0);
        assertLe(token.totalBurned(), token.initialSupply());
    }

    function test_Security_OwnershipTransferTwoStep() public {
        vm.expectEmit(true, true, false, false);
        emit Ownable2Step.OwnershipTransferStarted(owner, bob);
        vm.prank(owner);
        token.transferOwnership(bob);

        // 2-step: owner unchanged until acceptance (typo-safety fix).
        assertEq(token.owner(), owner);
        assertEq(token.pendingOwner(), bob);

        // Old owner still has authority before acceptance.
        vm.prank(owner);
        token.pause();
        vm.prank(owner);
        token.unpause();

        vm.prank(bob);
        token.acceptOwnership();
        assertEq(token.owner(), bob);

        // Old owner loses pause authority after acceptance.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        token.pause();
    }

    function test_Security_OwnershipTransferWrongAcceptorReverts() public {
        vm.prank(owner);
        token.transferOwnership(bob);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        token.acceptOwnership();
    }

    function test_Security_RenounceFreezesPauseForever() public {
        vm.prank(owner);
        token.renounceOwnership();
        assertEq(token.owner(), address(0));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        token.pause();
    }

    function test_Security_PausedBlocksOwnerToo() public {
        vm.prank(owner);
        token.pause();

        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vm.prank(owner);
        token.transfer(alice, 1e18);
    }

    function testFuzz_TransfersPreserveSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(token) && to != alice);
        amount = bound(amount, 0, token.balanceOf(alice));

        vm.prank(alice);
        token.transfer(to, amount);

        assertEq(token.totalSupply() + token.totalBurned(), token.initialSupply());
    }

    function testFuzz_BurnAccountingHolds(uint256 amount) public {
        amount = bound(amount, 1, token.balanceOf(alice));

        vm.prank(alice);
        token.burn(amount);

        assertEq(token.totalSupply(), token.initialSupply() - token.totalBurned());
        assertEq(token.currentSupply(), token.totalSupply());
        assertEq(token.circulatingSupply(), token.totalSupply());
        // Independent floors: dust burns (e.g. 1 wei) read 0 + 9999.
        assertApproxEqAbs(token.burnedBasisPoints() + token.remainingBasisPoints(), 10_000, 1);
    }
}
