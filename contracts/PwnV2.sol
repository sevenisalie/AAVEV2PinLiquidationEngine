pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";

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
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function kLast() external view returns (uint);

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

interface IAToken is IERC20 {
    function transferUnderlyingTo(
        address user,
        uint256 amount
    ) external returns (uint256);
}

interface IWETH is IERC20 {
    function deposit() external payable;

    function withdraw(uint amount) external;
}

contract PwnV2 is IUniswapV2Callee {
    address private constant PLAYER =
        0xAEFac7De344509cc05fB806898E18C8B8bD0024c;
    address private constant UNISWAP_V2_FACTORY =
        0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32; //quick
    address private constant LENDING_POOL =
        0x8dFf5E27EA6b7AC08EbFdf9eB090F32ee9a30fcf;
    address private constant UNISWAP_V2_ROUTER =
        0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506; //sushi
    address private constant DBTUSDC =
        0x248960A9d75EdFa3de94F7193eae3161Eb349a12;
    address private constant DBTDAI =
        0x75c4d1Fb84429023170086f06E682DcbBF537b7d;
    address private constant DAI = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063;
    address private constant WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address private constant USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address private constant AUSDC = 0x1a13F4Ca1d028320A707D99520AbFefca3998b7F;
    uint private constant totalBP = 10000;
    uint private constant swapFeeBP = 30; //0.3%
    uint private constant slippageBP = 9950; //99.5%
    uint private constant SCALE = 10 ** 12;
    uint256 MAX_INT = type(uint).max;
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
    IUniswapV2Pair private immutable usdcDaiLP =
        IUniswapV2Pair(0xf04adBF75cDFc5eD26eeA4bbbb991DB002036Bdd);

    // For this example, store the amount to repay
    uint private flashSwapAmountToRepay;

    constructor() {
        //define path here. we only need one so might as well do it in constrctr
        path = new address[](3);
        path[0] = USDC;
        path[1] = WETH;
        path[2] = DAI;

        usdc.approve(address(lendingPool), type(uint256).max);
        dai.approve(address(lendingPool), type(uint256).max);
    }

    function getPlayerDebt(
        address user,
        address asset
    ) internal view returns (uint debt) {
        IERC20 debtToken = IERC20(asset);
        return debtToken.balanceOf(user);
    }

    function getTotalLoanAmount() internal view returns (uint totalDebt) {
        uint usdcDebt = getPlayerDebt(PLAYER, DBTUSDC);
        uint daiDebt = getPlayerDebt(PLAYER, DBTDAI);
        uint scaledDebt = usdcDebt * SCALE;
        uint total = scaledDebt + daiDebt;
        return total / SCALE;
    }

    function getSwapAmountIn() internal view returns (uint amountIn) {
        //amount out, path
        uint daiDebt = getPlayerDebt(PLAYER, DBTDAI);
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

    // This function is to determine how much of Token0 to pay back when you flash loan both Tokn0 and Token1 but only
    // want to repay with token0. Token0 = TokenX for the sake of naming conventions not including 0-9
    // @param flashAmount0 is the amount of Token0 you have borrowed from the pair
    // @param flashAmount1 is the amount of Token1 you have borrowed from the pair
    // @returns amountTokenX is the amount of TokenX you need to transfer back to the pair address at the end of the
    // flashloan. This does not include a fee
    // @proof x * y = k
    // @proof k = ((reserves0 - flashAmount0) + x) * ((reserves1 - flashAmount1) + 0)
    // (reserves0 - flashAmount0)(reserves1 - flashAmount1) + (reserves0 - flashAmount0)0 + x(reserves1 - flashAmount1) + 0x
    // k = reserves0*reserves1 - reserves0*flashAmount1 - flashAmount0*reserves1 + flashAmount0*flashAmount1 + 0 + reserves1x - flashAmount1x + 0

    // x = (reserves0*reserves1 - reserves0*flashAmount1 - flashAmount0*reserves1 + flashAmount0*flashAmount1) / -reserves1 / flashAmount1 / 2

    // @proof x = (k - (reserves0 - flashAmount0) * (reserves1 - flashAmount1)) / (reserves1 - flashAmount1);

    function getAmountInXGivenNoY(
        uint flashAmount0,
        uint flashAmount1,
        IUniswapV2Pair pair
    ) internal view returns (uint amountTokenX) {
        (uint reserves0, uint reserves1, ) = pair.getReserves();
        uint scaledAmount1 = (flashAmount1 / 10 ** 12) + (1 * 10 ** 6);
        amountTokenX = scaledAmount1 + flashAmount0;
    }

    function flashSwap() external {
        // Get AAVE DAI & USDC debt
        uint daiDebt = getPlayerDebt(PLAYER, DBTDAI) + 1;
        uint usdcDebt = getPlayerDebt(PLAYER, DBTUSDC) + 1;
        uint usdcToRepay = getAmountInXGivenNoY(usdcDebt, daiDebt, usdcDaiLP);

        // Need to pass some data to trigger uniswapV2Call
        bytes memory data = abi.encode(msg.sender, usdcToRepay);

        // Flash loan DAI & USDC from Uniswap V2 pool
        usdcDaiLP.swap(usdcDebt, daiDebt, address(this), data);
    }

    // This function is called by the DAI/WETH pair contract

    function uniswapV2Call(
        address sender,
        uint amount0,
        uint amount1,
        bytes calldata data
    ) external {
        require(msg.sender == address(usdcDaiLP), "not pair");
        require(sender == address(this), "not sender");

        (address caller, uint usdcAmountToRepay) = abi.decode(
            data,
            (address, uint)
        );

        uint usdcAmountToRepayWithFee = (usdcAmountToRepay * 10030) / totalBP;

        //repay debt
        lendingPool.repay(USDC, amount0, 2, PLAYER);
        lendingPool.repay(DAI, amount1, 2, PLAYER);

        // new k * amount in = old k
        // old k / new k ==> amount in
        IERC20 ausdc = IERC20(AUSDC);

        ausdc.transferFrom(PLAYER, address(this), ausdc.balanceOf(caller));

        //withdraw onbehalf of player
        lendingPool.withdraw(USDC, MAX_INT, address(this));

        uint leftoverBalance = usdc.balanceOf(address(this));
        // usdc.transferFrom(PLAYER, address(this), 20000000);
        require(usdc.transfer(msg.sender, usdcAmountToRepayWithFee));
        require(leftoverBalance > 500000000, "Not enough leftover");
        require(usdc.transfer(PLAYER, usdc.balanceOf(address(this))));
    }

    receive() external payable {
        return;
    }

    fallback() external payable {
        return;
    }
}
