// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {CasinoToken} from "../contracts/CasinoToken.sol";

/// @notice Deploys CasinoToken (ZSKazik) with the entire fixed supply minted to a chosen owner.
/// @dev Usage:
///      INITIAL_OWNER=0xYourMultisig forge script script/DeployCasinoToken.s.sol --rpc-url <RPC> --broadcast
///      If INITIAL_OWNER is unset, falls back to msg.sender (broadcast sender).
///      Deploy directly to a multisig in ONE tx — never deploy to an EOA then transfer.
contract DeployCasinoToken is Script {
    function run() external returns (CasinoToken) {
        address initialOwner = vm.envOr("INITIAL_OWNER", msg.sender);
        require(initialOwner != address(0), "INITIAL_OWNER cannot be zero");
        address treasury = vm.envOr("TREASURY", address(0));

        vm.startBroadcast();
        CasinoToken token = new CasinoToken(initialOwner);
        vm.stopBroadcast();

        // Wire treasury as the owner (broadcast as owner if keys available,
        // otherwise print the follow-up instruction).
        if (treasury != address(0)) {
            console.log("NOTE: call setTreasury() from owner:", initialOwner);
            console.log("Planned treasury:", treasury);
        }

        console.log("ZSKazik deployed at:", address(token));
        console.log("Owner / supply holder:", token.owner());
        console.log("Version:", token.version());
        console.log("Total supply:", token.totalSupply());
        console.log("Treasury (unset until wired):", token.treasury());

        return token;
    }
}
