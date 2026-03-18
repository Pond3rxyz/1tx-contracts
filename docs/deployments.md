# 1tx Contract Deployments

**Deployer**: `0x4d0e3d2759B8f96B4FA82b2c308Dcd7663794F73`
**Deployment Date**: 2026-03-16

---

## Arbitrum Mainnet (Chain ID: 42161)

**Explorer**: https://arbiscan.io

### Core Contracts

| Contract | Proxy | Implementation |
|----------|-------|----------------|
| InstrumentRegistry | `0x6d116ad5571BC8F2fd3839Fb18c351F58eaBdd97` | `0x76332AE6F24597cf37d38E5deB9f2f4172003E64` |
| SwapPoolRegistry | `0x0744B56Bdf1e1F56FF4ed764F9b0787f4de44bAE` | `0xAA4a2CFd29734dA2041a56A716e408F1A610f85E` |
| SwapDepositRouter | `0xC46C6b9260F3BD3735637AaEd4fBD1B1dE6D84AE` | `0x1f160215BCF1dEeE074c55d3114CAbF952f8675F` |
| CCTPBridge | `0x29DD1294052D317b6F142be2d4e7E9d9Eb178431` | `0x2f7EA74E1FeA199630dc3aa8eDE958882e293aEC` |
| CCTPReceiver | `0xFCc3e94Eb1A6942a462Be9ADB657076AcD8954cB` | `0xC6aF193CBE5c546967CC916934d1Ff78Bb10fd05` |

### Portfolio Contracts

| Contract | Address |
|----------|---------|
| PortfolioStrategy (proxy) | `0x66dC3F5f87493a9F568bD3314625F79dbd242fbA` |
| PortfolioStrategy (implementation) | `0x6C41f964D3F2aF65128912DcadE68c9E96B95e11` |
| PortfolioFactory | `0xAeb653cEEC02bdAEDcD732e123580bEcB53f4F58` |
| PortfolioFactoryHelper | `0xA27bCc651497DEdd0835C0A5aC2FD4275a5f498b` |

### Adapters

| Adapter | Address | Protocol |
|---------|---------|----------|
| AaveAdapter | `0xA734BdbBde76B8de92F2955c44583b1A851BA892` | Aave V3 |
| MorphoAdapter | `0x61040AdE942611008c9Bc4da89735bE536eafFCe` | Morpho Vaults (ERC-4626) |
| EulerAdapter | `0x2173c2E7A5DEb830392f4809c69577031eb757A0` | Euler Earn (ERC-4626) |

### Registered Instruments

#### Aave V3

| Market | Token | Instrument ID |
|--------|-------|---------------|
| USDC | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | `0x0000a4b143cb7f395f87fa310c9ed0b6b164366315746904b32ce1e28bd16c26` |
| USDT | `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` | `0x0000a4b197fbaaa25f8222586e7e2ab22bda0e9ebc297353aede57b516689eff` |
| DAI | `0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1` | `0x0000a4b1e528ec7f067eaf609292eac824ec2d1a2e705cc2fa659c194673fe54` |
| GHO | `0x7dfF72693f6A4149b17e7C6314655f6A9F7c8B33` | `0x0000a4b16d8e1dbca988ef62ff70e233be0bf33eaff193a0bf788dc1159cd4e5` |

#### Morpho Vaults (ERC-4626)

| Vault | Vault Address | Instrument ID |
|-------|---------------|---------------|
| Steakhouse Prime USDC | `0x250CF7c82bAc7cB6cf899b6052979d4B5BA1f9ca` | `0x0000a4b105bcfd10a10ae54b8d6a72c0dd4778724afccfb55a9c10920c05d50d` |
| Clearstar High Yield USDC | `0x64CA76e2525fc6Ab2179300c15e343d73e42f958` | `0x0000a4b1d9610c7242b4216787cee91f37e65297b04c17d78ced99f67c7b8eb3` |
| KPK USDC Yield | `0x2C609d9CfC9dda2dB5C128B2a665D921ec53579d` | `0x0000a4b1683a6a2c2812821848901282927a54901ca1137ee9ac23b876daede9` |
| Yearn Degen USDC | `0x36b69949d60d06ECcC14DE0Ae63f4E00cc2cd8B9` | `0x0000a4b18a421f0f43a27ecc4c28e3a0b623db7ae1df03b6030546372dbb8d4c` |
| Hyperithm USDC | `0x4B6F1C9E5d470b97181786b26da0d0945A7cf027` | `0x0000a4b1025d5d650f3667db4f963a2fb9d8842f47ed8c056c9a7166b0ba55cd` |
| Clearstar USDC Reactor | `0xa53Cf822FE93002aEaE16d395CD823Ece161a6AC` | `0x0000a4b194d4938ed6aab5bdbac7ca4b622f3639b1bca1b8b9c3271403d3b1b5` |
| Gauntlet USDC Core | `0x7e97fa6893871A2751B5fE961978DCCb2c201E65` | `0x0000a4b10b72c929e4226de63c0c29b99d9464f3263b713e814a9d5d3864f518` |
| Steakhouse High Yield USDC | `0x5c0C306Aaa9F877de636f4d5822cA9F2E81563BA` | `0x0000a4b15f2a5083c04410a4302b68957f25ff58ab633244750cf29ba2af5c5d` |

#### Euler Earn (ERC-4626)

| Vault | Vault Address | Instrument ID |
|-------|---------------|---------------|
| eeUSDC | `0xe4783824593a50Bfe9dc873204CEc171ebC62dE0` | `0x0000a4b113408bc2bc523b6483fea3b3b73662555da29ff67d6f4afa8f0fd5a6` |

### Swap Pools

| Pair | Fee | Tick Spacing |
|------|-----|-------------|
| USDC / USDT | 100 | 1 |
| USDC / DAI | 100 | 1 |
| USDC / GHO | 100 | 1 |

### CCTP Configuration

| Setting | Value |
|---------|-------|
| Token Messenger | `0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d` |
| Message Transmitter | `0x81D40F21F12A8F0E3252Bccb954D722d4c464B64` |
| Domain | 3 |
| Destination: Base (domain 6) | receiver: `0xAA4a2CFd29734dA2041a56A716e408F1A610f85E` |
| Destination: Unichain (domain 10) | receiver: `0xD0043081c45E50F2F35260bd4c2E006F6854F510` |

---

## Base Mainnet (Chain ID: 8453)

**Explorer**: https://basescan.org

### Core Contracts

| Contract | Proxy | Implementation |
|----------|-------|----------------|
| InstrumentRegistry | `0x94CC7106f7741FA2d374Ca7b808645fF43b6d2a3` | `0xf3fe9A360E8B916C0b675A32b397889f54F8f371` |
| SwapPoolRegistry | `0xe6C6e82970b5f320B8E3a97fA1aDa5e06fb168b4` | `0x60Bd7F04d41FBc191ED8B1c575111AA4533B6F36` |
| SwapDepositRouter | `0xbFdd5bEdC0cB9B8795A93C2a1fB634012C8F99bC` | `0x69950a624CF85FECb382AC95b9fEFCC90986F230` |
| CCTPBridge | `0x76332AE6F24597cf37d38E5deB9f2f4172003E64` | `0x83241fAa04c1cBB7D5Da97D400aA78C9C7B46729` |
| CCTPReceiver | `0xAA4a2CFd29734dA2041a56A716e408F1A610f85E` | `0x6d116ad5571BC8F2fd3839Fb18c351F58eaBdd97` |

### Portfolio Contracts

| Contract | Address |
|----------|---------|
| PortfolioStrategy (proxy) | `0x51A0971b514ab02c7F03A03e8831f1f1552dc30E` |
| PortfolioStrategy (implementation) | `0xeb7f89d69074a21162bfAa8254A8C0e5153D4a08` |
| PortfolioFactory | `0x90CA0f74342a6399E3469a53373627a26dB3f368` |
| PortfolioFactoryHelper | `0x9bbF8d3C4057E9516C9c8AD3EB049e667AaddE09` |

### Adapters

| Adapter | Address | Protocol |
|---------|---------|----------|
| AaveAdapter | `0xBACC8882E2a9f5a67570E1BC10d87062dB68dfDd` | Aave V3 |
| CompoundAdapter | `0x24fe3D7a9aAdD40033F0C19Ad10D1dF2ea6F7c1B` | Compound V3 |
| MorphoAdapter | `0x12A41B400ca8f81FD09DCcf83Be4632e681Ed2B5` | Morpho Vaults (ERC-4626) |
| EulerAdapter | `0x873C9fFCc888622EF322746F653Bce12450E0Fd8` | Euler Earn (ERC-4626) |
| FluidAdapter | `0x5fD5b1EF0a8FE892e5bdBFbd35CeEc7B3B950372` | Fluid (ERC-4626) |

### Registered Instruments

#### Aave V3

| Market | Token | Instrument ID |
|--------|-------|---------------|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | `0x00002105c053a3e1290845e12a3eea14926472ce7f15da324cdf0700056fc04b` |
| EURC | `0x60a3e35cc302bfa44cb288bc5a4f316fdb1adb42` | `0x00002105ee9b5bc74aa022d3a1015fd449abb00dda35a713227ddc04d89db05c` |
| USDbC | `0xd9aaec86b65d86f6a7b5b1b0c42ffa531710b6ca` | `0x000021050675848050d62d913b2ac6dc14f70650cd1113d5fdbbec3e432f3ed5` |
| GHO | `0x6bb7a212910682dcfdbd5bcbb3e28fb4e8da10ee` | `0x000021059958277ec7a7f000b6b04b905f3f48cf85c08bb0c762bba74dce3be8` |
| cbBTC | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` | `0x000021054e6e25355ea1b1aaf504b4c6b30cd98a426913d5828abd5c51f48e92` |

#### Compound V3

| Market | Comet Address | Instrument ID |
|--------|---------------|---------------|
| USDC | `0xb125E6687d4313864e53df431d5425969c15Eb2F` | `0x00002105e1d832a44e229e784c3d4afba9a1ca44a288e34f7e5ddcba23155adc` |
| USDbC | `0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf` | `0x00002105a6fe9e1b1bc1f2cae0073846842cee59fbab8b444ff4ba3749faaa5b` |

#### Morpho Vaults (ERC-4626)

| Vault | Vault Address | Instrument ID |
|-------|---------------|---------------|
| Steakhouse USDC | `0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183` | `0x00002105a9bdcb222682fd224470c8ed2ae152dbc308a4154c5a332e0d94dccb` |
| Spark USDC | `0x7BfA7C4f149E7415b73bdeDfe609237e29CBF34A` | `0x00002105502f8247374b4bee34e398712f3df7b74c545f3f7b9aec39884ab022` |
| Gauntlet USDC Prime | `0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61` | `0x000021057d36355ffddcae0bede6d9c8f4a73b6c2b3e3a66565c7cd350d72f9f` |
| Steakhouse Prime USDC | `0xBEEFE94c8aD530842bfE7d8B397938fFc1cb83b2` | `0x000021055b188115404f4be66d6cc3b540d3e9876b67059e1140ffafacf7b446` |
| Re7 eUSD | `0xbb819D845b573B5D7C538F5b85057160cfb5f313` | `0x00002105aa35cdd6c9712f4fc21a5249dc60d59386348ac04041bdcc02668778` |
| Clearstar USDC | `0x1D3b1Cd0a0f242d598834b3F2d126dC6bd774657` | `0x00002105bbb2bef3f7b15da825cf967932dfff01ed107b8b18ffdd0d90bbf60f` |
| MEV Frontier USDC | `0x8773447e6369472D9B72f064Ea62e405216E9084` | `0x0000210592187c70f2a787a3fc931dfaea3f66c54a029407aa5ff83ea6fd1859` |

#### Euler Earn (ERC-4626)

| Vault | Vault Address | Instrument ID |
|-------|---------------|---------------|
| eeUSDC | `0x67f062a12f82c3b42d4CA7a35fb26CbAac28008B` | `0x00002105c43f72017e35fdc387b7048128c0df8dc2bf81251d190522404829e8` |

#### Fluid (ERC-4626)

| fToken | fToken Address | Instrument ID |
|--------|----------------|---------------|
| fUSDC | `0xf42f5795D9ac7e9D757dB633D693cD548Cfd9169` | `0x000021053a846b64b310324cfd96a29473b19dc05495f37cb6c87b8f3d721228` |
| fEURC | `0x1943FA26360f038230442525Cf1B9125b5DCB401` | `0x000021056b6d09c15812cf4d0b80184c57f1abd1da536becf4f42dd444e01f23` |
| fGHO | `0x8DdbfFA3CFda2355a23d6B11105AC624BDbE3631` | `0x00002105927eaf7d74858d0241fb00e75d8f519093042667cf0df17cbdd7e37e` |

### Swap Pools

| Pair | Fee | Tick Spacing |
|------|-----|-------------|
| USDC / USDT | 7 | 1 |
| USDC / EURC | 500 | 10 |
| USDC / USDbC | 100 | 1 |
| USDC / GHO | 100 | 1 |
| USDC / USDS | 100 | 1 |
| USDC / cbBTC | 500 | 10 |

### CCTP Configuration

| Setting | Value |
|---------|-------|
| Token Messenger | `0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d` |
| Message Transmitter | `0x81D40F21F12A8F0E3252Bccb954D722d4c464B64` |
| Domain | 6 |
| Destination: Arbitrum (domain 3) | receiver: `0xFCc3e94Eb1A6942a462Be9ADB657076AcD8954cB` |
| Destination: Unichain (domain 10) | receiver: `0xD0043081c45E50F2F35260bd4c2E006F6854F510` |

---

## Unichain Mainnet (Chain ID: 130)

**Explorer**: https://uniscan.xyz
**Deployment Date**: 2026-03-17

### Core Contracts

| Contract | Proxy | Implementation |
|----------|-------|----------------|
| InstrumentRegistry | `0x94CC7106f7741FA2d374Ca7b808645fF43b6d2a3` | `0xf3fe9A360E8B916C0b675A32b397889f54F8f371` |
| SwapPoolRegistry | `0xe6C6e82970b5f320B8E3a97fA1aDa5e06fb168b4` | `0x60Bd7F04d41FBc191ED8B1c575111AA4533B6F36` |
| SwapDepositRouter | `0xde80Ed3CeBdbf688fE12792BDC5d16f4401cC4f2` | `0x6310Fe911aeA27F0529Ea0c76E4B6Ab1A2395DB7` |
| CCTPBridge | `0xAdE2f30c17821e26f58922abcB28bC8E1C7b7E0e` | `0xa22d6cCa3286D3CCb034AaeAd167f68b047E85A2` |
| CCTPReceiver | `0xD0043081c45E50F2F35260bd4c2E006F6854F510` | `0x13130FC5BB532A4a261fD75C5fA79aD3029DF19b` |

### Portfolio Contracts

| Contract | Address |
|----------|---------|
| PortfolioStrategy (proxy) | `0xdD154cc48CC81D074630A695F8651762d05e4103` |
| PortfolioStrategy (implementation) | `0x1c3fedD58868d5df292145114d8939e01AC7a51e` |
| PortfolioFactory | `0x6F29586cAE2Eb38fE8b77f6FdaF15e2c532C44a5` |
| PortfolioFactoryHelper | `0x3E79DdA2971633c69563976f1F3fd8F04CeC26d3` |

### Adapters

| Adapter | Address | Protocol |
|---------|---------|----------|
| MorphoAdapter | `0xBACC8882E2a9f5a67570E1BC10d87062dB68dfDd` | Morpho Vaults (ERC-4626) |
| EulerAdapter | `0x24fe3D7a9aAdD40033F0C19Ad10D1dF2ea6F7c1B` | Euler Earn (ERC-4626) |

### Registered Instruments

#### Morpho Vaults (ERC-4626)

| Vault | Vault Address | Instrument ID |
|-------|---------------|---------------|
| Gauntlet USDC-C | `0x38f4f3B6533de0023b9DCd04b02F93d36ad1F9f9` | `0x000000824b822ab054373ab8475e79d5e8f5c5105ca79632b92aad9db3b4ec87` |

#### Euler Earn (ERC-4626)

| Vault | Vault Address | Instrument ID |
|-------|---------------|---------------|
| eeUSDC | `0x6eAe95ee783e4D862867C4e0E4c3f4B95AA682Ba` | `0x000000820683b130b1d45f5f6374452f1cb9389a8449014179901d2880a3c2c7` |

### CCTP Configuration

| Setting | Value |
|---------|-------|
| Token Messenger | `0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d` |
| Message Transmitter | `0x81D40F21F12A8F0E3252Bccb954D722d4c464B64` |
| Domain | 10 |
| Destination: Base (domain 6) | receiver: `0xAA4a2CFd29734dA2041a56A716e408F1A610f85E` |
| Destination: Arbitrum (domain 3) | receiver: `0xFCc3e94Eb1A6942a462Be9ADB657076AcD8954cB` |
