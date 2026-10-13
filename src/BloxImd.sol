// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title BloxImd (BLOX)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 BLOX (18 decimals) is minted
///         once, in the constructor, to the deployer. Nothing can mint afterwards.
/// @dev Deliberately minimal: no owner, no minter, no pause, no blacklist, no fee on transfer, no
///      hooks. The contract keeps no privileged role of any kind, so no hand can move or freeze a
///      holder's balance, and the supply can never grow. The constructor takes no arguments and
///      calls no other contract, so the creation code deploys on an empty chain and under CREATE2.
///
///      In the IdentityMD launch the deployer is the ProjectFactory, which receives the supply and
///      pays it out (swarm share, pool seed, remainder). See README.md.
contract BloxImd is ERC20 {
    /// @notice Number of decimals, as `decimals()` returns.
    uint8 public constant DECIMALS = 18;

    /// @notice The whole supply in minor units: 1,000,000,000 * 10^18.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(DECIMALS);

    /// @notice Mints the whole supply to the deployer (`msg.sender`).
    constructor() ERC20("BloxImd", "BLOX") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
