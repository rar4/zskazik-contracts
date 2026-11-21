// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TrustedForwarder — ERC-2771 meta-transaction forwarder with session keys
/// @notice Lets a user authorise a throwaway session key ONCE (setSigner), after
///         which the session key signs bets off-chain (no wallet popup) and a
///         relayer submits them here. The forwarder appends the real user address
///         to the calldata (ERC-2771 suffix), so games see _msgSender() == user
///         even though msg.sender == this forwarder.
/// @dev Signature scheme: session key personal-signs (EIP-191) the bytes32
///      keccak256(abi.encodePacked(user, target, callData, nonce)). The nonce
///      is per-user, incremented on every executed meta-tx (replay protection).
///      Session key holds no funds and can only act through this contract.
contract TrustedForwarder is ReentrancyGuard {
    struct Session {
        address signer;
        uint64 expiry; // unix seconds, 0 = none
    }

    mapping(address => Session) public sessions;
    mapping(address => uint256) public nonces;

    event SignerSet(address indexed user, address indexed signer, uint64 expiry);
    event SignerRevoked(address indexed user);
    event MetaTransactionExecuted(
        address indexed user, address indexed target, uint256 nonce, bool success
    );

    error SessionNotSet(address user);
    error SessionExpired(address user);
    error InvalidSignature(address user);
    error MetaTransactionFailed(address target, bytes reason);
    error ZeroAddress();

    /// @notice Authorise (or replace) the session key for msg.sender.
    /// @param signer Session wallet address (generated in the browser).
    /// @param expiry Unix timestamp after which the session stops working.
    function setSigner(address signer, uint64 expiry) external {
        if (signer == address(0)) revert ZeroAddress();
        if (expiry <= block.timestamp) revert SessionExpired(msg.sender);
        sessions[msg.sender] = Session(signer, expiry);
        emit SignerSet(msg.sender, signer, expiry);
    }

    /// @notice Revoke the session key for msg.sender, effective immediately.
    function revokeSigner() external {
        delete sessions[msg.sender];
        emit SignerRevoked(msg.sender);
    }

    function sessionOf(address user) external view returns (address signer, uint64 expiry) {
        Session storage s = sessions[user];
        return (s.signer, s.expiry);
    }

    function isSessionActive(address user) external view returns (bool) {
        Session storage s = sessions[user];
        return s.signer != address(0) && block.timestamp < s.expiry;
    }

    /// @notice The exact digest the session key must personal-sign.
    function metaDigest(address user, address target, bytes calldata callData, uint256 nonce)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(user, target, callData, nonce));
    }

    /// @notice Execute a session-signed meta-transaction on behalf of `user`.
    /// @param user Real player (funds stay in their wallet; games record them).
    /// @param target Game contract to call.
    /// @param callData Calldata for the game function (without ERC-2771 suffix).
    /// @param signature Personal signature by the authorised session key over
    ///        metaDigest(user, target, callData, nonces[user]).
    function executeMetaTransaction(
        address user,
        address target,
        bytes calldata callData,
        bytes calldata signature
    ) external nonReentrant returns (bytes memory) {
        Session storage s = sessions[user];
        if (s.signer == address(0)) revert SessionNotSet(user);
        if (block.timestamp >= s.expiry) revert SessionExpired(user);
        if (target == address(0)) revert ZeroAddress();

        uint256 nonce = nonces[user];
        bytes32 digest = metaDigest(user, target, callData, nonce);
        address recovered = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(digest), signature);
        if (recovered != s.signer) revert InvalidSignature(user);

        nonces[user] = nonce + 1;

        // ERC-2771: append the real user address as a 20-byte calldata suffix.
        bytes memory suffixed = abi.encodePacked(callData, user);
        (bool success, bytes memory returnData) = target.call(suffixed);
        if (!success) revert MetaTransactionFailed(target, returnData);

        emit MetaTransactionExecuted(user, target, nonce, success);
        return returnData;
    }
}
