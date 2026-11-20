// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {CoinFlip} from "../contracts/games/CoinFlip.sol";
import {Dice} from "../contracts/games/Dice.sol";
import {Plinko} from "../contracts/games/Plinko.sol";
import {Treasury} from "../contracts/Treasury.sol";

/// @notice Deploys CoinFlip, Dice, Plinko and authorizes them on the Treasury.
/// @dev TREASURY=0x… INITIAL_OWNER=0xMultisig forge script script/DeployGames.s.sol --rpc-url <RPC> --broadcast
///      Treasury owner must equal the broadcast sender (it calls authorizeGame x3).
contract DeployGames is Script {
    function run() external {
        address treasuryAddr = vm.envAddress("TREASURY");
        address initialOwner = vm.envOr("INITIAL_OWNER", msg.sender);
        Treasury treasury = Treasury(treasuryAddr);

        vm.startBroadcast();
        CoinFlip flip = new CoinFlip(treasuryAddr, initialOwner);
        Dice dice = new Dice(treasuryAddr, initialOwner);
        Plinko plinko = new Plinko(treasuryAddr, initialOwner);
        treasury.authorizeGame(address(flip));
        treasury.authorizeGame(address(dice));
        treasury.authorizeGame(address(plinko));
        vm.stopBroadcast();

        console.log("CoinFlip:", address(flip));
        console.log("Dice:", address(dice));
        console.log("Plinko:", address(plinko));
    }
}
