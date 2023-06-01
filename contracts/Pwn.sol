pragma solidity ^0.8.17;

interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint amount0,
        uint amount1,
        bytes calldata data
    ) external;
}

interface ILendingPool {
    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    function withdraw(address asset, uint256 amount, address to) external;

    function repay(
        address asset,
        uint256 amount,
        uint256 rateMode,
        address onBehalfOf
    ) external;
}

interface IUniswapV2Pair {
    function swap(
        uint amount0Out,
        uint amount1Out,
        address to,
        bytes calldata data
    ) external;
}

interface IUniswapV2Factory {
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);
}

interface IUniswapV2Router {
    function getAmountsIn(
        uint amountOut,
        address[] memory path
    ) external view returns (uint[] memory amounts);

    function getAmountsOut(
        uint amountIn,
        address[] memory path
    ) external view returns (uint[] memory amounts);

    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

interface IERC20 {
    function totalSupply() external view returns (uint);

    function balanceOf(address account) external view returns (uint);

    function transfer(address recipient, uint amount) external returns (bool);

    function allowance(
        address owner,
        address spender
    ) external view returns (uint);

    function approve(address spender, uint amount) external returns (bool);

    function transferFrom(
        address sender,
        address recipient,
        uint amount
    ) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);
}

interface IWETH is IERC20 {
    function deposit() external payable;

    function withdraw(uint amount) external;
}

contract Pwn is IUniswapV2Callee {
    address private constant PLAYER =
        0xAEFac7De344509cc05fB806898E18C8B8bD0024c;
    address private constant UNISWAP_V2_FACTORY =
        0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32; //quick
    address private constant LENDING_POOL =
        0x8dFf5E27EA6b7AC08EbFdf9eB090F32ee9a30fcf;
    address private constant UNISWAP_V2_ROUTER =
        0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506; //sushi
    address private constant AUSDC = 0x248960A9d75EdFa3de94F7193eae3161Eb349a12;
    address private constant ADAI = 0x75c4d1Fb84429023170086f06E682DcbBF537b7d;
    address private constant DAI = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063;
    address private constant WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address private constant USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    uint private constant totalBP = 10000;
    uint private constant swapFeeBP = 30; //0.3%
    uint private constant slippageBP = 9950; //99.5%
    uint private constant SCALE = 10 ** 12;
    uint256 MAX_INT = 2 ** 256 - 1;
    address[] private path;

    IUniswapV2Factory private constant factory =
        IUniswapV2Factory(UNISWAP_V2_FACTORY);
    IERC20 private constant weth = IERC20(WETH);
    IERC20 private constant usdc = IERC20(USDC);
    IERC20 private constant dai = IERC20(DAI);
    ILendingPool private constant lendingPool = ILendingPool(LENDING_POOL);
    IUniswapV2Router private constant sushiRouter =
        IUniswapV2Router(0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff);
    IUniswapV2Pair private immutable usdcWethLP =
        IUniswapV2Pair(0x853Ee4b2A13f8a742d64C8F088bE7bA2131f670d);
    IUniswapV2Pair private immutable daiWethLP =
        IUniswapV2Pair(0x4A35582a710E1F4b2030A3F826DA20BfB6703C09);

    // For this example, store the amount to repay
    uint private flashSwapAmountToRepay;

    constructor() {
        //define path here. we only need one so might as well do it in constrctr
        path = new address[](3);
        path[0] = USDC;
        path[1] = WETH;
        path[2] = DAI;
    }

    function getPlayerDebt(
        address user,
        address asset
    ) internal view returns (uint debt) {
        IERC20 debtToken = IERC20(asset);
        return debtToken.balanceOf(user);
    }

    function getTotalLoanAmount() internal view returns (uint totalDebt) {
        uint usdcDebt = getPlayerDebt(PLAYER, AUSDC);
        uint daiDebt = getPlayerDebt(PLAYER, ADAI);
        uint scaledDebt = usdcDebt * SCALE;
        uint total = scaledDebt + daiDebt;
        return total / SCALE;
    }

    function getSwapAmountIn() internal view returns (uint amountIn) {
        //amount out, path
        uint daiDebt = getPlayerDebt(PLAYER, ADAI);
        uint[] memory amounts = sushiRouter.getAmountsIn(daiDebt, path);
        return amounts[0];
    }

    function emergencyWithdrawToken(address token) external {
        IERC20 _token = IERC20(token);
        _token.transfer(PLAYER, _token.balanceOf(address(this)));
        return;
    }

    function emergencyWithdrawEth() external {
        (bool succ, bytes memory data) = payable(PLAYER).call{
            value: address(this).balance
        }("");
        require(succ, "failed to send eth to player");
        return;
    }

    function flashSwap() external {
        // Need to pass some data to trigger uniswapV2Call
        bytes memory data = abi.encode(USDC, address(this));
        // amount0Out is USDC, amount1Out is WETH
        // uint usdcDebt = getPlayerDebt(PLAYER, AUSDC);
        uint totalUsdc = getTotalLoanAmount();
        // uint usdcRequiredForDaiSwap = getSwapAmountIn();
        // uint swap1 = (usdcRequiredForDaiSwap * swapFeeBP) / totalBP;
        uint totalUSDCWithFees = (totalUsdc * 10100) / totalBP;
        usdcWethLP.swap(totalUSDCWithFees, 0, address(this), data);
    }

    // function flashSwap() external {
    //     // Need to pass some data to trigger uniswapV2Call
    //     bytes memory data = abi.encode(USDC, address(this));
    //     // amount0Out is USDC, amount1Out is WETH
    //     // uint usdcDebt = getPlayerDebt(PLAYER, AUSDC);
    //     uint totalUsdc = getTotalLoanAmount();
    //     // uint usdcRequiredForDaiSwap = getSwapAmountIn();
    //     // uint swap1 = (usdcRequiredForDaiSwap * swapFeeBP) / totalBP;
    //     uint totalUSDCWithFees = (totalUsdc * 10100) / totalBP;


    //     uint daiDebt = getPlayerDebt(PLAYER, ADAI);
    //     uint usdcDebt = getPlayerDebt(PLAYER, AUSDC);
    //     usdcWethLP.swap(usdcDebt, daiDebt, address(this), data);
    // }

    // This function is called by the DAI/WETH pair contract
    function uniswapV2Call(
        address sender,
        uint amount0,
        uint amount1,
        bytes calldata data
    ) external {
        require(msg.sender == address(usdcWethLP), "not pair");
        require(sender == address(this), "not sender");

        (address tokenBorrow, address callee) = abi.decode(
            data,
            (address, address)
        );

        // Your custom code would go here. For example, code to arbitrage.
        require(tokenBorrow == USDC, "token borrow != USDC");

        uint daiDebt = getPlayerDebt(PLAYER, ADAI);
        uint usdcDebt = getPlayerDebt(PLAYER, AUSDC);
        uint usdcAmountIn = getSwapAmountIn();
        uint slippageAccountedAmountIn = (usdcAmountIn * 10020) / totalBP; //hacky solutoin because positive slippage for tokens2exacttokens

        //makeswap
        usdc.approve(UNISWAP_V2_ROUTER, (slippageAccountedAmountIn + 7));
        sushiRouter.swapTokensForExactTokens(
            daiDebt,
            slippageAccountedAmountIn,
            path,
            callee,
            block.timestamp + 30
        );

        uint postTradeUsdcBalance = usdc.balanceOf(callee);
        require(
            postTradeUsdcBalance >= usdcDebt,
            "Trade fucked up, didnt leave enought USDC"
        );

        //repay debt
        lendingPool.repay(USDC, usdcDebt, 2, PLAYER);
        lendingPool.repay(DAI, daiDebt, 2, PLAYER);

        // lendingPool.repay(USDC, amount0, 2, PLAYER);
        // lendingPool.repay(DAI, amount1, 2, PLAYER);        

        //withdraw onbehalf of player

        lendingPool.withdraw(USDC, MAX_INT, PLAYER);

        //guarantees
        // uint postUsdcDebt = getPlayerDebt(PLAYER, AUSDC);
        // uint postDaiDebt = getPlayerDebt(PLAYER, ADAI);
        uint postUsdcBalance = usdc.balanceOf(callee);
        // require(postDaiDebt <= 0, "Dai debt dint get fully paid");
        // require(postUsdcDebt <= 0, "Dai debt dint get fully paid");
        require(postUsdcBalance >= amount0);

        //repay flashswap

        uint fee = (amount0 * 3) / 997 + 1;
        flashSwapAmountToRepay = amount0 + fee;

        // Transfer flash swap fee from caller
        usdc.transferFrom(PLAYER, callee, fee);

        // Repay
        usdc.transfer(address(usdcWethLP), flashSwapAmountToRepay);

        require(usdc.balanceOf(PLAYER) > (100 * 10 ** 6)); //rough fuzz. assume ill have more than 10 usdc
    }

    receive() external payable {
        return;
    }

    fallback() external payable {
        return;
    }
}
