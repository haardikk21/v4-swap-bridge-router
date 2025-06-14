// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

interface IL1StandardBridge {
    function depositETHTo(
        address _to,
        uint32 _minGasLimit,
        bytes calldata _extraData
    ) external payable;
    function depositERC20To(
        address _l1Token,
        address _l2Token,
        address _to,
        uint256 _amount,
        uint32 _minGasLimit,
        bytes calldata _extraData
    ) external;
}

contract SwapAndBridgeOptimismRouter is Ownable {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    IL1StandardBridge public immutable l1StandardBridge;

    mapping(address l1Token => address l2Token) public l1ToL2TokenAddresses;

    struct CallbackData {
        address sender;
        SwapSettings settings;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    struct SwapSettings {
        bool bridgeTokens;
        address recipientAddress;
    }

    error CallerNotManager();
    error TokenCannotBeBridged();

    constructor(
        IPoolManager _manager,
        IL1StandardBridge _l1StandardBridge
    ) Ownable(msg.sender) {
        manager = _manager;
        l1StandardBridge = _l1StandardBridge;
    }

    function swap(
        PoolKey memory key,
        SwapParams memory params,
        SwapSettings memory settings,
        bytes memory hookData
    ) external payable returns (BalanceDelta delta) {
        // If user requested a bridge of the output tokens
        // we must make sure the output token can be bridged at all
        // otherwise we revert the transaction early
        if (settings.bridgeTokens) {
            Currency l1TokenToBridge = params.zeroForOne
                ? key.currency1
                : key.currency0;

            if (!l1TokenToBridge.isAddressZero()) {
                address l2Token = l1ToL2TokenAddresses[
                    Currency.unwrap(l1TokenToBridge)
                ];
                if (l2Token == address(0)) revert TokenCannotBeBridged();
            }
        }

        // Unlock the pool manager which will trigger a callback
        delta = abi.decode(
            manager.unlock(
                abi.encode(
                    CallbackData(msg.sender, settings, key, params, hookData)
                )
            ),
            (BalanceDelta)
        );

        // Send any ETH left over to the sender
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0)
            CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, ethBalance);
    }

    function unlockCallback(
        bytes calldata rawData
    ) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert CallerNotManager();
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        // Call swap on the PM
        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);

        if (delta.amount0() < 0) {
            data.key.currency0.settle(
                manager,
                data.sender,
                uint256(int256(-delta.amount0())),
                false
            );
        }

        if (delta.amount1() < 0) {
            data.key.currency1.settle(
                manager,
                data.sender,
                uint256(int256(-delta.amount1())),
                false
            );
        }

        if (delta.amount0() > 0) {
            _take(
                data.key.currency0,
                data.settings.recipientAddress,
                uint256(int256(delta.amount0())),
                data.settings.bridgeTokens
            );
        }

        if (delta.amount1() > 0) {
            _take(
                data.key.currency1,
                data.settings.recipientAddress,
                uint256(int256(delta.amount1())),
                data.settings.bridgeTokens
            );
        }

        return abi.encode(delta);
    }

    function _take(
        Currency currency,
        address recipient,
        uint256 amount,
        bool bridgeToOptimism
    ) internal {
        // If not bridging, just send the tokens to the swapper
        if (!bridgeToOptimism) {
            currency.take(manager, recipient, amount, false);
        } else {
            // If we are bridging, take tokens to the router and then bridge to the recipient address on the L2
            currency.take(manager, address(this), amount, false);

            if (currency.isAddressZero()) {
                l1StandardBridge.depositETHTo{value: amount}(recipient, 0, "");
            } else {
                address l1Token = Currency.unwrap(currency);
                address l2Token = l1ToL2TokenAddresses[l1Token];

                IERC20Minimal(l1Token).approve(
                    address(l1StandardBridge),
                    amount
                );
                l1StandardBridge.depositERC20To(
                    l1Token,
                    l2Token,
                    recipient,
                    amount,
                    0,
                    ""
                );
            }
        }
    }

    function addL1ToL2TokenAddress(
        address l1Token,
        address l2Token
    ) external onlyOwner {
        l1ToL2TokenAddresses[l1Token] = l2Token;
    }

    receive() external payable {}
}
