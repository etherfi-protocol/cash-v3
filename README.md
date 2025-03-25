<h1> <img src="public/etherfi-logo.svg" width="60" height="60" alt="Logo" style="vertical-align:middle; margin-right: 10px;"/> EtherFi Cash Smart Contracts </h1> 

Cash transcends the limitations of neo-banks by rebuilding financial services from first principles using blockchain technology. Where neo-banks only digitize traditional banking, Cash delivers true asset ownership, programmable finance, and transparent operations without compromising on security or user experience.


## Key Features

- **True Self-Custody**: Unlike neo-banks that still control your assets, Cash gives users full ownership through smart contract wallets with multi-signature security
- **Programmable Finance**: Beyond the rigid limits of neo-banking apps, Cash enables customizable spending rules and automated financial management
- **Real Rewards**: Earn substantial cashback and actual yield on assets, not the minimal interest rates offered by traditional financial services
- **Censorship Resistance**: Financial freedom without the account freezes and arbitrary limitations common in centralized financial services

## Core Components

- **EtherFiSafe**: Smart contract accounts with multi-signature capabilities
- **CashModule**: Core financial functionality for spending and rewards
- **DebtManager**: Self-governing lending and borrowing with transparent parameters
- **PriceProvider**: Decentralized oracles for accurate asset pricing
- **SettlementDispatcher**: Permissionless settlement between on-chain and off-chain systems

## Security Advantages

- Cryptographic multi-signature authorization (not password-based like neo-banks)
- Transparent integration of financial services modules
- Community-controlled recovery mechanisms
- Open-source risk management for lending
- Decentralized permission systems

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

### Testing

Run the test suite with Forge:

```bash
forge test
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