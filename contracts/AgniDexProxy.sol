// contracts/Box.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/ISwapRouter.sol";
import "./interfaces/IZiSwap.sol";
import "./interfaces/IWMNT.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/FullMath.sol";
import "./libraries/Path.sol";

contract AgniDEXProxy is Initializable, OwnableUpgradeable {
    using Path for bytes;

    address public WMNT;
    address public _router;
    uint256 public _fee;
    address public _IZISwap;

    function initialize(
        address wmnt,
        address router,
        uint256 fee,
        address izumiswap
    ) public initializer {
        __Ownable_init();
        WMNT = wmnt;
        _router = router;
        _fee = fee;
        _IZISwap = izumiswap;
    }

    // Emitted when swap
    event AgniSwap(
        address tokenIn,
        address tokenOut,
        uint256 fee,
        address sender,
        address recipient,
        uint256 amountIn,
        uint256 amountOut
    );

    event FeeChanged(uint256 oldFee, uint256 newFee);

    event IZiSwap(
        address tokenIn,
        address tokenOut,
        uint256 fee,
        address sender,
        address recipient,
        uint256 amountIn,
        uint256 amountOut
    );

    function setIZumSwap(address _swap) external onlyOwner {
        _IZISwap = _swap;
    }

    function changeFee(uint256 fee) external onlyOwner {
        emit FeeChanged(_fee, fee);
        require(fee >= 0 && fee < 1e4, "invalid fee");
        _fee = fee;
    }

    function withdrawToken(address token, uint256 amount) external onlyOwner {
        if (token == WMNT) {
            IWMNT(WMNT).withdraw(amount);
            TransferHelper.safeTransferMNT(owner(), amount);
        } else {
            IERC20(token).transfer(owner(), amount);
        }
    }

    function withdraw(uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "no sufficient ether");
        payable(owner()).transfer(amount);
    }

    function agniSwap(
        ISwapRouter.ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut) {
        address payer = msg.sender;
        address proxyAddress = address(this);

        pay(params.tokenIn, payer, proxyAddress, params.amountIn);

        uint256 newamountIn = FullMath.mulDiv(params.amountIn, 1e4 - _fee, 1e4);

        TransferHelper.safeApprove(params.tokenIn, _router, newamountIn);

        amountOut = ISwapRouter(_router).exactInputSingle(
            ISwapRouter.ExactInputSingleParams(
                params.tokenIn,
                params.tokenOut,
                params.fee,
                proxyAddress,
                params.deadline,
                newamountIn,
                params.amountOutMinimum,
                params.sqrtPriceLimitX96
            )
        );

        require(amountOut > 0, "no out");

        address tokenout = params.tokenOut;
        if (tokenout == WMNT) {
            IWMNT(WMNT).withdraw(amountOut);
            TransferHelper.safeTransferMNT(payer, amountOut);
        } else {
            require(
                IERC20(tokenout).balanceOf(proxyAddress) >= amountOut,
                "no second balance"
            );
            TransferHelper.safeTransfer(tokenout, payer, amountOut);
        }

        emit AgniSwap(
            params.tokenIn,
            params.tokenOut,
            params.fee,
            payer,
            params.recipient,
            params.amountIn,
            amountOut
        );
    }

    struct IZuSwapAmountParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amount;
        uint256 minAcquired;
        uint256 deadline;
    }

    function izumiSwap(
        IZuSwapAmountParams calldata params
    ) external payable returns (uint256 amountOut) {
        address payer = msg.sender;
        address proxyAddress = address(this);

        pay(params.tokenIn, payer, proxyAddress, params.amount);

        uint256 newamountIn = FullMath.mulDiv(params.amount, 1e4 - _fee, 1e4);
        require(
            newamountIn <= type(uint128).max,
            "new amount exceeds uint128 range"
        );

        TransferHelper.safeApprove(params.tokenIn, _IZISwap, newamountIn);

        bytes memory path = abi.encodePacked(
            params.tokenIn,
            params.fee,
            params.tokenOut
        );

        (, uint256 acquire) = ISwap(_IZISwap).swapAmount(
            ISwap.SwapAmountParams(
                path,
                proxyAddress,
                uint128(newamountIn),
                params.minAcquired,
                params.deadline
            )
        );
        amountOut = acquire;
        require(amountOut > 0, "no out");

        address tokenOut = params.tokenOut;
        if (tokenOut == WMNT) {
            IWMNT(WMNT).withdraw(amountOut);
            TransferHelper.safeTransferMNT(payer, amountOut);
        } else {
            require(
                IERC20(tokenOut).balanceOf(proxyAddress) >= amountOut,
                "no second balance"
            );
            TransferHelper.safeTransfer(tokenOut, payer, amountOut);
        }

        emit IZiSwap(
            params.tokenIn,
            tokenOut,
            params.fee,
            payer,
            params.recipient,
            params.amount,
            amountOut
        );
    }

    /// @param token The token to pay
    /// @param payer The entity that must pay
    /// @param recipient The entity that will receive payment
    /// @param value The amount to pay
    function pay(
        address token,
        address payer,
        address recipient,
        uint256 value
    ) internal {
        if (token == WMNT && address(this).balance >= value) {
            // pay with WMNT
            IWMNT(WMNT).deposit{value: value}(); // wrap only what is needed to pay
            IWMNT(WMNT).transfer(recipient, value);
        } else if (payer == address(this)) {
            // pay with tokens already in the contract (for the exact input multihop case)
            TransferHelper.safeTransfer(token, recipient, value);
        } else {
            // pull payment
            TransferHelper.safeTransferFrom(token, payer, recipient, value);
        }
    }

    receive() external payable {}
}
