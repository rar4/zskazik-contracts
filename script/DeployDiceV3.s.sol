// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Dice} from "../contracts/games/Dice.sol";
import {Treasury} from "../contracts/Treasury.sol";

/// @notice Deploys Dice V3 (roll-over targets 1..99, up to 98x) and swaps it
///         into the Treasury's game registry. Also raises the Treasury
///         maxWinMultiplier to 100 so target 99 (98x) is placeable.
/// @dev Usage: TREASURY=0x… FORWARDER=0x… forge script script/DeployDiceV3.s.sol --rpc-url <RPC> --broadcast
///      Treasury owner must equal the broadcast sender (authorize/setLimits calls).
///      The old Dice is NOT revoked here: revoking a game strands its
///      unsettled escrows (settleBet is onlyGame), and activeWager is global
///      across games. Revoke the old Dice (0xDcCBA84D53BF3daa275f57cA7e81b202892EfC14)
///      in a follow-up once its escrows have settled.
///      Other limits are preserved exactly: minBet 0.001, maxBet 1M,
///      maxPayout 10M, maxTotalExposure 5M.
contract DeployDiceV3 is Script {
    function run() external {
        address treasuryAddr = vm.envAddress("TREASURY");
        address forwarderAddr = vm.envAddress("FORWARDER");
        Treasury treasury = Treasury(treasuryAddr);

        vm.startBroadcast();
        Dice dice = new Dice(treasuryAddr, msg.sender, forwarderAddr);
        treasury.authorizeGame(address(dice));
        treasury.setLimits(1e15, 1_000_000 * 1e18, 10_000_000 * 1e18, 100, 5_000_000 * 1e18);
        vm.stopBroadcast();

        console.log("DiceV3:", address(dice));
        console.log("maxWinMultiplier:", treasury.maxWinMultiplier());
    }
}
