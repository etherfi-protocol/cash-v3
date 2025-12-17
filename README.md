<h1> <a href="https://ether.fi"><img src="public/etherfi-logo.svg" width="60" height="60" alt="Logo" style="vertical-align:middle; margin-right: 10px;"/></a> ether.fi Cash Smart Contracts </h1>

[ether.fi](http://ether.fi) is charting a path as a crypto native banking alternative, offering a streamlined way for users to save, grow, and spend their crypto. ether.fi Cash completes this product trilogy by providing a platform that consolidates these 3 offerings. While digital banking apps merely build interfaces on legacy systems, Cash delivers true asset ownership, programmable finance, and transparent spending rails by rebuilding financial infrastructure from first principles on blockchain infrastructure. Cash combines the convenience of digital banking with the power and security of decentralized finance.

## Key Features

- **True Self-Custody**: Unlike digital banks that merely hold your assets, Cash gives users full ownership through smart contract wallets with multi-signature security
- **Programmable Finance**: Move beyond rigid spending rules with customizable financial automation that adapts to your needs
- **Real Rewards**: Earn competitive cashback on credit/debit card spend and best-in-class yield on assets held in your account
- **Censorship Resistance**: Financial freedom without the account freezes and arbitrary limitations common in centralized financial services

## Core Components

- **EtherFiSafe**: Smart contract accounts with multi-signature capabilities
- **CashModule**: Core financial functionality for spending and rewards
- **DebtManager**: Self-governing lending and borrowing with transparent parameters
- **PriceProvider**: Decentralized oracles for accurate asset pricing
- **SettlementDispatcher**: Permissionless settlement between on-chain and off-chain systems

## Security Advantages

- Cryptographic multi-signature authorization
- Transparent integration of financial services modules
- Community-controlled recovery mechanisms
- Open-source risk management for lending
- Decentralized permission systems

## Audits

- Fully audited by Certora & Nethermind

## For Developers

### Environment Setup

Create a `.env` file with the following variables:

```
PRIVATE_KEY=
MAINNET_RPC=
ARBITRUM_RPC=
BASE_RPC=
SCROLL_RPC=
MAINNET_ETHERSCAN_KEY=
SCROLLSCAN_KEY=
BASESCAN_KEY=

```

## Audits

- Fully audited by Certora & Nethermind

### Testing

Run the test suite with Forge:

```bash
pnpm install && forge test
```

Getting revert from the `The VM::deployCode` cheat code? Run:
```bash
forge clean && forge build 
```

For specific test files:

```bash
forge test --match-path test/path/to/file.t.sol -vvv
```

### Deployment

Deploy the contracts using Forge scripts:

```bash
source .env && forge script scripts/Setup.s.sol:Setup --rpc-url RPC_URL --chain CHAIN_ID -vvvv --broadcast --verify
```

Replace `RPC_URL` with the appropriate RPC endpoint (e.g., `$SCROLL_RPC`) and `CHAIN_ID` with the target chain ID.
