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

### Adapters

Adapters are now UUPS-upgradeable — the **proxy** address is permanent and registered in the
InstrumentRegistry; future logic changes ship via `upgradeToAndCall` on the proxy (no
re-registration). Upgrade owner is `0x4d0e3d2759B8f96B4FA82b2c308Dcd7663794F73`.

| Adapter | Proxy | Implementation | Protocol |
|---------|-------|----------------|----------|
| AaveAdapter | `0xD6ff3Ac1e0Bf6284BdFb55626F733F100880F342` | `0xD0b91197fB81D81FEfD108d1fAE6B61F41f1B189` | Aave V3 |
| MorphoAdapter | `0xa8fC4477EEdcb742B9640b23C816370A6523eDaf` | `0xdd515457F3ff1Bc57d2505295C5e58F76FD78458` | Morpho Vaults (ERC-4626) |
| EulerAdapter | `0xDBD1B8048518E6D572181E577d117101292A72aD` | `0x88C0a46A11a6Dbd10a334f5A3b09A1A85755b3b6` | Euler Earn (ERC-4626) |

> **Upgradeable-adapter migration (2026-07-21):** all adapters were swapped to proxy-backed,
> UUPS-upgradeable `src/adapters` implementations via `script/migration/MigrateAdapters.s.sol`
> (atomic re-point of all 14 instruments via `RepointMigrator`, same instrument IDs). Broadcast at
> block 486239114. Previous (non-upgradeable) adapters:
> AaveAdapter `0xB61d8b22d3EFc267A3781e0f72D049925521b412`,
> MorphoAdapter `0xb795ff600c6856f04B3d52083be2579E95678b05`,
> EulerAdapter `0x09F794080096b5131Eb803B431527C2f835763b4`.
>
> **Adapter migration (2026-07-02):** all adapters were swapped to the `src/adapters`
> implementations via `script/migration/MigrateAdapters.s.sol` (atomic re-point of all 14 instruments, same
> instrument IDs). Previous adapters: AaveAdapter `0xA734BdbBde76B8de92F2955c44583b1A851BA892`,
> MorphoAdapter `0x61040AdE942611008c9Bc4da89735bE536eafFCe`,
> EulerAdapter `0x2173c2E7A5DEb830392f4809c69577031eb757A0`.

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
| Bitget x Steakhouse USDC | `0xbeeff1D5dE8F79ff37a151681100B039661da518` | `0x0000a4b1017ac2357e9ea20f8c8e44c19dd8e3ad6c0dfd366ccd29fdc1e68de6` |
| Gauntlet USDC Balanced | `0x55a2B207b0074E13AdCb858950a81B7a04775E0F` | `0x0000a4b1e5be2bbb83c286e95db4cd65012d3a7e0c30e9b957753803a0f0bbd9` |
| Gauntlet USDC Prime | `0x610D151aE40662AE148cdBaaE1Ea5904b6AFAE78` | `0x0000a4b15de3cb58fe6939f7ad04d9fabe0dce86759f2081a0516902109507ad` |
| Gauntlet USDC Prime II | `0x7c574174DA4b2be3f705c6244B4BfA0815a8B3Ed` | `0x0000a4b14f118858bc48f8066fcdd0f30583f02fb1c2f605693d024e48259052` |
| KPK USDC Yield V2 | `0x5837e4189819637853a357aF36650902347F5e73` | `0x0000a4b1781c24a636b29f341d8c1a943bd35fa7292c89fca556a4dcf75204a9` |
| Bitget x Steakhouse USDT (USDT0) | `0xbeeff77CE5C059445714E6A3490E273fE7F2492F` | `0x0000a4b1f836a0a6797cba88993aaa05b9adadff679cf7dd7f4e1070cc0143bf` |

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

### Adapters

Adapters are now UUPS-upgradeable — the **proxy** address is permanent and registered in the
InstrumentRegistry; future logic changes ship via `upgradeToAndCall` on the proxy (no
re-registration). Upgrade owner is `0x4d0e3d2759B8f96B4FA82b2c308Dcd7663794F73`.

| Adapter | Proxy | Implementation | Protocol |
|---------|-------|----------------|----------|
| AaveAdapter | `0x72748778072707586303c09C7D72A502B02f609f` | `0xA0884B15535A747739B7C4CD68808215053B0828` | Aave V3 |
| CompoundAdapter | `0xfc8fbF9E79FDdB6f54352698A0f0357D35E1A94e` | `0x0446bf8ffa67696bD45e17C31AD468f721caC18a` | Compound V3 |
| MorphoAdapter | `0x74980651215862A2c9af32922EB193e31231fCf2` | `0x51c683A87C82A40248f1ccBCd328c21186454825` | Morpho Vaults (ERC-4626) |
| EulerAdapter | `0xb795ff600c6856f04B3d52083be2579E95678b05` | `0x81a38dE58bdCFa60E640261117Aa7470A73AaC45` | Euler Earn (ERC-4626) |
| FluidAdapter | `0xaB1659910AaF12d2274217212A597E9536488D3B` | `0xA666C08f8D720E3b2Dc21Eec3bF0FE01339deB32` | Fluid (ERC-4626) |
| Avantis (generic `ERC4626Adapter`) | `0x5BC27259Be65f159C86B96a95753B485c8cf7A3A` | `0x341f4A237A1a01228e4d5db6065447F0F2b8aB1A` | Avantis |
| Tokemak (generic `ERC4626Adapter`) | `0x86a5B3DF4aDd1c888F95D17d805D9c2d09222D65` | `0xdBd655b17a9EE33fb1f1c328fA701B13C78Ff1dB` | Tokemak |

> **Tokemak adapter — broadcast 2026-08-11, Base block 49,835,741.** One
> `script/RegisterInstruments.s.sol` run deployed the implementation and proxy, authorized the
> router, registered the `baseUSD` market and registered the instrument (5 txs, 1,947,730 gas).
> Adapter implementation tx `0x81d81b807498cbf8384728e5df550e1a647f69a214f5c3b0725d0c7eb6491ad5`,
> proxy tx `0x9a87178d59d9d8bfb0bc853f05ef50837a8d7bee8d9d0b3070c725338003aefd`.
> Verified on-chain after the run: `getAdapterMetadata()` → `("Tokemak", 8453)`, owner
> `0x4d0e3d27…94F73`, `authorizedCallers(router)` true, `hasMarket(baseUSD)` true,
> `getMarketCurrency` → canonical USDC, and
> `InstrumentRegistry.instruments(0x000021053d7d…03a0)` → this proxy. Re-running the script is now
> a no-op. Base-only.
>
> Second generic-`ERC4626Adapter` listing after Avantis, and the same reasoning applies: the
> adapter name is the instrument's protocol identity downstream and is what
> `max_weight_per_protocol` budgets against, so a DEX-LP autopool must not be listed under another
> protocol's name.

> **Avantis adapter — broadcast 2026-08-04, Base block 49,530,937.** One
> `script/RegisterInstruments.s.sol` run deployed the implementation and proxy, authorized the
> router, registered the `avUSDC` market and registered the instrument (5 txs, 1,949,789 gas,
> 0.0000117 ETH). Adapter creation tx `0xf8a34f9daf36d21c32361019e646ebd8872ba4f5c54c38daa61960aa00b15971`.
> Verified on-chain after the run: `getAdapterMetadata()` → `("Avantis", 8453)`, owner
> `0x4d0e3d27…94F73`, `authorizedCallers(router)` true, `hasMarket(avUSDC)` true, and
> `InstrumentRegistry.instruments(0x0000210505ce…32b3)` → this proxy. Arbitrum and Unichain were
> dry-run and are no-ops (0 deployed, 0 registered) — Avantis is Base-only.
>
> It is the **generic `ERC4626Adapter`, not a subclass.** The adapter name is the instrument's
> protocol identity downstream and is what `max_weight_per_protocol` budgets against — listing a
> perp-DEX LP sleeve as "Morpho" would spend the Morpho budget on the one instrument that exists
> because it is *not* Morpho. That identity now comes from `initializeNamed` at deploy time rather
> than from bytecode, so a new ERC-4626 protocol needs no new contract and no new script.
>
> The Morpho/Euler/Fluid subclasses above are retained only because their proxies are already live
> and were initialized before the stored name existed; their hardcoded names still win. New
> listings should not add subclasses.

> **Upgradeable-adapter migration (2026-07-21):** all adapters were swapped to proxy-backed,
> UUPS-upgradeable `src/adapters` implementations via `script/migration/MigrateAdapters.s.sol`
> (atomic re-point of all 18 instruments via `RepointMigrator`, same instrument IDs). Broadcast at
> block 48930629. Previous (non-upgradeable) adapters:
> AaveAdapter `0x10D93d1de2f634d27B35c90EcBE1894D9D9696a4`,
> CompoundAdapter `0xc97B496660C5606994dAebB51b722f2A99266604`,
> MorphoAdapter `0x39cC57fEAA0941e60fD0E76c5283E16e2c616F67`,
> EulerAdapter `0x25A9959Bf3A8a53e155CEd3F0F4AD8A56Dd1657F`,
> FluidAdapter `0xfBAbd830FD0Bfe5a4d9E242094a60f223A162103`.
>
> **Adapter migration (2026-07-02):** all adapters were swapped to the `src/adapters`
> implementations via `script/migration/MigrateAdapters.s.sol` (atomic re-point of all 18 instruments, same
> instrument IDs). Previous adapters: AaveAdapter `0xBACC8882E2a9f5a67570E1BC10d87062dB68dfDd`,
> CompoundAdapter `0x24fe3D7a9aAdD40033F0C19Ad10D1dF2ea6F7c1B`,
> MorphoAdapter `0x12A41B400ca8f81FD09DCcf83Be4632e681Ed2B5`,
> EulerAdapter `0x873C9fFCc888622EF322746F653Bce12450E0Fd8`,
> FluidAdapter `0x5fD5b1EF0a8FE892e5bdBFbd35CeEc7B3B950372`.

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
| Clearstar cbAssets Vault | `0x91C056B6d4311a743614FBc03ac32d4E6A2d3a3c` | `0x000021051acf1400f4edc4db46457ba30c1128cd92f2b9778c04c6ad422255aa` |
| Gauntlet USDC Frontier | `0x1deEfABEe758AAbdC29a542B24ca3b75aFD56765` | `0x00002105b1f5fb6bfb6667ce57b3f60750dae555bf7d894cac42e38503833b2b` |
| Yearn OG USDC V2 | `0xe7D0DBE3493830e2Ab62619211A2BfF0Fc60dB42` | `0x00002105b221c576a9703856a391e393120f9e3ab3575f05a9d061aafcd1b70a` |
| Moonwell Ecosystem USDC | `0xbB2F06CeAE42CBcF5559Ed0713538c8892D977c9` | `0x00002105841aea6b35dc757490dd00c8db55fe8e4d1d5be62cfc78578256d497` |
| Steakhouse High Yield USDC | `0xbeeff7aE5E00Aae3Db302e4B0d8C883810a58100` | `0x0000210512e2709b01f90d43eaa03650dec7af45046a6b67f3a2bbe4e1abe06c` |
| Farcaster x Steakhouse Prime | `0xBeEF00fc6e87dE086A0e29169A2f6e25cF5C11a9` | `0x00002105497b8d8825d4baefab484aff3084e1991c01d31ea7929e338334d57c` |
| RockawayX Midas USDC Prime | `0xAE4181CFB5aaA08bbE77d269c6B595672b9F9Edc` | `0x000021050323e1d70951a1ec2c8e9d063c7d4b44166b4c44778f603c00d8b6f4` |
| Gauntlet USDC Prime V2 | `0x050cE30b927Da55177A4914EC73480238BAD56f0` | `0x000021057001e361ea5097a4917f41a6f5e83990fcb91a392a1b2a59ac881c2d` |
| Clearstar Boring USDC | `0x0282159ecCaabA941bD1f4C518944D8fDCdc0681` | `0x0000210534ce468b293a5b123292b91d2c2b760df9c6f830fe4043a05bcd05bb` |
| ARCHITECT Global Value II | `0x6022Cbf61352618053d89FD9eEfe78Cb725B3c9d` | `0x00002105fc5bcab1eb3a58276c089cfe8b662ac5704bb5f7afe4cc4351b724cb` |
| Steakhouse Prime USDC V2 | `0xbeef0e0834849aCC03f0089F01f4F1Eeb06873C9` | `0x00002105a0a6684f95a2f6e51231fb21fbdf00e08de0311f086691c730e0c6cf` |
| Prime USDC | `0x5e03f8965e2957291B3c6990C6Cb9023c36d3d30` | `0x0000210590596a84c3defff747434f651a8a01b84bf0ba3b4e5574929e768d53` |
| Ethena x Steakhouse USDC | `0xBeEfF0be997Cca5B1c13A7433c2004637975739e` | `0x000021058b79f3d99e76d72d0499bd392f09337161d8c7b4a412cbf8672ec3ae` |
| Galaxy USDC Quality | `0x1e9e47583f15D45a10Df48c0b1846E0492c795D7` | `0x00002105ac4118770d1c4774ecedb3ffc5dc36b1e377193e370f673f2c70c2b3` |
| ARCHITECT Global Value | `0x8effa741061aaA2d8A5012a9B09A2d31d8B628d7` | `0x00002105d0c59133080c305c4ba411781e5ffe25efed0e50c666e89669120ee7` |
| Moonwell Flagship USDC | `0x48a90E85be5C56b0A669985A12ee7C449fC79965` | `0x000021050007e54cb7c0cb4aef15106124377331dc632158313ddeb1151de4ed` |
| Clearstar Core USDC | `0x116e1A65717A534B73EcB7d4F6543c65DBCd0E46` | `0x000021058a5d325868084f366952c749c00b0887fc7d7157de5f123aa9741523` |
| Avantgarde USDC Conservative V2 | `0xE34D43CA9152D198B60654868C8cD197196a492f` | `0x000021054a681e800e04821bd30b1c53f5792b2e345619add1f255c7d4ed6724` |
| Steakhouse High Yield USDC Edition | `0xbeeff2490FEffa212faC2f6553682C219E6a8845` | `0x00002105488dd7aa268aaa7e97e3841a8908090137ce1959186a092e167a167b` |
| Pangolins USDC † | `0x1401d1271C47648AC70cBcdfA3776D4A87CE006B` | `0x000021057ab5a05c032c9f60e46d06c772450b4b77567ccb8a9c19735ca496b2` |
| Yield Clearstar USDC † | `0xE74c499fA461AF1844fCa84204490877787cED56` | `0x000021058be1513e7572e06fa77c4ff65518d3826b14f9f979dfa8aae23947c3` |
| Gauntlet USDC Core † | `0xc0c5689e6f4D256E861F65465b691aeEcC0dEb12` | `0x00002105ef2f62db32db452d2dade3eac6215c9c6fc80ea316836a7a7f025589` |

> † MetaMorpho **V1.1**, not Morpho Vaults V2 — as are the seven above them
> (`Steakhouse USDC` through `MEV Frontier USDC`). Both generations share one adapter
> because the adapter's name is the identity `max_weight_per_protocol` budgets against,
> and both take the same Morpho Blue market risk; splitting them would hand the allocator
> two Morpho budgets.
>
> Listed only because Morpho has no V2 successor for these three mandates. Where a
> successor exists the curator migrates into it and the V1.1 balance leaves — measured
> 2026-08-13, Moonwell Flagship V1.1 (`0xc1256Ae5`) was down 61% over 180 days against the
> V2 vault listed above, and Steakhouse High Yield V1.1 (`0xBEEFA7B8`) down 64% against
> its own. Those two and UltraYield USDC (`0x5435BC53`, −43% in 30 days, no successor) are
> asserted **absent** from config by
> `test/fork/base/MorphoVaultsV11.fork.t.sol:test_supersededV11VaultsAreDeliberatelyAbsent`.
>
> ⚠️ Both Moonwell Flagship vaults are named "Moonwell Flagship USDC" and both mint
> `mwUSDC`. The one registered here is the **V2** contract at `0x48a90E85`, which held
> $10.0k on 2026-08-13 while its V1.1 namesake held $9.77M. Match on address, never on
> name or symbol.

#### Euler Earn (ERC-4626)

| Vault | Vault Address | Instrument ID |
|-------|---------------|---------------|
| eeUSDC | `0x67f062a12f82c3b42d4CA7a35fb26CbAac28008B` | `0x00002105c43f72017e35fdc387b7048128c0df8dc2bf81251d190522404829e8` |
| Clearstar Earn USDC | `0x8bF41Ad2b816F7c220b22F4BCD63fC2A35Ab4247` | `0x00002105b2d3540889a3d867578d1244586985c9fd85cc811a57993cccefd367` |

#### Fluid (ERC-4626)

| fToken | fToken Address | Instrument ID |
|--------|----------------|---------------|
| fUSDC | `0xf42f5795D9ac7e9D757dB633D693cD548Cfd9169` | `0x000021053a846b64b310324cfd96a29473b19dc05495f37cb6c87b8f3d721228` |
| fEURC | `0x1943FA26360f038230442525Cf1B9125b5DCB401` | `0x000021056b6d09c15812cf4d0b80184c57f1abd1da536becf4f42dd444e01f23` |
| fGHO | `0x8DdbfFA3CFda2355a23d6B11105AC624BDbE3631` | `0x00002105927eaf7d74858d0241fb00e75d8f519093042667cf0df17cbdd7e37e` |

#### Avantis (ERC-4626)

Registered 2026-08-04 on adapter `0x5BC27259Be65f159C86B96a95753B485c8cf7A3A`. The instrument ID
matches what the backend derives (`generateInstrumentId(8453, vault, marketId)`).

| Vault | Vault Address | Instrument ID |
|-------|---------------|---------------|
| avUSDC | `0x944766f715b51967E56aFdE5f0Aa76cEaCc9E7f9` | `0x0000210505ce3e09856275ab0e8b20abcc4e45bd455c50ab26f86011cde632b3` |

No `SwapPoolRegistry` entry is needed — `avUSDC.asset()` is canonical USDC, so the router's swap
branch never fires. Exit-path analysis: `avusdc-exit-verification.md`.

#### Tokemak (ERC-4626)

Registered 2026-08-11 on adapter `0x86a5B3DF4aDd1c888F95D17d805D9c2d09222D65`. The instrument ID
matches what the backend derives (`generateInstrumentId(8453, vault, marketId)`).

| Vault | Vault Address | Instrument ID |
|-------|---------------|---------------|
| baseUSD | `0x9c6864105AEC23388C89600046213a44C384c831` | `0x000021053d7defefc2175a9fa61a945e0126a55ddc302fa156e07c855a7003a0` |

No `SwapPoolRegistry` entry is needed — `baseUSD.asset()` is canonical USDC, so the router's swap
branch never fires. Exit-path verification: `test/fork/base/TokemakBaseUSD.fork.t.sol`.

Two properties of this vault are load-bearing and are pinned by that suite:

- Exits are bounded by destination liquidity and **revert `"insufficient liquidity"` past that
  bound rather than returning zero**, which is what makes it safe on `ERC4626Adapter.withdraw`
  as it stands (no `assetsWithdrawn == 0` guard). Round trips settle at every size tested up to
  $8M, ~163% of vault TVL, at a 3–9 bps spread that narrows as size grows.
- **`previewRedeem` is state-mutating, in violation of ERC-4626** — a STATICCALL to it reverts.
  Harmless only because the adapter values through `convertToAssets` and exits through `redeem`.
  Do not move `convertToUnderlying` onto `previewRedeem`.

Sizing caveat, not enforced anywhere in the stack: against the unperturbed vault the exit ceiling
sits near 80% of TVL (~$3.95M of $4.90M at the pinned block). It does not constrain a
deposit-then-exit round trip, which brings its own liquidity, but it does constrain a holder
exiting after others have drawn the destinations down.

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

## Monad Mainnet (Chain ID: 143)

**Explorer**: https://monadscan.com
**Deployed**: 2026-08-12, block 95,317,402–95,317,520
**CCTP domain**: 15

### Core Contracts

| Contract | Proxy | Implementation |
|----------|-------|----------------|
| InstrumentRegistry | `0xAeC82CA054E8Fc2ec9563230370aF199D9aaeE06` | `0x53eFd863B04F3db7F9285e4b1876642519d91961` |
| SwapPoolRegistry | `0x01463d74B2AFCeEd4747561e863f00B37c5e1289` | `0x6cb17AFCB98A2DB21a1BaaE61990e9CC357F43c3` |
| SwapDepositRouter | `0xe823985F6f08e0666c0271cD5c3457a5cF631edE` | `0xBF324a91e624Cde957618ff44c90b13809F4e3F5` |
| CCTPBridge | `0x1c3fedD58868d5df292145114d8939e01AC7a51e` | `0xd5c7d72c57B44C1686970673576368B85F90a4Ff` |
| CCTPReceiver | `0x6F29586cAE2Eb38fE8b77f6FdaF15e2c532C44a5` | `0xdD154cc48CC81D074630A695F8651762d05e4103` |

### Adapters

| Adapter | Proxy | Implementation | Protocol |
|---------|-------|----------------|----------|
| AaveAdapter | `0x451b9EBdf001B900a51fa8282c62f49478Bf5a22` | `0x9a210AD228Ad008D3c7663DD5CEE0574fB64b3C4` | Aave V3 |
| MorphoAdapter | `0xacC31BD7A13d1c835792A0F5a5024507B34636b7` | `0x2C3d6e475EA7Fd054a502700a5d54bBd3457eCEf` | Morpho Vaults V2 |
| EulerAdapter | `0xb68f4332A60143067ee5135b9baCd59681f3f20f` | `0x4dee4c5847De5B037DBd3a9D1B75fc9D8a1d0116` | Euler Earn |
| AaveAdapter (Neverland) | `0x3b7eF4223827491503E5c079053E13B498667875` | `0x5a6D39e83DDe93735a2a4E1D30F64e5Bd1Ea9f99` | Neverland |

The Morpho, Euler and Neverland adapters were all deployed by
`RegisterInstruments.s.sol`, not `Deploy.s.sol` — the latter's Morpho/Euler gates
key off vault names that predate this chain, so it silently skips both. Morpho
and Euler are the generic `ERC4626Adapter` carrying their protocol identity via
`initializeNamed`; verified on-chain to report `("Morpho Vaults V2", 143)` and
`("Euler Earn", 143)`, matching the other chains so `max_weight_per_protocol`
budgets them in the same bucket.

Neverland is the exception to that shape: it is an **`AaveAdapter`**, not an
`ERC4626Adapter`, because Neverland is an Aave V3 fork with its own pool at
`0x80F00661b13CC5F6ccd3885bE7b4C9c67545D585`. It carries its own protocol
identity through `AaveAdapter.initializeNamed` and reports `("Neverland", 143)`
on-chain — deliberately *not* `"Aave V3"`, so `max_weight_per_protocol` budgets
it separately from the real Aave deployment rather than pooling the two into one
protocol exposure. `AAVE_POOL` is set once at initialization and the name has no
setter, so neither is repointable; a wrong value there means a new proxy.

### Instruments

| Instrument | Execution address | instrumentId |
|---|---|---|
| Aave V3 USDC | `0x69a5F9AD4f96ebf0a0C792dD42a01cC5C0102fef` | `0x0000008fbfd944d81e22998baa9c49d788d05ec5636ce25b26408135673ba9cf` |
| Morpho `hyperUSDCa` | `0x78999cc96d2Ba0341588C60CcB0E91c6C33CF371` | `0x0000008f3d26791f852640634e078add7a84aa50630e294ff910af180097e875` |
| Morpho `augustUSDCv2` | `0x80017bF0f793EBbE9679Cd61ff0e395B62CAbB59` | `0x0000008f3c1527da06166f62265ed8e7750e2b151127103d7c74957cb1849a9d` |
| Morpho `satUSDC` | `0x75753e494e5e374C52E1d84fc04EB14B10F2C079` | `0x0000008f102d9ee582ee088bffee66e04a7452a25da6619fde473c3ec939bec1` |
| Euler `eUSDC-15` | `0xa3B64e2674463c98CbD21807055D8C1E008b6e79` | `0x0000008f2580724bcc8c57ba6c99ec93607f008765eccd9bdb393989e8565528` |
| Euler `Clearstar Earn USDC` | `0xE1BcA19baA63894D374578320551633320436523` | `0x0000008f20acc156b5a77f0036614b47715953e03473bcd955ca726e00cb3176` |
| Euler `eAUSD-16` (AUSD) | `0x9E3500649e16EBE295277EC030e42FAbacFa870E` | `0x0000008fe112a02a03f4a41b8843076a4a7700f0aa6bf9b654755ba73a42078b` |
| Aave V3 GHO | `0x69a5F9AD4f96ebf0a0C792dD42a01cC5C0102fef` | `0x0000008fb4a7350a0ac2ef38919fa70f138ed3da494b3daf01c3da91bef52180` |
| Neverland USDC | `0x80F00661b13CC5F6ccd3885bE7b4C9c67545D585` | `0x0000008f4ebefd380701541f3c3b8714bd828824fa2842de58ba96eea9758a3f` |
| Neverland AUSD | `0x80F00661b13CC5F6ccd3885bE7b4C9c67545D585` | `0x0000008f8b183cc36cd7ab674e79e56a05bc89cd6a733a92f3ca89ac84bc0266` |

`eAUSD-16` is the chain's first non-USDC instrument, registered 2026-08-16 in
block 96,496,190. Its market currency is AUSD
(`0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a`), read on-chain from the vault by
`RegisterInstruments.s.sol`, so it is reachable only through the swap route
below. 91.5% utilised at listing — `cash()` $1.017M against $10.45M of assets —
which bounds a single exit near $1.0M. Nothing off-chain reads
`maxRedeem`/`maxWithdraw`, so an oversized sell is an opaque revert.

Aave GHO and the two Neverland reserves were listed 2026-09-09 in block
103,276,887, by the same `RegisterInstruments.s.sol` — GHO onto the existing
Aave adapter, USDC and AUSD onto the Neverland proxy the same run deployed.

Two of the three are non-USDC and so reachable only through a swap route. GHO
(`0xfc421aD3C883Bf9E7C4f42dE845C4e4405799e73`) needed a new one, registered in
block 103,276,664 — deliberately *before* the instrument, since a GHO market
that exists before its route is a deposit that succeeds and a swap that reverts.
Neverland AUSD needed nothing new: it reuses the USDC/AUSD route already carrying
`eAUSD-16`.

### Swap Pools

| Route | Fee | tickSpacing | Hooks |
|---|---|---|---|
| USDC ↔ AUSD (bidirectional) | 50 (0.005%) | 1 | none |
| USDC ↔ GHO (bidirectional) | 100 (0.01%) | 1 | none |

USDC/AUSD was registered 2026-08-16 in block 96,495,955 by
`RegisterSwapPools.s.sol` — the incremental script added for that listing,
because swap-pool registration previously existed only inside `Deploy.s.sol`'s
full eight-step `run()` and could not be applied to a live chain. USDC/GHO
followed 2026-09-09 in block 103,276,664 through the same script.

> ⚠️ **The fee tier is the whole assertion.** Four AUSD/USDC tiers are
> initialised on Monad and only fee 50 / tickSpacing 1 holds liquidity.
> DeFiLlama labels this pair "0.01%" and there is no such pool — a route written
> from the vendor label would point `SwapPoolRegistry` at an empty pool, and
> routing is confined to Uniswap V4 with no fallback. Measured in
> `test/fork/monad/AusdUsdcRoute.fork.t.sol`; pinned in
> `test/unit/NetworkConfig.t.sol`.

Quoted through Monad's V4Quoter (`0xa222dd357a9076d1091ed6aa2e16c9742dd26891`)
at registration: 250,000 USDC → 249,924.709470 AUSD (3.0 bps), and
250,000 AUSD → 249,857.920844 USDC (5.7 bps).

### Status

**Complete.** Router ↔ bridge ↔ receiver wired, `tokenMessenger` set, router
authorized on the bridge and on all four adapters, and the CCTP mesh closed in
both directions — Monad ↔ Base, Arbitrum and Unichain each carry the correct
domain, `mintRecipient` and `destinationCaller`, verified on-chain against the
far side's own `CCTPReceiver`. Ten instruments registered, and the USDC/AUSD and
USDC/GHO routes each registered in both directions.

**Source verification is not done.** The Etherscan V2 API covers chain 143 and the key works,
but forge 1.5.0 rejects the chain from its own registry before reading the configured url.
Needs a newer foundry or a manual standard-json POST. Contracts are unaffected.

**Outstanding:** Aave `USDT0` still needs a verified Uniswap v4 `PoolKey` before
it can be listed; AUSD now has one (above). The allocator side has run no
correlation screen against the USDC vaults, and `caps.min_effective_positions`
charges unmeasurable instruments as fully correlated, so they may still fail
closed there — `eAUSD-16` is the exception, screened at correlation −0.017
against the shelf.

> ⚠️ **Every `forge script` run against Monad needs
> `--gas-estimate-multiplier 300`.** Forge sizes gas from a local simulation on
> Ethereum's schedule; Monad charges up to 34% more, and the first deploy attempt
> lost all ten of its configuration calls to it while every contract creation
> succeeded. Monad also bills the full gas limit, so every receipt shows
> `gasUsed == gasLimit` whether it succeeded or not.

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

### Adapters

Adapters are now UUPS-upgradeable — the **proxy** address is permanent and registered in the
InstrumentRegistry; future logic changes ship via `upgradeToAndCall` on the proxy (no
re-registration). Upgrade owner is `0x4d0e3d2759B8f96B4FA82b2c308Dcd7663794F73`.

| Adapter | Proxy | Implementation | Protocol |
|---------|-------|----------------|----------|
| MorphoAdapter | `0x07380DD19b01D07184269E3EAfBeadD28806348E` | `0x3F48517370De796CCDa6434953c32283A28Fd18f` | Morpho Vaults (ERC-4626) |
| EulerAdapter | `0xb2C77bB144Fb9051a7B6339DF34888faDE13f53E` | `0x20BA5f06A69a732014C238B91Fe0C7cA50F8B2EA` | Euler Earn (ERC-4626) |

> **Upgradeable-adapter migration (2026-07-21):** both adapters were swapped to proxy-backed,
> UUPS-upgradeable `src/adapters` implementations via
> `script/migration/MigrateAdaptersUnichain.s.sol` (atomic re-point, same instrument IDs).
> Broadcast tx `0x330b6b619c9aa21917514fa7129914cd4deab7542896d8cc321e6db035976236` (block 53901927).
> Previous (non-upgradeable) adapters: MorphoAdapter `0xd4aB69fD10CF2dF8AB0700561F6A4c96650D28B7`,
> EulerAdapter `0x26864BCB5a60a9803bDa7Ef7C9eE8f0C7bE64cc3`.
>
> **Adapter migration (2026-07-02):** both adapters were swapped to the `src/adapters`
> implementations via `script/migration/MigrateAdaptersUnichain.s.sol` (atomic re-point, same instrument IDs).
> Previous adapters: MorphoAdapter `0xBACC8882E2a9f5a67570E1BC10d87062dB68dfDd`,
> EulerAdapter `0x24fe3D7a9aAdD40033F0C19Ad10D1dF2ea6F7c1B`.

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
