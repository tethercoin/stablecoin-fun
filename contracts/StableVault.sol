// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import { VolatileToken } from "./VolatileToken.sol";

import { ERC20 } from "@rari-capital/solmate/src/tokens/ERC20.sol";
import { SafeTransferLib } from "@rari-capital/solmate/src/utils/SafeTransferLib.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { IERC4626 } from "./interfaces/IERC4626.sol";
import { FixedPointMathLib } from "./utils/FixedPointMath.sol";

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./interfaces/IWETH9.sol";

import "hardhat/console.sol";

/// Deposit, Withdraw, Mint, Redeem exists for Stable
/// Fund & Defund exists for Volatility
/// All reserve asset accounting (WETH) is done inside of Stable Vault.
/// Preserve 4626 expected interface (eg vault mint/burn operating on one underlying)

error NoEthSupplied();

contract StableVault is ERC20, IERC4626 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    uint256 public constant minFloat = 12000; // 120%
    uint256 public constant maxFloat = 10000; // 100%
    uint256 public volatilityBuffer;

    VolatileToken public immutable volatile;
    IWETH9 public immutable weth;
    AggregatorV3Interface internal immutable priceFeed;

    constructor() ERC20("SRAI", "SRU", 18) {
        volatile = new VolatileToken("VOLAI", "volSRU", 18);
        weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        priceFeed = AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
    }

    receive() external payable {}

    fallback() external payable {}

    /*///////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Stablecoin
    /// Give WETH amount, get STABLE amount
    function deposit(uint256 wethIn, address to) public override returns (uint256 stableCoinAmount) {
        require((stableCoinAmount = previewDeposit(wethIn)) != 0, "ZERO_SHARES");
        require(weth.transferFrom(msg.sender, address(this), wethIn));
        _mint(to, stableCoinAmount);
        emit Deposit(msg.sender, to, wethIn, stableCoinAmount);
    }

    /// @notice Stablecoin
    /// Mint specific AMOUNT OF STABLE by giving WETH
    function mint(uint256 stableCoinAmount, address to) public override returns (uint256 wethIn) {
        require(weth.transferFrom(msg.sender, address(this), wethIn = previewMint(stableCoinAmount)));
        _mint(to, stableCoinAmount);
        emit Deposit(msg.sender, to, wethIn, stableCoinAmount);
    }

    /// @notice Stablecoin
    /// Withdraw from Vault underlying. Amount of WETH by burning equivalent amount of STABLECOIN
    function withdraw(
        uint256 amountReserve,
        address to,
        address from
    ) public override returns (uint256 wethOut) {
        uint256 allowed = allowance[from][msg.sender];
        if (msg.sender != from && allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amountReserve;
        wethOut = previewWithdraw(amountReserve); // Calc wethOut for given amount of WETH
        _burn(from, amountReserve); // burn this vault token i.e minted stablecoins
        emit Withdraw(from, to, amountReserve, wethOut);
        weth.transferFrom(address(this), msg.sender, wethOut);
    }

    /// @notice Stablecoin
    /// Redeem from Vault underlying. (WETH) equivalent to AMOUNTSTABLE
    function redeem(
        uint256 amountStable,
        address to,
        address from
    ) public override returns (uint256 wethOut) {
        uint256 allowed = allowance[from][msg.sender];
        if (msg.sender != from && allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amountStable;
        require((wethOut = previewRedeem(amountStable)) != 0, "ZERO_ASSETS");
        wethOut = previewRedeem(amountStable);
        _burn(from, amountStable);
        emit Withdraw(from, to, wethOut, amountStable);
        weth.transferFrom(address(this), msg.sender, wethOut);
    }

    /// @notice Volatility/Funding token
    /// Give amount of WETH, receive VolatilityToken
    function fund(uint256 volCoinAmount, address to) public returns (uint256 wethIn) {
        require(weth.transferFrom(msg.sender, address(this), wethIn = previewFund(volCoinAmount)));
        volatile.mint(to, volCoinAmount);
        volatilityBuffer += wethIn;
        emit Deposit(msg.sender, to, wethIn, volCoinAmount); // Change event
    }

    /// @notice Volatility/Funding token
    /// Redeem number of SHARES (VolToken) for WETH as current price (at loss or profit)
    function defund(
        uint256 volCoinAmount,
        address to,
        address from
    ) public returns (uint256 wethOut) {
        require((wethOut = previewDefund(volCoinAmount)) != 0, "ZERO_ASSETS");
        volatile.burn(to, volCoinAmount);
        volatilityBuffer -= wethOut;
        weth.transferFrom(address(this), msg.sender, wethOut);
        emit Withdraw(from, to, wethOut, volCoinAmount);
    }

    function previewFund(uint256 amount) public view returns (uint256 stableVaultShares) {
        return amount / (getLatestPrice() / 1e8); // AMOUNT / (ETH/USD)
    }

    /// @notice Volatility token
    /// The only function that claims yield from Vault
    /// https://jacob-eliosoff.medium.com/a-cheesy-analogy-for-people-who-find-usm-confusing-1fd5e3d73a79
    function previewDefund(uint256 amount) public view returns (uint256 wethOut) {
        uint256 sharesGrowth = amount * ((volatilityBuffer * getLatestPrice()) / volatile.totalSupply());
        wethOut = sharesGrowth / (getLatestPrice() / 1e8);
        // return amount * ((totalAssets() * (getLatestPrice() / 1e8)) / totalSupply);
    }

    /// @notice How much at max can be redeemed to keep 120% WETH over current all minted STABLE
    function freeFloat() public view returns (uint256) {
        uint256 totalCollateralValue = totalAssets() * getLatestPrice(); // USD value of reserve
        if (totalCollateralValue >= (totalSupply * minFloat)) {}
        return (totalAssets() * minFloat) / maxFloat;
    }

    /// @notice Stablecoin
    /// Return how much STABLECOIN does user receive for AMOUNT of WETH
    function previewDeposit(uint256 amount) public view override returns (uint256 stableCoinAmount) {
        return (getLatestPrice() / 1e8) * amount; // (ETH/USD) * AMOUNT
    }

    /// @notice Stablecoin
    /// Return how much WETH is needed to receive AMOUNT of STABLECOIN
    function previewMint(uint256 amount) public view override returns (uint256 stableCoinAmount) {
        return amount / (getLatestPrice() / 1e8); // AMOUNT / (ETH/USD)
    }

    /// @notice Stablecoin
    /// Return how much WETH to transfer by calculating equivalent amount of burn to given AMOUNT of WETH
    function previewWithdraw(uint256 amount) public view override returns (uint256 wethOut) {
        return (getLatestPrice() / 1e8) * amount; // AMOUNT * (ETH/USD)
    }

    /// @notice Stablecoin
    /// Return how much WETH to transfer equivalent to given AMOUNT of STABLECOIN
    function previewRedeem(uint256 amount) public view override returns (uint256 wethOut) {
        return amount / (getLatestPrice() / 1e8); // AMOUNT / (ETH/USD)
    }

    /*///////////////////////////////////////////////////////////////
                         INTERNAL HOOKS LOGIC
    //////////////////////////////////////////////////////////////*/

    function beforeWithdraw(uint256 amount) internal {}

    function afterDeposit(uint256 amount) internal {}

    /*///////////////////////////////////////////////////////////////
                        ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view override returns (uint256) {
        return weth.balanceOf(address(this));
    }

    function assetsOf(address user) public view override returns (uint256) {
        return balanceOf[user];
    }

    function volatileAssetsOf(address user) public view returns (uint256) {
        return volatile.balanceOf(user);
    }

    function assetsPerShare() public view override returns (uint256) {
        return previewRedeem(10**decimals);
    }

    function maxDeposit(address) public pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address user) public view override returns (uint256) {
        return assetsOf(user);
    }

    function maxRedeem(address user) public view override returns (uint256) {
        return balanceOf[user];
    }

    function getLatestPrice() public view returns (uint256) {
        (uint80 roundID, int256 price, uint256 startedAt, uint256 timeStamp, uint80 answeredInRound) = priceFeed
            .latestRoundData();
        return uint256(price);
    }

    /*///////////////////////////////////////////////////////////////
            ETH WRAPPER LOGIC (split into other proxy contract)
            https://github.com/ethers-io/ethers.js/issues/1160
    //////////////////////////////////////////////////////////////*/
    // function deposit() external payable returns (uint256 stableCoinAmount) {
    // uint256 ethIn = msg.value;
    // if (ethIn > 0) revert NoEthSupplied();
    // weth.deposit{ value: msg.value }();
    // stableCoinAmount = deposit(ethIn, msg.sender);
    // }
    // function mint() external payable returns (uint256 volCoinAmount) {
    // uint256 ethIn = msg.value;
    // if (ethIn > 0) revert NoEthSupplied();
    // weth.deposit{ value: msg.value }();
    // volCoinAmount = mint(ethIn, msg.sender);
    // }
}
