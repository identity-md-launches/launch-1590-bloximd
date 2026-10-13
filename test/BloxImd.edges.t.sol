// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BloxImd} from "../src/BloxImd.sol";

/// @notice Edge inputs and property tests that `test/BloxImd.t.sol` does not pin: one wei, the
///         exact boundary of a balance or allowance, the same call twice, approvals that overwrite,
///         `transferFrom` by the owner itself, round-trips, and the ERC-20 behaviours a launch
///         relies on (no fee, no hook, no exemption) checked as properties over random inputs.
/// forge-config: default.fuzz.runs = 1000
contract BloxImdEdgesTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    BloxImd token;

    function setUp() public {
        vm.prank(deployer);
        token = new BloxImd();
    }

    // ---------------------------------------------------------------- supply boundaries

    function test_supplyFitsInUint96AndUint128() public view {
        // Many pool and vesting contracts pack balances; the supply must not overflow them.
        assertLe(token.totalSupply(), type(uint96).max);
        assertLe(token.totalSupply(), type(uint128).max);
    }

    function test_supplyIsExactlyTenToThe27() public view {
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.totalSupply() % 10 ** 18, 0);
    }

    function test_oneWeiTransfersAndTheLastWeiLeaves() public {
        vm.startPrank(deployer);
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertTrue(token.transfer(alice, SUPPLY - 1));
        vm.stopPrank();
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);

        // The emptied deployer cannot send even one wei.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferExactlyBalancePlusOneReverts() public {
        vm.prank(deployer);
        token.transfer(alice, 7);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 7, 8));
        token.transfer(bob, 8);
        // The boundary itself succeeds.
        vm.prank(alice);
        assertTrue(token.transfer(bob, 7));
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transferMaxUint256Reverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
    }

    // ---------------------------------------------------------------- the same call twice

    function test_sameTransferTwiceMovesTwice() public {
        vm.startPrank(deployer);
        token.transfer(alice, 10e18);
        token.transfer(alice, 10e18);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 20e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 20e18);
    }

    function test_secondTransferOfWholeBalanceReverts() public {
        vm.startPrank(deployer);
        token.transfer(alice, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, 0, SUPPLY));
        token.transfer(alice, SUPPLY);
        vm.stopPrank();
    }

    function test_sameApproveTwiceIsIdempotent() public {
        vm.startPrank(deployer);
        token.approve(alice, 5e18);
        token.approve(alice, 5e18);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 5e18, "approve added instead of setting");
    }

    function test_transferFromTwiceExhaustsAllowanceExactly() public {
        vm.prank(deployer);
        token.approve(alice, 10e18);
        vm.startPrank(alice);
        token.transferFrom(deployer, bob, 5e18);
        token.transferFrom(deployer, bob, 5e18);
        assertEq(token.allowance(deployer, alice), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 10e18);
    }

    // ---------------------------------------------------------------- approvals

    function test_approveOverwritesNotAdds() public {
        vm.startPrank(deployer);
        token.approve(alice, 5e18);
        token.approve(alice, 3e18);
        assertEq(token.allowance(deployer, alice), 3e18);
        token.approve(alice, 0);
        assertEq(token.allowance(deployer, alice), 0);
        vm.stopPrank();
    }

    function test_approveEmitsApproval() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, alice, 42);
        vm.prank(deployer);
        token.approve(alice, 42);
    }

    function test_approveDoesNotMoveBalance() public {
        vm.prank(deployer);
        token.approve(alice, SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_approveCanExceedBalanceButSpendCannot() public {
        vm.prank(deployer);
        token.transfer(alice, 1e18);
        vm.prank(alice);
        token.approve(bob, SUPPLY);
        assertEq(token.allowance(alice, bob), SUPPLY);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1e18, 1e18 + 1));
        token.transferFrom(alice, carol, 1e18 + 1);
    }

    function test_allowanceOfZeroSpenderIsZeroAndUnusable() public view {
        assertEq(token.allowance(deployer, address(0)), 0);
        assertEq(token.allowance(address(0), deployer), 0);
    }

    function test_transferFromDoesNotEmitApproval() public {
        vm.prank(deployer);
        token.approve(alice, 10e18);
        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(deployer, bob, 4e18);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "transferFrom should emit exactly one event");
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
    }

    function test_maxMinusOneAllowanceIsDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max - 1);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, alice), type(uint256).max - 2);
    }

    // ---------------------------------------------------------------- transferFrom edges

    /// @dev Being the owner does not waive the allowance: `transferFrom(self, ...)` needs a
    ///      self-approval like any other spender.
    function test_ownerNeedsSelfAllowanceForTransferFrom() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1e18));
        token.transferFrom(deployer, alice, 1e18);

        vm.startPrank(deployer);
        token.approve(deployer, 1e18);
        assertTrue(token.transferFrom(deployer, alice, 1e18));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1e18);
        assertEq(token.allowance(deployer, deployer), 0);
    }

    function test_transferFromToZeroAddressRevertsEvenWithAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 1e18);
        assertEq(token.allowance(deployer, alice), 1e18, "a reverted transferFrom consumed allowance");
    }

    function test_transferFromZeroAddressReverts() public {
        // Nobody holds an allowance from address(0), so the allowance check fires first.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(0), alice, 1);
    }

    function test_transferFromZeroAmountNeedsNoAllowance() public {
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 0));
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferFromOwnerToOwnerKeepsBalanceAndSpendsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 3e18);
        vm.prank(alice);
        token.transferFrom(deployer, deployer, 3e18);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.allowance(deployer, alice), 0);
    }

    // ---------------------------------------------------------------- the launch's flows

    /// @dev The launch sends to a contract (the distributor, the pool manager) and expects every
    ///      wei to arrive: no fee, no hook, no exemption logic, including when the receiver is a
    ///      contract or the token itself.
    function test_transfersToContractsArriveWhole() public {
        address someContract = address(new Sink());
        vm.startPrank(deployer);
        assertTrue(token.transfer(someContract, 123_456_789));
        assertTrue(token.transfer(address(token), 1));
        vm.stopPrank();
        assertEq(token.balanceOf(someContract), 123_456_789);
        // Tokens sent to the token itself are simply held there: no recovery path exists (README).
        assertEq(token.balanceOf(address(token)), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_tenPercentSwarmShareIsExact() public {
        uint256 swarm = (SUPPLY * 1_000) / 10_000;
        assertEq(swarm, 100_000_000e18);
        vm.prank(deployer);
        token.transfer(alice, swarm);
        assertEq(token.balanceOf(alice), swarm);
        vm.prank(alice);
        token.transfer(bob, swarm);
        assertEq(token.balanceOf(bob), swarm);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_twoDeploymentsAreIndependent() public {
        vm.prank(alice);
        BloxImd other = new BloxImd();
        vm.prank(deployer);
        token.transfer(bob, 1e18);
        assertEq(other.balanceOf(bob), 0);
        assertEq(other.balanceOf(alice), SUPPLY);
        assertEq(other.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_noStorageSettersExist() public {
        string[6] memory signatures = [
            "setFee(uint256)",
            "setTax(uint256)",
            "setExempt(address,bool)",
            "excludeFromFee(address)",
            "setMaxTx(uint256)",
            "renounceOwnership()"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
    }

    // ---------------------------------------------------------------- properties

    /// @dev Round trip: sending and sending back restores both balances exactly.
    function testFuzz_transferRoundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev Additivity: two transfers deliver the same as one transfer of their sum.
    function testFuzz_twoTransfersEqualOne(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        vm.startPrank(deployer);
        token.transfer(alice, a);
        token.transfer(alice, b);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), a + b);
        assertEq(token.balanceOf(deployer), SUPPLY - a - b);
    }

    /// @dev Any transfer among three holders keeps the three balances summing to the supply.
    function testFuzz_threeWayConservation(uint256 toAlice, uint256 toBob, uint256 aliceToBob) public {
        toAlice = bound(toAlice, 0, SUPPLY);
        toBob = bound(toBob, 0, SUPPLY - toAlice);
        aliceToBob = bound(aliceToBob, 0, toAlice);
        vm.startPrank(deployer);
        token.transfer(alice, toAlice);
        token.transfer(bob, toBob);
        vm.stopPrank();
        vm.prank(alice);
        token.transfer(bob, aliceToBob);
        assertEq(token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
        assertEq(token.balanceOf(bob), toBob + aliceToBob);
    }

    /// @dev Whatever is sent to any non-zero address arrives whole: no fee, no rounding.
    function testFuzz_receiverGetsExactlyWhatWasSent(address to, uint256 amount) public {
        to = address(uint160(bound(uint256(uint160(to)), 1, type(uint160).max)));
        amount = bound(amount, 0, SUPPLY);
        uint256 before = token.balanceOf(to);
        vm.prank(deployer);
        token.transfer(to, amount);
        if (to == deployer) {
            assertEq(token.balanceOf(to), SUPPLY);
        } else {
            assertEq(token.balanceOf(to), before + amount);
            assertEq(token.balanceOf(deployer), SUPPLY - amount);
        }
    }

    /// @dev A transfer to the zero address reverts for any amount, including zero.
    function testFuzz_zeroReceiverAlwaysReverts(uint256 amount) public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
    }

    /// @dev `approve` stores exactly the value given for any non-zero spender, and overwrites.
    function testFuzz_approveStoresExactly(address spender, uint256 first, uint256 second) public {
        spender = address(uint160(bound(uint256(uint160(spender)), 1, type(uint160).max)));
        vm.startPrank(deployer);
        token.approve(spender, first);
        assertEq(token.allowance(deployer, spender), first);
        token.approve(spender, second);
        assertEq(token.allowance(deployer, spender), second);
        vm.stopPrank();
    }

    /// @dev A spend by `transferFrom` decrements a finite allowance by exactly the amount and leaves
    ///      an infinite one alone; the allowance after a spend is never larger than before.
    function testFuzz_allowanceAfterSpend(uint256 allowed, uint256 spent) public {
        allowed = bound(allowed, 0, type(uint256).max);
        spent = bound(spent, 0, allowed < SUPPLY ? allowed : SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        token.transferFrom(deployer, bob, spent);
        uint256 after_ = token.allowance(deployer, alice);
        assertLe(after_, allowed);
        if (allowed == type(uint256).max) assertEq(after_, allowed);
        else assertEq(after_, allowed - spent);
        assertEq(token.balanceOf(bob), spent);
    }

    /// @dev A failed call changes nothing: balance, allowance and supply are identical before and
    ///      after a reverted `transferFrom`.
    function testFuzz_revertedTransferFromIsAtomic(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        amount = bound(amount, allowed + 1, type(uint256).max);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        (bool ok,) = address(token).call(abi.encodeCall(token.transferFrom, (deployer, bob, amount)));
        assertFalse(ok);
        assertEq(token.allowance(deployer, alice), allowed);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev No caller, with any calldata that is not a real ERC-20 call, can change the supply.
    function testFuzz_unknownSelectorsNeverChangeSupply(address caller, bytes4 selector, bytes memory args) public {
        bytes4[9] memory known = [
            IERC20.transfer.selector,
            IERC20.transferFrom.selector,
            IERC20.approve.selector,
            IERC20.totalSupply.selector,
            IERC20.balanceOf.selector,
            IERC20.allowance.selector,
            bytes4(keccak256("name()")),
            bytes4(keccak256("symbol()")),
            bytes4(keccak256("decimals()"))
        ];
        bool isKnown = selector == token.TOTAL_SUPPLY.selector || selector == token.DECIMALS.selector;
        for (uint256 i = 0; i < known.length && !isKnown; i++) {
            isKnown = selector == known[i];
        }
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        if (!isKnown) {
            assertFalse(ok, "an unknown selector was accepted");
            assertEq(token.balanceOf(deployer), SUPPLY, "an unknown selector moved a balance");
        }
        assertEq(token.totalSupply(), SUPPLY);
    }
}

contract Sink {}
