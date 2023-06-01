//determine debt
//determine collateral
//take out flashloan for debt amount
//payback debt
//withdraw collateral
//payback flashloan with collateral + fees
// https://polygon-mainnet.g.alchemy.com/v2/xqh4Yge8hgKcutvYBVkBz6dG-eFAuiAy

//addresses polygon
const addresses = {
    ETH: "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619",
    USDC: "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174",
    DAI: "0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063",
    Factory: "0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32",
    USDCWETH: "0x853Ee4b2A13f8a742d64C8F088bE7bA2131f670d",
    DAIWETH: "0x4A35582a710E1F4b2030A3F826DA20BfB6703C09",
    player: "0xAEFac7De344509cc05fB806898E18C8B8bD0024c",
    lendingpool: "0x8dFf5E27EA6b7AC08EbFdf9eB090F32ee9a30fcf",
    lendingpooladdressprovider: "0xd05e3E715d945B59290df0ae8eF85c1BdB684744",
    aUSDC: "0x1a13F4Ca1d028320A707D99520AbFefca3998b7F",
    USDCdbt: "0x248960A9d75EdFa3de94F7193eae3161Eb349a12",
    DAIdbt: "0x75c4d1Fb84429023170086f06E682DcbBF537b7d",
    quickRouter: "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff",
    pwn: "0x3Ab429846aF10946d49ce066cE521c5f52b0a011"
}

import { isBigNumberish } from "@ethersproject/bignumber/lib/bignumber"
import { BigNumber } from "ethers"
import { ethers } from "hardhat"
import { parse } from "path"

const debtTokenABI = [
    "function balanceOf(address owner) view returns (uint balance)",
    "function approve(address spender, uint amount) external returns (bool)"
]

const routerABI = [
    "function getAmountsOut(uint amountIn, address[] memory path) public view returns (uint[] memory amounts)",
    "function getAmountsIn(uint amountOut, address[] memory path) public view returns (uint[] memory amounts)",
    `function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
      ) external returns (uint[] memory amounts)`
]


const getProvider = async () => {
    const provider = ethers.provider
    if (!provider) { return undefined } else {
        return provider
    }
}

const getSigner = async () => {
    try {
        const signer = await ethers.getSigner("0xAEFac7De344509cc05fB806898E18C8B8bD0024c")
        return signer
    } catch (error) {
        console.log(error)
        return undefined
    }
}

const approval = async () => {
    const signer = await ethers.getSigner(addresses.player)
    const usdc = new ethers.Contract(addresses.aUSDC, debtTokenABI, signer)
    const approval = await usdc.approve(addresses.pwn, ethers.constants.MaxUint256)
    const tx = await approval.wait()
    return tx
}

const pwn = async () => {
    const ctr = await ethers.getContractAt("PwnV2", addresses.pwn)
    // const approve = await approval()
    const pwn = await ctr.flashSwap({
        gasLimit: 1000000,
        maxFeePerGas: ethers.utils.parseUnits("100", 9),
        maxPriorityFeePerGas: ethers.utils.parseUnits("44", 9)
    })
    const pwnreceipt = await pwn.wait()
    return console.log(pwnreceipt)

}

const getDebt = async () => {
    const provider = await getProvider()
    const player = await (await getSigner())?.getAddress()
    const usdcDebtToken = new ethers.Contract(addresses.USDCdbt, debtTokenABI, provider)
    const daiDebtToken = new ethers.Contract(addresses.DAIdbt, debtTokenABI, provider)
    const rawBalance0 = await usdcDebtToken.balanceOf(addresses.player)
    const rawBalance1 = await daiDebtToken.balanceOf(addresses.player)
    const balance0: any = ethers.utils.formatUnits(rawBalance0, 6)
    const balance1: any = ethers.utils.formatUnits(rawBalance1, 18)
    const scale = (BigNumber.from(10)).pow(BigNumber.from(12)) //for usdc (18 - 6), could use IERC20 interface to dynamically address difference in decimals, but fuck it
    const truesum = parseFloat(balance0) + parseFloat(balance1)
    const num = (rawBalance0.mul(scale)).add(rawBalance1)

    return {
        usdc: rawBalance0,
        dai: rawBalance1,
        totalDebtInUSDC: {
            decimal: truesum,
            bignum: num.div(scale)
        }
    }
}

const getSwapAmounts = async () => {
    const provider = await getProvider()
    // const prov = new ethers.providers.JsonRpcProvider("https://polygon-mainnet.g.alchemy.com/v2/xqh4Yge8hgKcutvYBVkBz6dG-eFAuiAy")
    const router = new ethers.Contract(
        addresses.quickRouter,
        routerABI,
        provider
    )
    const debt = await getDebt()
    const amountInUSDCforExactAmountOutofDai = await router.getAmountsIn(
        debt.dai,
        [
            addresses.USDC,
            addresses.ETH,
            addresses.DAI
        ]
    )
    console.log(amountInUSDCforExactAmountOutofDai)

    const amounts = {
        debt: debt.dai,
        tokenIn: addresses.USDC,
        amountIn: amountInUSDCforExactAmountOutofDai[0],
        tokenOut: addresses.DAI,
        amountOut: amountInUSDCforExactAmountOutofDai.at(-1)
    }
    return amounts
}

const simulation = async () => {
    const d = await getDebt()
    //state
    let usdcDebtPosition = d.usdc
    let daiDebtPosition = d.dai
    let flashloan = BigNumber.from(0)
    let dai = BigNumber.from(0)
    let usdc = BigNumber.from(0)

    //data
    const totalDebtPosition = d.totalDebtInUSDC.bignum
    const provider = await getProvider()

    //takeout flashloan
    flashloan = flashloan.add(totalDebtPosition)
    usdc = usdc.add(flashloan)

    //split into dai and usdc
    const amountOut = daiDebtPosition
    const amountIn = (await getSwapAmounts()).amountIn

    // const swap = await (new ethers.Contract(addresses.quickRouter, routerABI, provider)).swapTokensForExactTokens(
    //     amountOut,
    //     amountIn,
    //     [addresses.USDC, addresses.ETH, addresses.DAI],
    //     addresses.player,
    //     Math.floor((Date.now() / 1000)) + 60 * 120
    // )
    dai = dai.add(amountOut)
    usdc = usdc.sub(amountIn)
    console.log(dai)
    console.log(usdc)


}

const main = async () => {
    await pwn()
    return
}

main()