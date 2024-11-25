# Swap + Bridge Router

End users (EOAs) cannot call Uniswap v4 PoolManager directly.

In our tests, we've been routing calls through various different router contracts.

-> PoolSwapTest
-> PoolModifyLiquidityTest

Swapping => UniversalRouter
Modifying Liquidity => NFT Position Manager (LP NFTs to end users)

We're gonna build our own swap router.

## Idea

We're going to build a swap router that integrates with Optimism's native bridge contracts.

User requests a swap for A to B, and they can optionally choose to have B bridged over to Optimism instead of getting it on L1.

Simplified proof-of-concept for building something like Squid Router essentially.

One of two things:

1. Take money on chain 1, swap it, bridge output tokens to Chain 2
2. OR, take money on chain 1, bridge to chain 2, and swap over there

> NOTE: Some of the code we're gonna write today is pretty Optimism-specific stuff. We're gonna skim over that specific knowledge, and focus mostly on the router itself.

## Job of a Router

1. Route the user action over the PM properly (swap parameters)
2. Settle balances with the pool manager at the end
3. Send output tokens to user or bridge them to Optimism if user signaled they want to do that (and if it is possible)

## Mechanism Design

Not all tokens are possible to bridge from L1 to L2

in our contract, we'll maintain a mapping called `l1ToL2TokenAddresses`

USDC on L1 -> 0xabc...
USDC on L2 -> 0xxyz...

If the output token of the swap being requested is NOT part of this mapping, then we cannot bridge to Optimism

adding a new key-value pair to this mapping will be an `ownerOnly` function in our case

Squid Router: they integrate with Axelar's bridge so they basically just use Axelar's mapping of token addresses and only work with tokens that Axelar supports bridging between a given src and dest chain

---

On Sepolia, particularly, there's only two tokens "officially" supported to bridge through the native bridge

1. ETH (native ETH)
2. OUTb (Optimism Useless Token Bridgeable)

## What can we actually test locally

Foundry has a cool feature called network forking.

It allows us to "fork" any public chain locally and run sort of a little replica of it on your computer

we're not gonna deploy our own L1StandardBridge or any of the other Optimism contracts

we're gonna fork the Sepolia testnet, deploy our v4-related contracts, conduct swaps through our router to v4

BUT - a problem with forked networks:

---

Alice intiiates a bridge txn on ETH L1
-> emit some sort of event from the contract

Offchain processor (optimism nodes) are listening for that event
-> they will do their thing and make sure its valid

offchain processor will trigger a transaction on the L2 (OP Sepolia)
-> funds will be sent to the recipietn addres

---

we're gonna write a test that runs locally and tests the events being emitted are valid and as expected

---

we're gonna also write a script that will actualyl interact with sepolia and send a public txn that you can verify after 10-20 minutes that an optimism txn was also created

## Events

1. Topic0

2. Topic1 (?)
3. Topic2 (?)
4. Topic3 (?)

5. Data = abi.encoded version of all the remaining inforamtion

Topic0 = keccak256(event signature)
=> WHICH event is being emitted

`indexed` parameter => easy filtering of events on the node side

Topic1 is optional, and exists if there is at least 1 `indexed` parameter in the event

Topic2 is optional, exists if theres a second `indexed` parameter in the event

Topic3 is optional, exists if theres a third `indexed` parameter in the event

Data is all the other stuff abi encoded together

---

`expectEmit` will ALWAYS check `Topic0`

(`checkTopic1`, `checkTopic2`, `checkTopic3`, `checkData`)
