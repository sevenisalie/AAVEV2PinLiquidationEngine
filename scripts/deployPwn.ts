import { ethers } from "hardhat"


const main = async () => {
    const PWNFACTORY = await ethers.getContractFactory("PwnV2")
    const pwndeploy = await PWNFACTORY.deploy()
    await pwndeploy.deployed()
    console.log(
        `Pwn deployed to ${pwndeploy.address}`
    );
}

main()