//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );

    /**
     * bit 0-15: LTV
     * bit 16-31: Liq. threshold
     * bit 32-47: Liq. bonus
     * bit 48-55: Decimals
     * bit 56: reserve is active
     * bit 57: reserve is frozen
     * bit 58: borrowing is enabled
     * bit 59: stable rate borrowing enabled
     * bit 60-63: reserved
     * bit 64-79: reserve factor
     */
    function getConfiguration(address asset)
        external
        view
        returns (
            uint256 config
        );

}

// UniswapV2

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
interface IERC20 {
    // Returns the account balance of another account with address _owner.
    function balanceOf(address owner) external view returns (uint256);

    /**
     * Allows _spender to withdraw from your account multiple times, up to the _value amount.
     * If this function is called again it overwrites the current allowance with _value.
     * Lets msg.sender set their allowance for a spender.
     **/
    function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

    /**
     * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
     * The function SHOULD throw if the message caller’s account balance does not have enough tokens to spend.
     * Lets msg.sender send pool tokens to an address.
     **/
    function transfer(address to, uint256 value) external returns (bool);
}

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;
    address public constant borrower = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;
    address me = address(this); 
    /// Retrieve LendingPool address
    ILendingPool lendingPool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    // store token addresses
    address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; 
    address WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; 
    // store uniswap pair inf    
    IUniswapV2Factory public factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    IUniswapV2Pair private eupair = IUniswapV2Pair(factory.getPair(WETH, USDT));
    IUniswapV2Pair private bepair = IUniswapV2Pair(factory.getPair(WBTC, WETH));

    // IUniswapV2Pair private pair = IUniswapV2Pair(0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852);
    uint256 private constant liquidationAmountUSDT = 2916378221684;
    // some helper function, it is totally fine if you can finish the lab without using these function
    // https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        // calculates max amount that can be payed
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        // calculates w/fees
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }
    constructor() {
        // TODO: (optional) initialize your contract
    }

    // TODO: add a `receive` function so that you can withdraw your WETH
    receive() external payable {} 
    // END TODO

    // required by the testing script, entry for your liquidation call
    function operate() external {
        // 0. security checks and initializing variables
        //    *** Your code here 

        // 1. get the target user account data & make sure it is liquidatable
        //    *** Your code here ***
        uint256 totalCollateralETH;
        uint256 totalDebtETH;
        uint256 currentThresh;
        // uint256 ltv;
        uint256 healthFactor;

        
        // console.log(address(this).balance);
        (totalCollateralETH, totalDebtETH, , currentThresh, , healthFactor) = lendingPool.getUserAccountData(address(borrower));
        require(healthFactor / (10**health_factor_decimals) < 1, "HF is not below 1");
        uint256 spread = (lendingPool.getConfiguration(WETH) & 0xFFFF00000000)>> 32;
        console.log("Liquidation Spread: ", spread);
        console.log("Current Threshold: ", currentThresh);

        // 2. call flash swap to liquidate the target user
        // based on https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077
        // we know that the target user borrowed USDT with WBTC as collateral
        // we should borrow USDT, liquidate the target user and get the WBTC, then swap WBTC to repay uniswap
        // (please feel free to develop other workflows as long as they liquidate the target user successfully)
        // TODO: consider existing balance before swapping
        uint256 r0;
        uint256 r1;
        (r0, r1, ) = eupair.getReserves();
        console.log("---------- WETH/USD RESERVES ----------");
        console.log(r0, r1);
        console.log("---------- TOTAL DEBT (ETH) ----------");
        console.log(totalDebtETH);
        console.log("---------- TOTAL COLLATERAL (ETH) ----------");
        console.log(totalCollateralETH);
        // based on this math: r > (D - CT) / (1 + (ST) - T)
        uint256 liquidationAmt1ETH = (totalDebtETH*10e9 - (totalCollateralETH*currentThresh*10e5))/((10e9 + (spread*currentThresh) - currentThresh*10e5));
        // buffer for positive hf
        uint256 liquidationAmt1USDT = getAmountOut(liquidationAmt1ETH, r0, r1);

        liquidationAmt1USDT = liquidationAmt1USDT > r1? r1: liquidationAmt1USDT;

        console.log("---------- PLANNED REPAYMENT (USDT) ----------");
        console.log("First Round: ", liquidationAmt1USDT);
        console.log("OLD HEALTH FACTOR: ", healthFactor);
        
        eupair.swap(0, liquidationAmt1USDT, address(this), abi.encode("hi"));
        (totalCollateralETH, totalDebtETH, , currentThresh, , healthFactor) = lendingPool.getUserAccountData(address(borrower));
        console.log("NEW HEALTH FACTOR: ", healthFactor);
        if (healthFactor/(10**health_factor_decimals) < 1) {
            (r0, r1, ) = eupair.getReserves();
            // 11 == random constant that worked well
            uint256 liquidationAmt2USDT = getAmountOut(totalDebtETH/11, r0, r1);

            liquidationAmt2USDT = liquidationAmt2USDT > r1? r1: liquidationAmt2USDT;
            console.log("SECOND REPAY AMOUNT USD: ", liquidationAmt2USDT);

            eupair.swap(0, liquidationAmt2USDT, address(this), abi.encode("hi"));
        } 
        // 3. Convert the profit into ETH and send back to sender
        uint256 my_eth = IERC20(WETH).balanceOf(me);
        IWETH(WETH).withdraw(my_eth); 
        msg.sender.call{value: my_eth}("");
        
        
    }
    // required by the swap
    function uniswapV2Call(
        address,
        uint256,
        uint256 amount1,
        bytes calldata
    ) external override {
        uint256 eurWETH;
        uint256 eurUSDT;
        uint256 berWBTC;
        uint256 berWETH;

        (eurWETH, eurUSDT, ) = eupair.getReserves();
        (berWBTC, berWETH, ) = bepair.getReserves();
        // 2.1 liquidate the target user
        liquidate(amount1);

        // 2.2 swap WBTC for WETH
        IERC20 WBTC_POOL = IERC20(WBTC);
        uint256 WBTCAmountToPay = WBTC_POOL.balanceOf(me);
        uint256 WETHAmountToReceive = getAmountOut(WBTCAmountToPay, berWBTC, berWETH);
        console.log();
        WBTC_POOL.approve(address(bepair), WBTCAmountToPay);
        WBTC_POOL.transfer(address(bepair), WBTCAmountToPay);
        console.log("----- SWAP BTC FOR ETH -----");
        console.log("WBTC TO PAY: ", WBTCAmountToPay);
        console.log("WETH TO RECEIVE: ", WETHAmountToReceive);
        bepair.swap(0, WETHAmountToReceive, me, new bytes(0));
        console.log("WETH BALANCE: ", IERC20(WETH).balanceOf(me));


        // 2.3 repay flash swap
        IERC20 WETH_POOL = IERC20(WETH);
        uint256 repayAmount = getAmountIn(amount1, eurWETH, eurUSDT);
        console.log("FLASH LOAN REPAY AMOUNT: ", repayAmount);
        // console.log("FLASH LOAN FEE: ", repayAmount ) - convert(amount1, eurUSDT, eurWETH));

        WETH_POOL.approve(address(eupair), repayAmount);
        WETH_POOL.transfer(address(eupair), repayAmount);
        
    }

    function liquidate(uint256 debtToCover) internal {
        // liquidate the borrower 
        IERC20(USDT).approve(address(lendingPool), debtToCover);
        lendingPool.liquidationCall(WBTC, USDT, borrower, debtToCover, false);
    }
}
