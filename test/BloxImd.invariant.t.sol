// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BloxImd} from "../src/BloxImd.sol";

/// @notice Drives the token with random call sequences from a fixed set of actors and keeps ghost
///         books of what every balance and allowance should be. Every handler function bounds its
///         inputs so that the intended call never reverts; the failure paths (over-balance,
///         over-allowance, zero receiver, privileged selectors, ETH) are probed through low-level
///         calls whose outcome is asserted in place and counted for the invariants.
/// @dev The handler never calls `vm.setEnv`, never reads the environment and never prunes runs
///      with `vm.assume`.
contract BloxImdHandler is CommonBase, StdAssertions, StdUtils {
    uint256 public constant SUPPLY = 1_000_000_000e18;

    BloxImd public immutable token;
    address public immutable deployer;

    address[] public actors;
    mapping(address => bool) public isActor;

    // Ghost books: what the contract must report after any sequence.
    mapping(address => uint256) public ghost_balance;
    mapping(address => mapping(address => uint256)) public ghost_allowance;
    mapping(address => uint256) public ghost_received;
    mapping(address => uint256) public ghost_sent;

    // Counters, so the invariant file can check that every path was actually exercised.
    uint256 public calls_transfer;
    uint256 public calls_transferFrom;
    uint256 public calls_approve;
    uint256 public calls_transferToSelf;
    uint256 public calls_revertInsufficientBalance;
    uint256 public calls_revertInsufficientAllowance;
    uint256 public calls_revertZeroReceiver;
    uint256 public calls_revertZeroSpender;
    uint256 public calls_privilegedProbe;
    uint256 public calls_etherProbe;

    // Anything that must never happen.
    uint256 public ghost_privilegedCallsSucceeded;
    uint256 public ghost_etherAccepted;
    uint256 public ghost_transferReturnedFalse;

    string[23] private privilegedSignatures = [
        "mint(address,uint256)",
        "mint(uint256)",
        "mint()",
        "issue(uint256)",
        "setOwner(address)",
        "transferOwnership(address)",
        "upgradeTo(address)",
        "initialize(address)",
        "unpause()",
        "setMinter(address)",
        "pause()",
        "blacklist(address)",
        "blocklist(address)",
        "freeze(address)",
        "freezeAccount(address)",
        "setBlacklist(address,bool)",
        "setBlocked(address,bool)",
        "lock(address)",
        "disableTransfers()",
        "setTransfersEnabled(bool)",
        "burnFrom(address,uint256)",
        "burn(uint256)",
        "seize(address)"
    ];

    constructor(BloxImd token_, address deployer_, uint256 actorCount_) {
        token = token_;
        deployer = deployer_;
        actors.push(deployer_);
        isActor[deployer_] = true;
        for (uint256 i = 1; i < actorCount_; i++) {
            address a = vm.addr(uint256(keccak256(abi.encodePacked("BloxImd actor", i))));
            actors.push(a);
            isActor[a] = true;
        }
        ghost_balance[deployer_] = SUPPLY;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    // ------------------------------------------------------------------ success paths

    /// @dev `transfer` of any amount the sender can afford, including zero and the whole balance.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        if (!ok) ghost_transferReturnedFalse++;

        ghost_balance[from] -= amount;
        ghost_balance[to] += amount;
        ghost_sent[from] += amount;
        ghost_received[to] += amount;
        calls_transfer++;
    }

    /// @dev A self-transfer must be a no-op on the balance. It is tracked separately from
    ///      `transfer` so the invariant on flows sees sent == received for it.
    function transferToSelf(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 0, token.balanceOf(who));
        uint256 before = token.balanceOf(who);

        vm.prank(who);
        bool ok = token.transfer(who, amount);
        if (!ok) ghost_transferReturnedFalse++;
        assertEq(token.balanceOf(who), before, "self-transfer changed the balance");

        ghost_sent[who] += amount;
        ghost_received[who] += amount;
        calls_transferToSelf++;
    }

    /// @dev `approve` overwrites (never adds to) the previous allowance, including to zero and to
    ///      the infinite sentinel.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (infinite) amount = type(uint256).max;

        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        if (!ok) ghost_transferReturnedFalse++;

        ghost_allowance[owner][spender] = amount;
        calls_approve++;
    }

    /// @dev `transferFrom` within both the allowance and the owner's balance. Infinite allowances
    ///      are not decremented; finite ones are, exactly by the amount spent.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 cap = allowed < token.balanceOf(owner) ? allowed : token.balanceOf(owner);
        amount = bound(amount, 0, cap);

        vm.prank(spender);
        bool ok = token.transferFrom(owner, to, amount);
        if (!ok) ghost_transferReturnedFalse++;

        ghost_balance[owner] -= amount;
        ghost_balance[to] += amount;
        ghost_sent[owner] += amount;
        ghost_received[to] += amount;
        if (allowed != type(uint256).max) ghost_allowance[owner][spender] = allowed - amount;
        calls_transferFrom++;
    }

    // ------------------------------------------------------------------ failure paths

    /// @dev Any amount above the balance must revert with `ERC20InsufficientBalance` and move nothing.
    function transferAboveBalanceReverts(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        amount = bound(amount, balance + 1, type(uint256).max);

        vm.prank(from);
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(token.transfer, (to, amount)));
        assertFalse(ok, "transfer above balance did not revert");
        assertEq(
            data,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount),
            "wrong revert for transfer above balance"
        );
        assertEq(token.balanceOf(from), balance, "a reverted transfer moved the sender's balance");
        calls_revertInsufficientBalance++;
    }

    /// @dev Any amount above a finite allowance must revert with `ERC20InsufficientAllowance`.
    ///      When the allowance is infinite the probe approves a finite one first, so the path is
    ///      always exercised.
    function transferFromAboveAllowanceReverts(
        uint256 spenderSeed,
        uint256 ownerSeed,
        uint256 toSeed,
        uint256 allowed,
        uint256 amount
    ) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        allowed = bound(allowed, 0, SUPPLY);
        vm.prank(owner);
        token.approve(spender, allowed);
        ghost_allowance[owner][spender] = allowed;
        calls_approve++;

        amount = bound(amount, allowed + 1, type(uint256).max);
        uint256 ownerBalance = token.balanceOf(owner);

        vm.prank(spender);
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(token.transferFrom, (owner, to, amount)));
        assertFalse(ok, "transferFrom above allowance did not revert");
        assertEq(
            data,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount),
            "wrong revert for transferFrom above allowance"
        );
        assertEq(token.balanceOf(owner), ownerBalance, "a reverted transferFrom moved the owner's balance");
        assertEq(token.allowance(owner, spender), allowed, "a reverted transferFrom changed the allowance");
        calls_revertInsufficientAllowance++;
    }

    /// @dev The zero address can never receive, by `transfer` or by `transferFrom`.
    function transferToZeroReverts(uint256 fromSeed, uint256 amount, bool viaTransferFrom) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        uint256 balance = token.balanceOf(from);

        bool ok;
        bytes memory data;
        if (viaTransferFrom) {
            vm.prank(from);
            token.approve(from, amount);
            ghost_allowance[from][from] = amount;
            calls_approve++;
            vm.prank(from);
            (ok, data) = address(token).call(abi.encodeCall(token.transferFrom, (from, address(0), amount)));
        } else {
            vm.prank(from);
            (ok, data) = address(token).call(abi.encodeCall(token.transfer, (address(0), amount)));
        }
        assertFalse(ok, "transfer to the zero address did not revert");
        assertEq(
            data,
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)),
            "wrong revert for zero receiver"
        );
        assertEq(token.balanceOf(from), balance, "a reverted zero-receiver transfer moved the balance");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        calls_revertZeroReceiver++;
    }

    /// @dev The zero address can never be a spender.
    function approveZeroSpenderReverts(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(token.approve, (address(0), amount)));
        assertFalse(ok, "approve of the zero spender did not revert");
        assertEq(
            data,
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)),
            "wrong revert for zero spender"
        );
        assertEq(token.allowance(owner, address(0)), 0, "the zero spender has an allowance");
        calls_revertZeroSpender++;
    }

    /// @dev No mint, owner, pause, blacklist, freeze, seize, burn or upgrade selector exists; every
    ///      such call, from any actor including the deployer, must fail outright.
    function privilegedProbe(uint256 callerSeed, uint256 targetSeed, uint256 sigSeed, uint256 amount) external {
        address caller = _actor(callerSeed);
        address target = _actor(targetSeed);
        string memory sig = privilegedSignatures[bound(sigSeed, 0, privilegedSignatures.length - 1)];

        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodeWithSignature(sig, target, amount));
        if (ok) ghost_privilegedCallsSucceeded++;
        calls_privilegedProbe++;
    }

    /// @dev The token has no receive or fallback: ETH, with or without calldata, is refused.
    function etherProbe(uint256 callerSeed, uint256 value, bytes calldata junk) external {
        address caller = _actor(callerSeed);
        value = bound(value, 1, 100 ether);
        vm.deal(caller, value);
        vm.prank(caller);
        (bool ok,) = address(token).call{value: value}(junk);
        if (ok) ghost_etherAccepted++;
        calls_etherProbe++;
    }

    // ------------------------------------------------------------------ views for the invariants

    function sumOfActorBalances() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
    }

    function sumOfGhostBalances() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += ghost_balance[actors[i]];
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract BloxImdInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant ACTORS = 6;

    address deployer = makeAddr("deployer");
    BloxImd token;
    BloxImdHandler handler;

    function setUp() public {
        vm.prank(deployer);
        token = new BloxImd();
        handler = new BloxImdHandler(token, deployer, ACTORS);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferToSelf.selector;
        selectors[2] = handler.approve.selector;
        selectors[3] = handler.transferFrom.selector;
        selectors[4] = handler.transferAboveBalanceReverts.selector;
        selectors[5] = handler.transferFromAboveAllowanceReverts.selector;
        selectors[6] = handler.transferToZeroReverts.selector;
        selectors[7] = handler.approveZeroSpenderReverts.selector;
        selectors[8] = handler.privilegedProbe.selector;
        selectors[9] = handler.etherProbe.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Runs once at the end of every sequence: the campaign must actually have driven the
    ///      handler, so the invariants above were checked against real state changes.
    function afterInvariant() public view {
        uint256 driven = handler.calls_transfer() + handler.calls_transferFrom() + handler.calls_approve()
            + handler.calls_transferToSelf() + handler.calls_revertInsufficientBalance()
            + handler.calls_revertInsufficientAllowance() + handler.calls_revertZeroReceiver()
            + handler.calls_revertZeroSpender() + handler.calls_privilegedProbe() + handler.calls_etherProbe();
        assertGt(driven, 0, "the sequence drove nothing");
    }

    /// @notice The supply is fixed at construction and nothing in any sequence changes it.
    function invariant_totalSupplyIsConstant() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    /// @notice Every token is held by one of the actors: what the actors hold sums to the supply,
    ///         so nothing is created, lost, or parked where no actor sent it.
    function invariant_actorBalancesSumToSupply() public view {
        assertEq(handler.sumOfActorBalances(), SUPPLY);
        assertEq(handler.sumOfGhostBalances(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    /// @notice Each balance equals the ghost book: initial holding plus everything received minus
    ///         everything sent, counted by the handler on each successful call.
    function invariant_balancesMatchGhostFlows() public view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address a = handler.actors(i);
            uint256 initial = a == deployer ? SUPPLY : 0;
            assertEq(token.balanceOf(a), handler.ghost_balance(a), "balance differs from ghost balance");
            assertEq(
                token.balanceOf(a) + handler.ghost_sent(a),
                initial + handler.ghost_received(a),
                "balance differs from initial + received - sent"
            );
            assertLe(token.balanceOf(a), SUPPLY, "an actor holds more than the supply");
        }
    }

    /// @notice Nobody ever moves more out than they were given: sent <= initial + received.
    function invariant_noActorSpendsMoreThanItReceived() public view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address a = handler.actors(i);
            uint256 initial = a == deployer ? SUPPLY : 0;
            assertLe(handler.ghost_sent(a), initial + handler.ghost_received(a));
        }
    }

    /// @notice Every allowance equals the ghost book: the last `approve`, minus each finite spend,
    ///         with the infinite sentinel never decremented.
    function invariant_allowancesMatchGhostBook() public view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < n; j++) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghost_allowance(owner, spender));
            }
        }
    }

    /// @notice No privileged selector ever executed, no ETH was ever accepted, and no successful
    ///         ERC-20 call ever returned false.
    function invariant_noPrivilegedPathExists() public view {
        assertEq(handler.ghost_privilegedCallsSucceeded(), 0, "a privileged selector executed");
        assertEq(handler.ghost_etherAccepted(), 0, "the token accepted ETH");
        assertEq(address(token).balance, 0, "the token holds ETH");
        assertEq(handler.ghost_transferReturnedFalse(), 0, "a successful call returned false");
    }

    /// @notice Metadata and code are immutable across any sequence.
    function invariant_metadataAndCodeAreImmutable() public view {
        assertEq(token.name(), "BloxImd");
        assertEq(token.symbol(), "BLOX");
        assertEq(token.decimals(), 18);
        assertGt(address(token).code.length, 0);
    }

    /// @notice The handler is not vacuous: a fixed, scripted sequence through every handler path,
    ///         success and failure alike, runs end to end, so each path is known to be reachable
    ///         by the random campaign above.
    function test_handlerDrivesEveryPath() public {
        handler.transfer(0, 1, 123e18);
        handler.transferToSelf(1, 5e18);
        handler.approve(1, 2, 50e18, false);
        handler.approve(0, 3, 0, true);
        handler.transferFrom(2, 1, 4, 20e18);
        handler.transferFrom(3, 0, 5, 1e18);
        handler.transferAboveBalanceReverts(4, 0, type(uint256).max);
        handler.transferFromAboveAllowanceReverts(2, 1, 3, 10e18, 11e18);
        handler.transferToZeroReverts(0, 1, false);
        handler.transferToZeroReverts(0, 1, true);
        handler.approveZeroSpenderReverts(0, 1);
        for (uint256 i = 0; i < 23; i++) {
            handler.privilegedProbe(i % ACTORS, 1, i, type(uint128).max);
        }
        handler.etherProbe(2, 1 ether, "");
        handler.etherProbe(2, 1 ether, hex"a9059cbb");

        assertEq(handler.calls_transfer(), 1);
        assertEq(handler.calls_transferToSelf(), 1);
        assertEq(handler.calls_approve(), 2 + 1 + 1);
        assertEq(handler.calls_transferFrom(), 2);
        assertEq(handler.calls_revertInsufficientBalance(), 1);
        assertEq(handler.calls_revertInsufficientAllowance(), 1);
        assertEq(handler.calls_revertZeroReceiver(), 2);
        assertEq(handler.calls_revertZeroSpender(), 1);
        assertEq(handler.calls_privilegedProbe(), 23);
        assertEq(handler.calls_etherProbe(), 2);

        invariant_totalSupplyIsConstant();
        invariant_actorBalancesSumToSupply();
        invariant_balancesMatchGhostFlows();
        invariant_noActorSpendsMoreThanItReceived();
        invariant_allowancesMatchGhostBook();
        invariant_noPrivilegedPathExists();
        invariant_metadataAndCodeAreImmutable();
    }
}
