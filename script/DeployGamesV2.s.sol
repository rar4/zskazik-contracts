// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {CoinFlip} from "../contracts/games/CoinFlip.sol";
import {Dice} from "../contracts/games/Dice.sol";
import {Treasury} from "../contracts/Treasury.sol";

/// @notice Deploys fixed CoinFlip + Dice (fail-fast payout-cap pre-check at
///         placement) and swaps them into the Treasury's game registry.
/// @dev Usage: TREASURY=0x… forge script script/DeployGamesV2.s.sol --rpc-url <RPC> --broadcast
///      Treasury owner must equal the broadcast sender (authorize/revoke calls).
///      Plinko is unchanged and keeps its existing address/authorization.
///      No active escrows may exist on the old games (check activeWager == 0).
contract DeployGamesV2 is Script {
    function run() external {
        address treasuryAddr = vm.envAddress("TREASURY");
        address forwarderAddr = vm.envAddress("FORWARDER");
        Treasury treasury = Treasury(treasuryAddr);
        require(treasury.activeWager() == 0, "active escrows exist - settle/refund first");

        vm.startBroadcast();
        CoinFlip flip = new CoinFlip(treasuryAddr, msg.sender, forwarderAddr);
        Dice dice = new Dice(treasuryAddr, msg.sender, forwarderAddr);
        treasury.authorizeGame(address(flip));
        treasury.authorizeGame(address(dice));
        treasury.revokeGame(0x22157527B27C4E3174215126c100f66B041cF082);
        treasury.revokeGame(0xe3192207Fa9Da7BdBFfd09E0F01FB49C14E59b04);
        vm.stopBroadcast();

        console.log("CoinFlipV2:", address(flip));
        console.log("DiceV2:", address(dice));
    }
}
