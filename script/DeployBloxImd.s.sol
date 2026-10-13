// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {BloxImd} from "../src/BloxImd.sol";

/// @title DeployBloxImd
/// @notice Reviewable deployment script for BloxImd. The token has no constructor arguments, so
///         there is nothing to configure: whoever broadcasts the deployment receives the supply.
/// @dev On the IdentityMD launch this script is NOT used: the factory deploys the attested creation
///      code itself and receives the supply. The script exists for local forks and for anyone who
///      wants to deploy the same token elsewhere. Tests call `deploy()` directly.
contract DeployBloxImd is Script {
    /// @notice Deploys the token. The caller of the CREATE (the broadcaster, or this contract when
    ///         called from a test) receives the whole supply.
    function deploy() public returns (BloxImd token) {
        token = new BloxImd();
    }

    /// @notice Broadcasts `deploy()` with the signer forge is given on the command line.
    function run() external returns (BloxImd token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
