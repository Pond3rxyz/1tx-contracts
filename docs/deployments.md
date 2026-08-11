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
