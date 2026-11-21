// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {TrustedForwarder} from "../contracts/TrustedForwarder.sol";

/// @notice Deploys the ERC-2771 TrustedForwarder (session-key meta-txs).
/// @dev Usage: forge script script/DeployForwarder.s.sol --rpc-url <RPC> --broadcast
contract DeployForwarder is Script {
    function run() external returns (TrustedForwarder) {
        vm.startBroadcast();
        TrustedForwarder forwarder = new TrustedForwarder();
        vm.stopBroadcast();
        console.log("TrustedForwarder:", address(forwarder));
        return forwarder;
    }
}
