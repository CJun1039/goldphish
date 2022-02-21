pragma solidity ^0.8.0;

import './interfaces/uniswap_v2/IUniswapV2Pair.sol';
import './interfaces/uniswap_v3/callback/IUniswapV3SwapCallback.sol';
import './interfaces/uniswap_v3/IUniswapV3Pool.sol';
import './libraries/uniswap_v3/CallbackValidation.sol';
import './interfaces/IERC20.sol';

contract Shooter is
    IUniswapV3SwapCallback
{

    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    address internal constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    // below deployer is for example purposes; private key = 0xab1179084d3336336d60b2ed654d99a21c2644cadd89fd3034ee592e931e4a77
    address internal constant deployer = 0x23E7D87AFF47ba3D65D7Ab2F8cbc9F1BB3DDD32d;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    constructor() {
        require(msg.sender == deployer);
    }


    /// @notice Transfers tokens from msg.sender to a recipient
    /// @dev Errors with ST if transfer fails
    /// @param token The contract address of the token which will be transferred
    /// @param to The recipient of the transfer
    /// @param value The value of the transfer
    function safeTransfer(
        address token,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'ST');
    }

    function getNextUniswapV2(
        uint256 idx,
        bytes calldata data
    ) pure internal returns (address recipient) {
        while (true)
        {
            require(idx < data.length);
            uint256 rec = uint256(bytes32(data[idx:idx+32]));
            if (rec & (0x1 << 252) == 0)
            {
                // this is a uniswap v2
                recipient = address(uint160(rec));
                break;
            }
            idx += 32;
        }
    }

    function doUniswapV3Swap(
            address exchange,
            uint256 amountOut,
            bool zeroForOne,
            uint8 recipientCode,
            uint256 cdata_idx,
            bytes calldata data
        ) internal {
        // uniswap v3
        // we need to copy the remaining exchange info into memory
        address recipient;
        if (recipientCode == 0x0)
        {
            // send to self
            recipient = address(this);
        }
        else if (recipientCode == 0x1)
        {
            // send to msg.sender
            recipient = msg.sender;
        }
        else
        {
            // send to next uniswap v3 exchange address -- need to scan for it
            recipient = getNextUniswapV2(cdata_idx + 32, data);
        }

        (bool success,) = exchange.call(
            abi.encodeWithSelector(
                IUniswapV3PoolActions.swap.selector,
                recipient,
                zeroForOne,
                -int256(amountOut),
                (
                    zeroForOne
                        ? MIN_SQRT_RATIO + 1
                        : MAX_SQRT_RATIO - 1
                ),
                data[cdata_idx+32:]
            )
        );

        require(success);
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        address repaymentToken;
        address outputToken;
        {
            address token0;
            address token1;
            IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
            token0 = pool.token0();
            token1 = pool.token1();
            uint24 fee = pool.fee();
            CallbackValidation.verifyCallback(
                UNISWAP_V3_FACTORY,
                token0,
                token1,
                fee
            );
            (outputToken, repaymentToken) = amount0Delta < 0
                ? (token0, token1)
                : (token1, token0);
        }

        uint8 recipientCode = 0;
        uint256 cdata_idx = 0;
        while (cdata_idx < data.length)
        {
            uint256 cdataNext = uint256(bytes32(data[cdata_idx:cdata_idx+32]));

            // decode flags
            recipientCode = uint8(cdataNext >> 254);
            bool zeroForOne = (cdataNext & (0x1 << 253)) != 0;
            address exchange = address(uint160(cdataNext));
            uint256 amountOut = (cdataNext >> 160) & 0xfffffffffffffffffffffff;

            if (cdataNext & (0x1 << 252) != 0)
            {
                // broken out to avoid 'stack too deep' error (I guess)
                if (recipientCode == 0x1)
                {
                    // we're paying for the prior uniswap v3 exchange, as gas savings we already had set amountOut to 0
                    // so infer it here
                    amountOut = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
                }
                doUniswapV3Swap(exchange, amountOut, zeroForOne, recipientCode, cdata_idx, data);
                // assume remainder was handled recursively
                break;
            }
            else
            {
                address recipient;
                uint256 requiredInput = 0;

                if (cdata_idx + 64 <= data.length)
                {
                    uint256 maybeExtraData = uint256(bytes32(data[cdata_idx + 32 : cdata_idx + 64]));
                    if (maybeExtraData & uint160(0x00ffffffffffffffffffffffffffffffffffffffff /* leading zero is deliberate */) == 0)
                    {
                        // using extradata mark
                        requiredInput = maybeExtraData >> 160;                        
                        cdata_idx += 32;
                    }
                }
                else
                {
                    // This is the last exchange and we are sending the whole amount to msg.sender; so we can infer the amountOut.
                    // In this case, interpret amountOut field as amountIn
                    if (recipientCode != 0x0)
                    {
                        requiredInput = amountOut;
                        amountOut = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
                    }
                }
                cdata_idx += 32;

                if (requiredInput > 0)
                {
                    if (cdata_idx == 0)
                    {
                        // We are forwarding output from the prior uniswap v3, we already know the token address
                        safeTransfer(WETH, exchange, requiredInput);                        
                    }
                    else
                    {
                        // address neededToken = zeroForOne ? IUniswapV2Pair(exchange).token0() : IUniswapV2Pair(exchange).token1();
                        safeTransfer(
                            WETH, exchange, requiredInput
                        );
                    }
                }

                if (recipientCode == 0x0)
                {
                    // send to self
                    recipient = address(this);
                }
                else if (recipientCode == 0x1)
                {
                    // send to msg.sender
                    recipient = msg.sender;
                }
                else
                {
                    // send to next exchange address directly
                    recipient = address(uint160(bytes20(data[cdata_idx+12:cdata_idx+32])));
                }

                (bool success, ) = exchange.call(
                    abi.encodeWithSelector(
                        IUniswapV2Pair.swap.selector,
                        zeroForOne ? 0 : amountOut,
                        zeroForOne ? amountOut : 0,
                        recipient,
                        new bytes(0)
                    )
                );
                require(success);
            }
        }

        if (recipientCode == 0x0) {
            // must manually forward payment to msg.sender
            int256 neededValue = int256(amount0Delta > 0 ? amount0Delta : amount1Delta);
            safeTransfer(repaymentToken, msg.sender, uint256(neededValue));
        }
    }

    fallback(bytes calldata input) external payable returns (bytes memory) {
        assembly {
            {
                // ensure method sel is 0
                let method_sel := calldataload(0)
                method_sel := shr(244, method_sel)
                if iszero(iszero(method_sel)) { revert(0,0) }
            }

            {
                // ensure only authorized caller
                let msg_sender := caller()
                if iszero(eq(msg_sender, deployer)) { revert(0,0) }
            }

            {
                // load first line
                let input0 := calldataload(0x4)
    
                {
                    // check block target
                    let block_target := shr(240, input0)
                    if iszero(eq(and(number(), 0xffff), block_target)) { revert(0,0) }
                }

                let exchange1 := and(input0, 0xffffffffffffffffffffffffffffffffffffffff)

                // NOTE: memory from 0x80 and on is free for our use, store our call info there
                mstore(0x80, shl(224, 0x128acb08)) // method selector for uniswap v3 swap()

                // compute zeroForOne (easy)
                let zeroForOne := iszero(iszero(and(input0, shl(239, 0x1))))
                mstore(0xa4, zeroForOne)
                
                // store max price (computed from zeroForOne)
                switch zeroForOne
                case 0 {
                    mstore(0xe4, sub(MAX_SQRT_RATIO, 1))
                }
                default {
                    mstore(0xe4, add(MIN_SQRT_RATIO, 1))
                }

                // compute amountIn (may require loading extradata)
                let amountInOriginal := and(shr(160, input0), 0x3fffffffffffffffffff)
                switch amountInOriginal 
                case 0 {
                    // amountIn is actually in extradata
                    let extradata := calldataload(0x24)
                    mstore(0xc4, shr(64, extradata))
                }
                default {
                    // set amountIn
                    mstore(0xc4, amountInOriginal)
                }

                // compute the recipient address, store it in memory too
                switch and(input0, shl(238, 0x1))
                case 0 {
                    // recipient is shooter
                    mstore(0x84, address())
                }
                default {
                    // recipient is next uniswap v2 exchange -- unfortunately, we need to scan calldata for it
                    let cdsize := calldatasize()
                    let i := add(0x24, mul(iszero(amountInOriginal), 0x20)) // account for extradata, if present
                    for { } lt(i, cdsize) { i := add(i, 0x20) } {
                        let line := calldataload(i)
                        if iszero(and(line, shl(252, 0x1))) {
                            // this is the uniswap v2 address we're looking for
                            line := and(line, 0xffffffffffffffffffffffffffffffffffffffff)
                            mstore(0x84, line)
                            break
                        }
                    }
                    if iszero(lt(i, cdsize)) { revert(0,0) }
                }

                // store the bytes calldata data (For callback)
                mstore(0x104, 0xa0)
                // copy the remaining calldata
                {
                    let cdsize := calldatasize()
                    let additionalCdStart := add(0x24, mul(iszero(amountInOriginal), 0x20))
                    let additionalCdLen := sub(cdsize, additionalCdStart)
                    // store the size of data
                    mstore(0x124, additionalCdLen)
                    // copy the extra calldata itself
                    calldatacopy(0x144, additionalCdStart, additionalCdLen)

                    let status := call(
                        gas(), // gas amount
                        exchange1, // recipient
                        0, // value (wei)
                        0x80, // calldata start
                        add(0xc4, additionalCdLen), // calldata len
                        0x80,
                        0x40
                    )
                    if iszero(status) { revert(0,0) }
                }

                if iszero(amountInOriginal) {
                    // see if we do a coinbase xfer
                    let coinbaseXfer := and(calldataload(0x24), 0xffffffffffffffff)

                    let status := call(
                        gas(), // gas amount
                        coinbase(), // recipient
                        coinbaseXfer, // value (wei)
                        0x0, // calldata start
                        0x0, // calldata len
                        0x0, // return start
                        0x0 // return len
                    )
                    if iszero(status) { revert(0,0) }
                }
            }
        }
    }

    /** fallback to accept payments of Ether */
    receive() external payable {}

    function withdraw(uint256 wad) external {
        require(msg.sender == deployer);
        payable(msg.sender).transfer(wad);
    }

    function withdrawToken(address token, uint256 amount) external {
        require(msg.sender == deployer);
        safeTransfer(token, msg.sender, amount);
    }

}
