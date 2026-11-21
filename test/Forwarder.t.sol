// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {CasinoToken} from "../contracts/CasinoToken.sol";
import {Treasury} from "../contracts/Treasury.sol";
import {CoinFlip} from "../contracts/games/CoinFlip.sol";
import {TrustedForwarder} from "../contracts/TrustedForwarder.sol";

contract ForwarderTest is Test {
    CasinoToken token;
    Treasury treasury;
    CoinFlip flip;
    TrustedForwarder forwarder;
    address owner = address(0xBEEF);
    address player = address(0xCAFE);
    uint256 sessionPk = 0x1234;

    function setUp() public {
        vm.startPrank(owner);
        token = new CasinoToken(owner);
        treasury = new Treasury(
            address(token), owner, 1e15, 1_000_000 * 1e18, 10_000_000 * 1e18, 10, 5_000_000 * 1e18
        );
        forwarder = new TrustedForwarder();
        flip = new CoinFlip(address(treasury), owner, address(forwarder));
        treasury.authorizeGame(address(flip));
        token.setTreasury(address(treasury));
        token.transfer(address(treasury), 1_000_000 * 1e18);
        vm.stopPrank();
        vm.deal(player, 1 ether);
        // Fund player via owner transfer (owner holds supply).
        vm.prank(owner);
        token.transfer(player, 10_000 * 1e18);
        vm.prank(player);
        token.approve(address(treasury), type(uint256).max);
    }

    function _sign(address session, bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sessionPk, digest);
        // ECDSA.recover with eth-signed prefix: vm.sign signs the raw digest;
        // the forwarder wraps with toEthSignedMessageHash, so sign the wrapped hash.
        return abi.encodePacked(r, s, v);
    }

    function test_MetaBetRecordsRealPlayer() public {
        address session = vm.addr(sessionPk);
        uint64 expiry = uint64(block.timestamp + 30 days);
        vm.prank(player);
        forwarder.setSigner(session, expiry);

        bytes memory callData = abi.encodeCall(CoinFlip.flip, (true, uint256(100 * 1e18)));
        uint256 nonce = forwarder.nonces(player);
        bytes32 digest = forwarder.metaDigest(player, address(flip), callData, nonce);
        bytes32 ethDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        bytes memory sig = _sign(session, ethDigest);

        forwarder.executeMetaTransaction(player, address(flip), callData, sig);

        // Player recorded, escrow pulled from player (not relayer/forwarder).
        assertEq(token.balanceOf(player), 10_000 * 1e18 - 100 * 1e18);
        assertEq(forwarder.nonces(player), 1);
    }

    function test_MetaBetReplayReverts() public {
        address session = vm.addr(sessionPk);
        vm.prank(player);
        forwarder.setSigner(session, uint64(block.timestamp + 30 days));
        bytes memory callData = abi.encodeCall(CoinFlip.flip, (true, uint256(100 * 1e18)));
        bytes32 digest = forwarder.metaDigest(player, address(flip), callData, 0);
        bytes32 ethDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        bytes memory sig = _sign(session, ethDigest);
        forwarder.executeMetaTransaction(player, address(flip), callData, sig);
        vm.expectRevert();
        forwarder.executeMetaTransaction(player, address(flip), callData, sig);
    }

    function test_MetaBetWithoutSessionReverts() public {
        bytes memory callData = abi.encodeCall(CoinFlip.flip, (true, uint256(100 * 1e18)));
        vm.expectRevert();
        forwarder.executeMetaTransaction(player, address(flip), callData, hex"");
    }
}
