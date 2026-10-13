# BloxImd (BLOX)

A fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum.

| Property | Value |
| --- | --- |
| Solidity contract | `BloxImd` (`src/BloxImd.sol`) |
| `name()` | `BloxImd` |
| `symbol()` | `BLOX` |
| `decimals()` | `18` |
| Total supply | 1,000,000,000 BLOX = `1000000000000000000000000000` minor units |
| Minting | once, in the constructor, all of it to `msg.sender` (the deployer) |
| Constructor arguments | none |
| Owner / admin roles | none |

## Behaviour

- The constructor mints the whole supply to whoever deploys the contract and emits one
  `Transfer(address(0), deployer, supply)` event. There is no other mint path, so the supply can
  never grow.
- Transfers, approvals and `transferFrom` are the plain OpenZeppelin v5 ERC-20 semantics: no fee,
  no burn on transfer, no reflections, no transfer limits, no hooks, no exemptions. Every address
  (the factory, the pool manager, the distributor, an ordinary trader) is treated the same, so the
  launch flows move exactly what they say.
- Failure cases revert with the ERC-6093 custom errors (`ERC20InsufficientBalance`,
  `ERC20InsufficientAllowance`, `ERC20InvalidReceiver`, `ERC20InvalidSpender`).
- There is no owner, minter, pauser, blacklist, freeze, seize, `burnFrom` or upgrade mechanism. The
  contract has no `receive`/`fallback`, so it rejects ETH and every unknown selector.
- The runtime code contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`, and no library with
  public or external functions, so the bytecode is fully linked and deployable as built.

## Assumptions

- The brief names a token with a fixed supply minted once to the deployer and no other transfer
  rules. Nothing beyond standard ERC-20 was added, since anything else (owner, burn, tax, pause)
  would be a power the brief did not ask for.
- "Deployer" is the address that executes the creation code. On the IdentityMD launch that is the
  ProjectFactory, which receives the full supply and distributes it (see below). In the deploy
  script it is the broadcasting signer.
- The constructor does not call any other contract and takes no arguments, so it deploys on an
  empty chain and under CREATE2 at an address that depends only on the factory, the salt and the
  creation code.

## Deployment parameters

### IdentityMD launch (how this token actually goes live)

These values are decided by the launch and copied into the manifest by the manifest step. They are
listed here for the record only; this repository does not write `launch.json`.

| Parameter | Value |
| --- | --- |
| Chain | Ethereum (chain id 1) |
| Token contract | `BloxImd`, constructor args: none |
| `token.totalSupply` | `1000000000000000000000000000` |
| `token.decimals` | `18` |
| Paired currency | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| Pool fee | `12500` (1.25%) |
| Tick spacing | `60` |
| Initial price (provenance) | `79228162514264337593543950336` |
| `economics.poolBps` | `8000` |
| `economics.initialMarketCapWei` | `2500000000000000000000` (2,500 IMD for the whole supply) |
| `economics.remainderTo` | `0xd380a8b40fcea7c0a699ff0d8232a264b37a2f9f` |
| Application contracts | none |

Flow of the supply at launch, all performed by the factory from the balance the constructor minted
to it:

1. 10% to the launch's MerkleDistributor (the swarm's share).
2. 80% seeds the single-sided Uniswap v4 pool against IMD at the price derived from the 2,500 IMD
   opening cap.
3. The remaining 10% is forwarded to `economics.remainderTo`.

Because the token has no exemptions and no fee, each of these transfers delivers exactly the amount
sent.

### Standalone deployment (forks, other chains, local testing)

`script/DeployBloxImd.s.sol` deploys the token with `new BloxImd()`; the broadcasting signer
receives the whole supply. There is no configuration. The script reads no environment variables,
and the tests call `deploy()` directly.

```sh
forge script script/DeployBloxImd.s.sol:DeployBloxImd --rpc-url <RPC> --broadcast --account <keystore>
```

This assignment does not deploy or broadcast anything; the IdentityMD deployer launches the
attested bytecode through the factory.

## After launch

There is nothing to set. The token has no owner-settable storage, no configurable addresses and no
administrative functions.

## Operational responsibilities

- **The supply holder is whoever deployed.** On the launch that is the factory, which pays out the
  whole supply during the launch transaction. For a standalone deployment the signer holds all of
  it and is responsible for distributing it and for custody of that key.
- **No recovery powers exist.** Tokens sent to a wrong address, to the token contract itself or to
  a contract that cannot move them are lost. There is no pause and no freeze, by design.
- **No upgrade path.** The contract is immutable. Any change means a new token.
- **Explorer verification** is the deployer's task after launch (`forge verify-contract` with this
  repository's `foundry.toml` settings: solc 0.8.26, optimizer on with 200 runs, EVM version
  `cancun`, `bytecode_hash = "none"`).
- **Independent review.** Passing tests are not an audit. The token is a thin wrapper over
  OpenZeppelin's audited ERC-20, but the launch policy still expects a separate adversarial review
  by an independent contributor before release.

## Repository layout

```
foundry.toml                 solc 0.8.26 pinned, bytecode_hash = "none", no ffi, no fs access
src/BloxImd.sol              the token
script/DeployBloxImd.s.sol   reviewable deploy script (deploy() is tested directly)
test/BloxImd.t.sol           unit, failure, fuzz and launch-flow tests
lib/forge-std                vendored forge-std v1.9.7 (src only, plain files)
lib/openzeppelin-contracts   vendored OpenZeppelin Contracts v5.1.0 (contracts only, plain files)
```

Dependencies are committed as ordinary files, not git submodules, so the project builds offline.

## Building and testing

```sh
forge build
forge test
forge fmt --check
```

The tests cover: metadata; the single constructor mint and its event; that the supply goes to
whoever deploys, including a CREATE2 deployment from a factory contract; successful transfers,
approvals and `transferFrom`; reverts for insufficient balance, insufficient allowance, zero-address
receiver and zero-address spender; that no mint/owner/upgrade/pause/blacklist/freeze/seize call
exists or changes supply or balances, from a stranger or from the deployer; that ETH is rejected;
that the runtime has no `DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT` and fits EIP-170; fuzzed supply
conservation and allowance enforcement; and the deploy script's `deploy()` function.

Tests read no environment variables and do not depend on the calling address, so they run in any
order and in parallel.

## Security notes

Checked against the eth-security reference: no reentrancy surface (no external calls), no
oracle or price logic, no proxy, no delegatecall, no signatures, no privileged roles, exact
18-decimal supply with no floating-point arithmetic, and all inputs validated by OpenZeppelin's
ERC-20 (zero-address checks, balance and allowance checks). Slither and Mythril were not run in this
environment; the Foundry fuzz tests were.
