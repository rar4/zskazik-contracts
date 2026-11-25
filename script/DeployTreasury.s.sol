// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Treasury} from "../contracts/Treasury.sol";
import {CasinoToken} from "../contracts/CasinoToken.sol";

/// @notice Deploys Treasury linked to an existing CasinoToken.
/// @dev Usage:
///      CASINO_TOKEN=0xToken INITIAL_OWNER=0xMultisig BURN_THRESHOLD=20000000000000000000000000 \
///      MIN_BET=1000000000000000 MAX_BET=1000000000000000000000000 \
///      MAX_PAYOUT=10000000000000000000000000 WIN_MULT=10 MAX_EXPOSURE=5000000000000000000000000 \
///      forge script script/DeployTreasury.s.sol --rpc-url <RPC> --broadcast
///      Post-deploy (as token owner): token.setTreasury(address(treasury)).
contract DeployTreasury is Script {
    function run() external returns (Treasury) {
        address tokenAddr = vm.envAddress("CASINO_TOKEN");
        require(tokenAddr != address(0), "CASINO_TOKEN required");
        address initialOwner = vm.envOr("INITIAL_OWNER", msg.sender);
        require(initialOwner != address(0), "INITIAL_OWNER cannot be zero");

        uint256 minBet = vm.envOr("MIN_BET", uint256(1e15));
        uint256 maxBet = vm.envOr("MAX_BET", uint256(1_000_000 * 1e18));
        uint256 maxPayout = vm.envOr("MAX_PAYOUT", uint256(10_000_000 * 1e18));
        uint256 winMult = vm.envOr("WIN_MULT", uint256(10));
        uint256 maxExposure = vm.envOr("MAX_EXPOSURE", uint256(5_000_000 * 1e18));

        vm.startBroadcast();
        Treasury treasury = new Treasury(
            tokenAddr, initialOwner, minBet, maxBet, maxPayout, winMult, maxExposure
        );
        uint256 burnThreshold = vm.envOr("BURN_THRESHOLD", uint256(20_000_000 * 1e18));
        if (burnThreshold != treasury.burnThreshold()) {
            treasury.setBurnThreshold(burnThreshold);
        }
        vm.stopBroadcast();

        console.log("Treasury deployed at:", address(treasury));
        console.log("Token:", tokenAddr);
        console.log("Owner:", treasury.owner());
        console.log("minBet:", treasury.minBet());
        console.log("maxBet:", treasury.maxBet());
        console.log("maxPayout:", treasury.maxPayout());
        console.log("maxWinMultiplier:", treasury.maxWinMultiplier());
        console.log("maxTotalExposure:", treasury.maxTotalExposure());
        console.log("burnThreshold:", treasury.burnThreshold());
        console.log("NEXT: token.setTreasury() from token owner:");
        console.log("  token:", tokenAddr);
        console.log("  value:", address(treasury));

        return treasury;
    }
}
