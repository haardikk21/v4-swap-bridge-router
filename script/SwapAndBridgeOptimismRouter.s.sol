// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {SwapAndBridgeOptimismRouter, IL1StandardBridge} from "../src/SwapAndBridgeOptimismRouter.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolManager} from "v4-core/PoolManager.sol";

import {Vm} from "forge-std/Test.sol";
import "forge-std/Script.sol";

interface IOUTbToken {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function faucet() external;
}

contract SwapAndBridgeOptimismRouterScript is Script, Deployers {
    // Optimism Bridge Contracts
    IL1StandardBridge public constant l1StandardBridge = IL1StandardBridge(0xFBb0621E0B23b5478B630BD55a5f21f67730B0F1);
    address public constant l2CrossDomainMessenger = 0x4200000000000000000000000000000000000010;

    // OUTb Token
    IOUTbToken OUTbL1Token = IOUTbToken(0x12608ff9dac79d8443F17A4d39D93317BAD026Aa);
    IOUTbToken OUTbL2Token = IOUTbToken(0x7c6b91D9Be155A6Db01f749217d76fF02A7227F2);

    // Periphery Contract
    SwapAndBridgeOptimismRouter poolSwapAndBridgeOptimism;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // NOTE: Currently this doesn't work - because Sepolia has an outdated version of v4-core that is incompatible
        // Once a new deployment exists, update the contract addresses below and it *should* work

        // Sepolia Deployment according to uniswaphooks.com
        manager = PoolManager(payable(0xf7a031A182aFB3061881156df520FE7912A51617));
        modifyLiquidityRouter = PoolModifyLiquidityTest(0x140C64C63c52cE05138E21564b72b0B2Dff9B67f);

        // Deploy custom router
        poolSwapAndBridgeOptimism = new SwapAndBridgeOptimismRouter(manager, l1StandardBridge);

        // Get some OUTb tokens on L1 and approve the routers to use it
        OUTbL1Token.faucet();
        OUTbL1Token.approve(address(poolSwapAndBridgeOptimism), type(uint256).max);
        OUTbL1Token.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Create the OUTb token mapping on the periphery contract
        poolSwapAndBridgeOptimism.addL1ToL2TokenAddress(address(OUTbL1Token), address(OUTbL2Token));

        // Initialize an ETH <> OUTb pool and add some liquidity there
        (key,) = initPool(
            // CurrencyLibrary.NATIVE,
            CurrencyLibrary.ADDRESS_ZERO,
            Currency.wrap(address(OUTbL1Token)),
            IHooks(address(0)),
            3000,
            SQRT_PRICE_1_1
        );

        // Add some liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity{value: 0.1 ether}(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 0.1 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        vm.recordLogs();
        poolSwapAndBridgeOptimism.swap{value: 0.001 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            SwapAndBridgeOptimismRouter.SwapSettings({bridgeTokens: true, recipientAddress: vm.addr(deployerPrivateKey)}),
            ZERO_BYTES
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 messageHash = _getEncodedMessageHashForRelay(logs);

        console.log("Message Hash");
        console.logBytes32(messageHash);
        console.log(
            "Check for message status here: https://sepolia-optimism.etherscan.io/address/0x4200000000000000000000000000000000000007#readProxyContract"
        );

        vm.stopBroadcast();
    }

    function _getEncodedMessageHashForRelay(Vm.Log[] memory logs) internal pure returns (bytes32) {
        Vm.Log memory sentMessageLog;
        Vm.Log memory sentMessageExtensionLog;

        for (uint8 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("SentMessage(address,address,bytes,uint256,uint256)")) {
                sentMessageLog = logs[i];
            }

            if (logs[i].topics[0] == keccak256("SentMessageExtension1(address,uint256)")) {
                sentMessageExtensionLog = logs[i];
            }
        }

        bytes4 relayMessageSelector = 0xd764ad0b;

        address target = address(uint160(uint256(sentMessageLog.topics[1])));
        (address sender, bytes memory message, uint256 messageNonce, uint256 gasLimit) =
            abi.decode(sentMessageLog.data, (address, bytes, uint256, uint256));

        uint256 value = abi.decode(sentMessageExtensionLog.data, (uint256));

        bytes memory encodedMessage =
            abi.encodeWithSelector(relayMessageSelector, messageNonce, sender, target, value, gasLimit, message);
        bytes32 encodedMessageHash = keccak256(encodedMessage);

        return encodedMessageHash;
    }
}
