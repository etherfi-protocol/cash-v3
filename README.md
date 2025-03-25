<h1> <img src="public/etherfi-logo.svg" width="60" height="60" alt="Logo" style="vertical-align:middle; margin-right: 10px;"/> EtherFi Cash Smart Contracts </h1> 


Cash powers ether.fi's crypto neo-banking experience, bringing traditional banking services to Web3 through a secure, modular and infinitely extensible smart contract architecture.

## Key Features

- **Smart Contract Accounts**: Self-custodial wallets with multi-signature security and account recovery
- **Banking Services**: Spending limits, cashback rewards, and flexible credit/debit modes
- **Yield Generation**: Supply assets to earn interest through secure lending markets
- **Cross-Chain Transfers**: Bridge assets across blockchain networks seamlessly
- **Fiat Integration**: Settlement infrastructure for crypto-fiat interactions

## Core Components

- **EtherFiSafe**: Smart contract accounts with multi-signature capabilities
- **CashModule**: Core banking functionality for spending and cashback
- **DebtManager**: Lending and borrowing with configurable parameters
- **PriceProvider**: Secure oracles for accurate asset pricing
- **SettlementDispatcher**: Manages settlement between on-chain and off-chain systems

## Security

- Multi-signature transaction authorization
- Whitelisting and secure integration of modules
- Account recovery with timelock protection
- Automated health checks for loan positions
- Role-based access control


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