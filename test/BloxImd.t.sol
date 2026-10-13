// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BloxImd} from "../src/BloxImd.sol";
import {DeployBloxImd} from "../script/DeployBloxImd.s.sol";

/// @notice Stands in for the launch factory: deploys the token through CREATE2 and so becomes
///         `msg.sender` of the constructor, exactly as ProjectFactory will.
contract Create2Deployer {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "create2 failed");
    }
}

contract BloxImdTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    BloxImd token;

    function setUp() public {
        vm.prank(deployer);
        token = new BloxImd();
    }

    // ---------------------------------------------------------------- metadata and supply

    function test_metadata() public view {
        assertEq(token.name(), "BloxImd");
        assertEq(token.symbol(), "BLOX");
        assertEq(token.decimals(), 18);
        assertEq(token.DECIMALS(), 18);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_supplyIsExactlyOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
        assertEq(token.totalSupply() / 10 ** token.decimals(), 1_000_000_000);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        new BloxImd();
    }

    function test_supplyGoesToWhoeverDeploys() public {
        vm.prank(bob);
        BloxImd other = new BloxImd();
        assertEq(other.balanceOf(bob), SUPPLY);
        assertEq(other.balanceOf(deployer), 0);
    }

    /// @dev The launch deploys the creation code through CREATE2 from the factory, with no
    ///      constructor arguments: the factory must end up holding the whole supply.
    function test_create2DeploymentMintsToTheDeployingContract() public {
        Create2Deployer factory = new Create2Deployer();
        bytes memory code = type(BloxImd).creationCode;
        bytes32 salt = bytes32(uint256(42));
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(code)))))
        );
        address deployed = factory.deploy(code, salt);
        assertEq(deployed, predicted, "CREATE2 address is not the predicted one");
        BloxImd launched = BloxImd(deployed);
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
    }

    // ---------------------------------------------------------------- transfers: success

    function test_transferMovesBalanceAndEmits() public {
        uint256 amount = 1_000e18;
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, amount);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWholeBalanceAndZeroAmount() public {
        vm.startPrank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertTrue(token.transfer(bob, 0));
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 5e18));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_approveAndTransferFrom() public {
        uint256 amount = 250e18;
        vm.prank(deployer);
        assertTrue(token.approve(alice, amount));
        assertEq(token.allowance(deployer, alice), amount);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 100e18));
        assertEq(token.balanceOf(bob), 100e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 100e18);
        assertEq(token.allowance(deployer, alice), amount - 100e18);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1e18);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_secondaryHoldersCanTransferFreely() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 4e18));
        vm.prank(bob);
        assertTrue(token.transfer(stranger, 4e18));
        assertEq(token.balanceOf(alice), 6e18);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(stranger), 4e18);
    }

    // ---------------------------------------------------------------- transfers: failure

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1e18, 2e18));
        token.transfer(bob, 2e18);
    }

    function test_transferRevertsFromEmptyAccount() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, stranger, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1e18);
    }

    function test_transferFromWithoutAllowanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1e18));
        token.transferFrom(deployer, alice, 1e18);
    }

    function test_transferFromBeyondAllowanceReverts() public {
        vm.prank(deployer);
        token.approve(alice, 5e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 5e18, 6e18));
        token.transferFrom(deployer, bob, 6e18);
    }

    function test_transferFromBeyondBalanceReverts() public {
        vm.prank(deployer);
        token.transfer(alice, 1e18);
        vm.prank(alice);
        token.approve(bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1e18, 2e18));
        token.transferFrom(alice, stranger, 2e18);
    }

    function test_approveZeroAddressSpenderReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------- no privileged powers

    /// @dev There is no mint, owner, upgrade or minter role: every such call must miss the contract
    ///      entirely (no fallback, so the call fails) and leave supply and balances untouched,
    ///      whether a stranger or the deployer makes it.
    function test_noCallCanIncreaseSupply() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], stranger, type(uint128).max);
            vm.prank(stranger);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(deployer);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(stranger), 0, signatures[i]);
            assertEq(token.balanceOf(deployer), SUPPLY, signatures[i]);
        }
    }

    /// @dev No pause, blacklist, freeze, seize or burnFrom: nothing the deployer calls moves or
    ///      locks a holder's balance, and the holder keeps full control afterwards.
    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        vm.prank(deployer);
        token.transfer(alice, 1_000e18);
        string[13] memory signatures = [
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
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 1_000e18);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 500e18));
        assertEq(token.balanceOf(bob), 500e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_noEtherAccepted() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------- fuzz / invariants

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, amount)
        );
        token.transfer(alice, amount);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 spent) public {
        allowed = bound(allowed, 0, SUPPLY);
        spent = bound(spent, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        if (spent > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowed, spent)
            );
            token.transferFrom(deployer, bob, spent);
        } else {
            assertTrue(token.transferFrom(deployer, bob, spent));
            assertEq(token.balanceOf(bob), spent);
            assertEq(token.allowance(deployer, alice), allowed - spent);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- deploy script

    function test_deployScriptFunctionMintsToItsCaller() public {
        DeployBloxImd script = new DeployBloxImd();
        BloxImd deployed = script.deploy();
        assertEq(deployed.name(), "BloxImd");
        assertEq(deployed.symbol(), "BLOX");
        assertEq(deployed.totalSupply(), SUPPLY);
        // `deploy()` runs `new BloxImd()` inside the script contract, so the script is the deployer.
        assertEq(deployed.balanceOf(address(script)), SUPPLY);
    }
}
