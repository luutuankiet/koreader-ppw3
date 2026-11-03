# cloudflare-gateway: snapshot, not maintained

Promoted from the 20261103/cloudflare-gateway topic folder. Frozen when committed; read it
as evidence, never as current truth.

The folder held the working files for moving the Kindle device bridge onto a Cloudflare
Worker (issues #16 to #22). Each `issue-<n>/` subfolder holds the scripts and decisive
tool output for that issue; `shared/` holds files that served the whole effort. Values
that identify an account, a host or a person are written as `$KEY` names from `.env`
(see `.env.example`), and home directories as `$HOME`; `envscan hydrate <file>` puts the
values back. Build outputs are listed as pointers only, with the command that rebuilds
them. Paths into the original working folder read `<topic-folder>/`.

## issue-16/69-fake-gateway-401.log
- was: `20261103/cloudflare-gateway/69/69-fake-gateway-401.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `9a3692760426a02d830bc95effc20470f6879e152fb8e9d7dd99945ebdef727f`
- captured: 2026-11-03T15:55:45Z
- rebuild: `none: a recorded run`

## issue-16/69-fake-gateway.log
- was: `20261103/cloudflare-gateway/69/69-fake-gateway.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `28b0ffd62c8ed9a5a736266dd04a0e67d5ec2b23094950f15f756f9b3f82d5ea`
- captured: 2026-11-03T15:48:12Z
- rebuild: `none: a recorded run`

## issue-16/69-fake-gateway.mjs
- was: `20261103/cloudflare-gateway/69/69-fake-gateway.mjs` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `371f112cae378316ab44d03c1cb38bb03e822676dae92088eafaa3296aeaa0ca`
- captured: 2026-11-03T15:37:55Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-16/69-fake-gateway.mjs | node --input-type=module -`

## issue-16/69-supervisor-config.sh
- was: `20261103/cloudflare-gateway/69/69-supervisor-config.sh` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `0a120e983331ec5ee3fdafac57f8ce7461d3a428b9e49136b14cbe84b22d6be2`
- captured: 2026-11-03T15:52:31Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-16/69-supervisor-config.sh | bash -s`

## issue-16/69-test_live.txt
- was: `20261103/cloudflare-gateway/69/69-test_live.txt` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `01215ac4c9cc212672bec5741b8e4575083903ed66262338fc5d57879e25e2f8`
- captured: 2026-11-03T15:52:31Z
- rebuild: `cd koreader_mcp.koplugin && luajit test_live.lua`

## issue-16/69-test_ui_agent.txt
- was: `20261103/cloudflare-gateway/69/69-test_ui_agent.txt` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `cf6aa276a38251067efe790357ee22aa3eee3c25096777f3ceca12aee4423796`
- captured: 2026-11-03T15:52:31Z
- rebuild: `cd koreader_mcp.koplugin && luajit test_ui_agent.lua`

## issue-17/fake-device.mjs
- was: `20261103/cloudflare-gateway/70/fake-device.mjs` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `7befa4a8d0c17855ff34f2eacd14f3e4689c1967dcfbc359f2e23e7b88420065`
- captured: 2026-11-03T15:38:30Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-17/fake-device.mjs | node --input-type=module -`

## issue-17/jest-kindle-gateway.log
- was: `20261103/cloudflare-gateway/70/jest-kindle-gateway.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `2dca6a155313ee132d52ae5653915c487cbc6d3884e69fef488a7844da1557a0`
- captured: 2026-11-03T15:38:27Z
- rebuild: `cd kindle-gateway && npm test`

## issue-17/tsc-kindle-gateway.log
- was: `20261103/cloudflare-gateway/70/tsc-kindle-gateway.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- captured: 2026-11-03T15:38:15Z
- rebuild: `cd kindle-gateway && npx tsc --noEmit`

## issue-17/tsc-worker.log
- was: `20261103/cloudflare-gateway/70/tsc-worker.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- captured: 2026-11-03T15:38:09Z
- rebuild: `cd kindle-gateway-worker && npx tsc --noEmit`

## issue-17/vitest-run.log
- was: `20261103/cloudflare-gateway/70/vitest-run.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `d4759cfa47d3140b287860b5c780eb562979d6b4d58495d5eff18ad2fcd454a2`
- captured: 2026-11-03T15:38:15Z
- rebuild: `cd kindle-gateway-worker && npx vitest run`

## issue-18/encode-timing.log
- was: `20261103/cloudflare-gateway/71/run/encode-timing.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `f38aace4ac0b3aa2367060a9bb73d4f41e1e1dbb623c2c81cc3759dbbb4719dd`
- captured: 2026-11-03T16:01:10Z
- rebuild: `none: a recorded run`

## issue-18/encode-timing.mjs
- was: `20261103/cloudflare-gateway/71/run/encode-timing.mjs` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `d83a27c4598dcfef086b907f87b1933876d48143cfceaa2928ca074138fda31c`
- captured: 2026-11-03T16:01:05Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-18/encode-timing.mjs | node --input-type=module -`

## issue-18/fake-device.mjs
- was: `20261103/cloudflare-gateway/71/run/fake-device.mjs` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `d7aa14d427096a94262311620118647d7b79a75f45ad78a56382f478bb094893`
- captured: 2026-11-03T16:03:34Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-18/fake-device.mjs | node --input-type=module -`

## issue-18/kindle-gateway-jest.log
- was: `20261103/cloudflare-gateway/71/run/kindle-gateway-jest.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `19c6189fafddafa2824e06d3626ebcdd27c428507b070becf2d6bdcc9bb46e47`
- captured: 2026-11-03T16:03:34Z
- rebuild: `cd kindle-gateway && npm test`

## issue-18/mcp-client-legacy.log
- was: `20261103/cloudflare-gateway/71/run/mcp-client-legacy.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `d10f0ae80593f2add3b6580024dfc29778550e0be3f5daf1a8895cac45ecb41e`
- captured: 2026-11-03T16:00:56Z
- rebuild: `none: a recorded run`

## issue-18/mcp-client-modern.log
- was: `20261103/cloudflare-gateway/71/run/mcp-client-modern.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `bda0dfd799c106f1170b9b0e37827c40233eb4635a87749c34c33e77751576e4`
- captured: 2026-11-03T16:00:53Z
- rebuild: `none: a recorded run`

## issue-18/mcp-client.mjs
- was: `20261103/cloudflare-gateway/71/run/mcp-client.mjs` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `79e960f4025eda7551864089a2626d7cb0234ebf5e389ca1d859f8812e0fc812`
- captured: 2026-11-03T16:03:34Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-18/mcp-client.mjs | node --input-type=module -`

## issue-18/tools-parity.log
- was: `20261103/cloudflare-gateway/71/run/tools-parity.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `4a34f7a86449977f17b44efc5d0e0428f125727b61ebd0f8305022d7965663ac`
- captured: 2026-11-03T16:01:45Z
- rebuild: `none: a recorded run`

## issue-18/tools-parity.mjs
- was: `20261103/cloudflare-gateway/71/run/tools-parity.mjs` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `23fdc699c890891affc20bb66ee4892ef5b322f6ae5324be8ecbe2c5e70cc62b`
- captured: 2026-11-03T16:01:45Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-18/tools-parity.mjs | node --input-type=module -`

## issue-18/vitest.log
- was: `20261103/cloudflare-gateway/71/run/vitest.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `34a803a2886e37027916600b708950f33a577e8d68bba55f75e679014ec66a96`
- captured: 2026-11-03T16:03:34Z
- rebuild: `cd kindle-gateway-worker && npx vitest run`

## issue-19/72-gateway-jest.log
- was: `20261103/cloudflare-gateway/72/72-gateway-jest.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `fde7a1bd76e04ae03e7233e835985a282cca8530bad90ca7506a661df3c20cac`
- captured: 2026-11-03T16:10:47Z
- rebuild: `cd kindle-gateway && npm test`

## issue-19/72-live-read.log
- was: `20261103/cloudflare-gateway/72/72-live-read.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `bfbdb5bff5e22f1a69be3f050709c819a7fb1b9875fb464203cda54068d3c04a`
- captured: 2026-11-03T16:11:42Z
- rebuild: `none: a recorded run`

## issue-19/72-live-upload.log
- was: `20261103/cloudflare-gateway/72/72-live-upload.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `61d03034dda7200ad32f953a6f6a954aa8b54db1fc80802182672be0f48373f3`
- captured: 2026-11-03T16:11:25Z
- rebuild: `none: a recorded run`

## issue-19/72-tsc.log
- was: `20261103/cloudflare-gateway/72/72-tsc.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `da5e101522c6e1becec71016328b0b13964fcfdf9c94f50bfa958fc737e0b667`
- captured: 2026-11-03T16:10:23Z
- rebuild: `cd kindle-gateway-worker && npx tsc --noEmit`

## issue-19/72-worker-vitest.log
- was: `20261103/cloudflare-gateway/72/72-worker-vitest.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `2750ce3f501819630bf1276aa2f93770480deef1c314353913d2c97cb3a06012`
- captured: 2026-11-03T16:10:36Z
- rebuild: `cd kindle-gateway-worker && npx vitest run`

## issue-19/capture-golden.ts
- was: `20261103/cloudflare-gateway/72/capture-golden.ts` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `9880fd1b877d6c126883040672690ca897a4d15427472e6afc3575d0026b60c8`
- captured: 2026-11-03T16:07:19Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-19/capture-golden.ts | npx tsx -`

## issue-19/live-read.mts
- was: `20261103/cloudflare-gateway/72/live-read.mts` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `fcef7e7899f3ca15fbd9f9b21d142954d009b8fa14182b0d28034a65c202edb2`
- captured: 2026-11-03T16:07:19Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-19/live-read.mts | npx tsx -`

## issue-19/live-read.sh
- was: `20261103/cloudflare-gateway/72/live-read.sh` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `3ef8f37ca8feadaa413eaff4d9661e39b3a74757cd5e8d7c3a9af23840ff69fc`
- captured: 2026-11-03T16:11:42Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-19/live-read.sh | bash -s`

## issue-19/live-upload.sh
- was: `20261103/cloudflare-gateway/72/live-upload.sh` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `b201d05d7dcdd72674d56853361753f437941c9bf6cdee654ffd8db14a4d171f`
- captured: 2026-11-03T16:07:19Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-19/live-upload.sh | bash -s`

## issue-20/20-public-install.log
- was: `20261103/cloudflare-gateway/73/public-install/20-public-install.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `c1433737b3be793d433402c19491c363a14fe9fdae348884ed72729f2f917287`
- captured: 2026-11-03T16:00:01Z
- rebuild: `none: a recorded run`

## issue-20/20-public-install.lua
- was: `20261103/cloudflare-gateway/73/public-install/20-public-install.lua` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `dbad37b257c71d4e215aae8784eb88e0cbae1a66eb18076b701ce41662081fec`
- captured: 2026-11-03T16:00:00Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-20/20-public-install.lua | luajit -`

## issue-20/20-test_core-postrebase.log
- was: `20261103/cloudflare-gateway/73/20-test_core-postrebase.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `400044fe23b7284fef23dee58684a66c3d1d2875398581260e049c87b0862820`
- captured: 2026-11-03T15:51:47Z
- rebuild: `cd pluginpackages.koplugin && luajit test_core.lua`

## issue-20/73-download_probe.log
- was: `20261103/cloudflare-gateway/73/73-download_probe.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `9d876f7c901cbeb14821f3b072b3ad88aff60d1ccfc1dd23d0f35f024e5aa839`
- captured: 2026-11-03T15:35:21Z
- rebuild: `none: a recorded run`

## issue-20/73-download_probe.lua
- was: `20261103/cloudflare-gateway/73/73-download_probe.lua` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `b425c35fd3ea7d3fc8cdc04cdc3b21180fc8762f245edd268e80858b089410b0`
- captured: 2026-11-03T15:35:09Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-20/73-download_probe.lua | luajit -`

## issue-20/73-github-dry-run.log
- was: `20261103/cloudflare-gateway/73/73-github-dry-run.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `ba3ec2cb27f64c965a68fb737e474ca1e98008140a1b013770a2ef92ea884b48`
- captured: 2026-11-03T15:38:28Z
- rebuild: `none: a recorded run`

## issue-20/73-github-dry-run.sh
- was: `20261103/cloudflare-gateway/73/73-github-dry-run.sh` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `bb6b3fa3073d7799f15ee80fdf68d596b035092fd28ae1d9c1925d6c207c6a7a`
- captured: 2026-11-03T15:38:27Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-20/73-github-dry-run.sh | bash -s`

## issue-20/73-local-mode-diff.log
- was: `20261103/cloudflare-gateway/73/73-local-mode-diff.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `ef3019f5de8a13e63f8272b3e7a0348e3165b4e745dae20e63056e4111ad80ec`
- captured: 2026-11-03T15:38:15Z
- rebuild: `none: a recorded run`

## issue-20/73-local-mode-diff.sh
- was: `20261103/cloudflare-gateway/73/73-local-mode-diff.sh` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `0686dc63f96068fbd3f1e500f15c2f705435bb9e841faf09a32af8dd071a88b9`
- captured: 2026-11-03T15:38:14Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-20/73-local-mode-diff.sh | bash -s`

## issue-20/73-registry_parse.log
- was: `20261103/cloudflare-gateway/73/73-registry_parse.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `21f05ee926d141dd4ed715716fc7a675d026120898e182b1b30b4415274faf74`
- captured: 2026-11-03T15:51:52Z
- rebuild: `none: a recorded run`

## issue-20/73-registry_parse.lua
- was: `20261103/cloudflare-gateway/73/73-registry_parse.lua` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `974dc7e5b9cb8f8f522ea513885c403f7d3a8bcc7632a05e1f98c5f756b41aad`
- captured: 2026-11-03T15:51:52Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-20/73-registry_parse.lua | luajit -`

## issue-20/73-release-command.sh
- was: `20261103/cloudflare-gateway/73/73-release-command.sh` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `c31b42738f4ccd5b8c6937d37430eae20d6c3b446a7673b0e973feabc8cd9771`
- captured: 2026-11-03T15:51:58Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-20/73-release-command.sh | bash -s`

## issue-20/73-test_core.log
- was: `20261103/cloudflare-gateway/73/73-test_core.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `400044fe23b7284fef23dee58684a66c3d1d2875398581260e049c87b0862820`
- captured: 2026-11-03T15:33:52Z
- rebuild: `cd pluginpackages.koplugin && luajit test_core.lua`

## issue-21/02-r2-create.log
- was: `20261103/cloudflare-gateway/74/02-r2-create.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `f783af3cb8afbc912c7d61b00dcd0ba4073526bdd1960bd8c5a0a2b217105b1f`
- captured: 2026-11-03T16:15:52Z
- rebuild: `none: a recorded run`

## issue-21/08-smoke.log
- was: `20261103/cloudflare-gateway/74/08-smoke.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `53d93063c4fc1330697e883c470bba77f411d2ab85cb29177efa850ad4b34e23`
- captured: 2026-11-03T16:18:07Z
- rebuild: `none: a recorded run`

## issue-21/10-before-localgw.log
- was: `20261103/cloudflare-gateway/74/10-before-localgw.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `b60a1b10b8296b43e76ecec6eb9b912b7dff07e5ad8b72fa2eaba404259379db`
- captured: 2026-11-03T16:19:07Z
- rebuild: `none: a recorded run`

## issue-21/11-localgw-recent-log.txt
- was: `20261103/cloudflare-gateway/74/11-localgw-recent-log.txt` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `42f006ea1a4b699dee908c274c00edff0fa4c8efd2160b52cfe758e5f6b678d9`
- captured: 2026-11-03T16:19:14Z
- rebuild: `none: a recorded run`

## issue-21/13-restart-via-localgw.log
- was: `20261103/cloudflare-gateway/74/13-restart-via-localgw.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `80db7e6a6b7c00cb49cc899f04e9e10af6871c84cad9fef2374580e6314e9865`
- captured: 2026-11-03T16:21:15Z
- rebuild: `none: a recorded run`

## issue-21/15-sigkill.log
- was: `20261103/cloudflare-gateway/74/15-sigkill.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `4bbf74a1564a3b0e71eb02a7d4d0b4d0f49c264b5dfbe871942798d5c4c71ebc`
- captured: 2026-11-03T16:21:58Z
- rebuild: `none: a recorded run`

## issue-21/20-e2e-legacy.log
- was: `20261103/cloudflare-gateway/74/20-e2e-legacy.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `3007574162f5ed5d99fdec999891b68a83257e6ca2cf6f8d9bdffad6a0fd70f6`
- captured: 2026-11-03T16:22:41Z
- rebuild: `none: a recorded run`

## issue-21/20-e2e-modern-attempt1-network-timeout.log
- was: `20261103/cloudflare-gateway/74/20-e2e-modern-attempt1-network-timeout.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `297134cae81d011075d75cfad2a7316340c5a67fe9bdd91955a748ac9bd9d764`
- captured: 2026-11-03T16:22:42Z
- rebuild: `none: a recorded run`

## issue-21/20-e2e-modern.log
- was: `20261103/cloudflare-gateway/74/20-e2e-modern.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `8362cbb1fa9da3ba3090474cc2ee17a725f043b03b74ad1722a2b11b42c35cc3`
- captured: 2026-11-03T16:23:12Z
- rebuild: `none: a recorded run`

## issue-21/21-e2e-ui-action.log
- was: `20261103/cloudflare-gateway/74/21-e2e-ui-action.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `b6bb197ca7859fd002c091fe89f93865e7421cc4fe8f5a933c9c7355e2eba31e`
- captured: 2026-11-03T16:23:44Z
- rebuild: `none: a recorded run`

## issue-21/22-inbox-and-registry.log
- was: `20261103/cloudflare-gateway/74/22-inbox-and-registry.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `11f73761aa6cfacc620ba91e51a8c73a2beedb19a51578ee9a0a1facdb1d273c`
- captured: 2026-11-03T16:24:00Z
- rebuild: `none: a recorded run`

## issue-21/31-analytics-all.json
- was: `20261103/cloudflare-gateway/74/31-analytics-all.json` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `583141895a18ef8ed128e4a32c3ad47703ea1aae711d3a78a6359b751db99921`
- captured: 2026-11-03T16:41:20Z
- rebuild: `none: a recorded run`

## issue-21/31-analytics-idle.json
- was: `20261103/cloudflare-gateway/74/31-analytics-idle.json` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `fa4d7a7c5d8c6434900eb505403d1a5f95ae5d3fac7d6a2bf23143772c14309a`
- captured: 2026-11-03T16:41:19Z
- rebuild: `none: a recorded run`

## issue-21/32-analytics-per-minute.json
- was: `20261103/cloudflare-gateway/74/32-analytics-per-minute.json` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `7e0a7cbf7bb362d2430aae33df18b44730e55f1ad6c1b5874df317af7ff06f31`
- captured: 2026-11-03T16:41:35Z
- rebuild: `none: a recorded run`

## issue-21/40-restore.log
- was: `20261103/cloudflare-gateway/74/40-restore.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `d481125ec8de25f0609036144ab2056bbd1115b6fae0064d5275e9ef24cd24fa`
- captured: 2026-11-03T16:42:37Z
- rebuild: `none: a recorded run`

## issue-21/41-restored-localgw.log
- was: `20261103/cloudflare-gateway/74/41-restored-localgw.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `3792767903e5cf00dc54c4ce0f02b581d0a11fa42ccc89bf7b1f9cbf9285dced`
- captured: 2026-11-03T16:42:42Z
- rebuild: `none: a recorded run`

## issue-21/42-worker-after-restore.log
- was: `20261103/cloudflare-gateway/74/42-worker-after-restore.log` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `ad8f859ad6de5eff1782607d36f49f4d76ab400242ea1699bf9f162ebed2d1da`
- captured: 2026-11-03T16:42:53Z
- rebuild: `none: a recorded run`

## issue-21/analytics.py
- was: `20261103/cloudflare-gateway/74/analytics.py` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `69e45bc9a87e3ce04662e80aa05d457b710b65355cb6a0a61235eae2d4cfa537`
- captured: 2026-11-03T16:24:15Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-21/analytics.py | python3 -`

## issue-21/cfenv.sh
- was: `20261103/cloudflare-gateway/74/cfenv.sh` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `6778df5d7f6683c537755a8d02e587fc26f9d6a5b52eb098cbee8f1fe794ad9b`
- captured: 2026-11-03T16:15:15Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-21/cfenv.sh | bash -s`

## issue-21/e2e-client.mjs
- was: `20261103/cloudflare-gateway/74/e2e-client.mjs` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `ff17f71722f6bdf51c6255e86d1eaf08b0f177b8fa825872202e944639f0ff41`
- captured: 2026-11-03T16:22:26Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-21/e2e-client.mjs | node --input-type=module -`

## issue-21/emu-point.sh
- was: `20261103/cloudflare-gateway/74/emu-point.sh` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `f34a276aa83246e128065f9cf1c3c4e940c3d8a696cd943c2963efa406926ba7`
- captured: 2026-11-03T16:19:25Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-21/emu-point.sh | bash -s`

## issue-21/local-gw.sh
- was: `20261103/cloudflare-gateway/74/local-gw.sh` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `534692dbf3f7fa82078dffc8441dc8759ac5428789e7dade14a1882eb6583089`
- captured: 2026-11-03T16:19:05Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-21/local-gw.sh | bash -s`

## issue-21/smoke.sh
- was: `20261103/cloudflare-gateway/74/smoke.sh` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `9e5a441bebc66b083c41163e07a56d07be3dd7f2d7976c9978d8316de64f350e`
- captured: 2026-11-03T16:18:00Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-21/smoke.sh | bash -s`

## issue-21/ui-action.mjs
- was: `20261103/cloudflare-gateway/74/ui-action.mjs` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `f24cb4b3ba19a06c21a9d4772179fcdc0d8c85342cc836ac8d2e2dcca099e7de`
- captured: 2026-11-03T16:23:28Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/issue-21/ui-action.mjs | node --input-type=module -`

## issue-21/wrangler.no-r2.jsonc
- was: `20261103/cloudflare-gateway/74/wrangler.no-r2.jsonc` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `98030f4ef2151a5482dc5b7bf6596cac59895184c2033646869aebf0cd558f1a`
- captured: 2026-11-03T16:16:09Z
- rebuild: `none: a recorded run`

## shared/sni_probe.lua
- was: `20261103/cloudflare-gateway/sni_probe.lua` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `883f4e33b7ce248fef203c249a161a3bbe1cafbb9e7180f2ea5fe7ffb60dd9cb`
- captured: 2026-11-03T15:26:30Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/shared/sni_probe.lua | luajit -`

## shared/subissues.sh
- was: `20261103/cloudflare-gateway/subissues.sh` in the 20261103/cloudflare-gateway topic folder
- handling: snapshot
- pin: sha256 `84f42d88f10387609e5da97720ab520ce04c78bc41d6f49d4009115b1becf749`
- captured: 2026-11-03T15:26:30Z
- rebuild: `envscan hydrate evidence/20261103-cloudflare-gateway/shared/subissues.sh | bash -s`

## issue-20/archives/SHA256SUMS (pointer only)
- was: `20261103/cloudflare-gateway/73/archives/SHA256SUMS` in the 20261103/cloudflare-gateway topic folder
- handling: cache
- pin: sha256 `eae84eb33da5685a11c371ff7048ef1306b6ed78eb4275f85245f269ccf3b6c2`
- captured: 2026-11-03T15:38:28Z
- rebuild: `scripts/publish.sh --dry-run (archives, index.json, SHA256SUMS)`

## issue-20/archives/pluginpackages-0.2.0.tar.gz (pointer only)
- was: `20261103/cloudflare-gateway/73/archives/pluginpackages-0.2.0.tar.gz` in the 20261103/cloudflare-gateway topic folder
- handling: cache
- pin: sha256 `5bfca3e141b1590d9cce7f02f07fa825e692dea79f45df704c1afc3e00b2f65d`
- captured: 2026-11-03T15:38:28Z
- rebuild: `scripts/publish.sh --dry-run (archives, index.json, SHA256SUMS)`

## issue-20/archives/syncedhistory-0.2.0.tar.gz (pointer only)
- was: `20261103/cloudflare-gateway/73/archives/syncedhistory-0.2.0.tar.gz` in the 20261103/cloudflare-gateway topic folder
- handling: cache
- pin: sha256 `aad7aa2cd2854d53c70b883270ff860728f80dfa5f17714beb255d6a975f9a1e`
- captured: 2026-11-03T15:38:28Z
- rebuild: `scripts/publish.sh --dry-run (archives, index.json, SHA256SUMS)`

## issue-20/github-build1/pluginpackages-0.2.0.tar.gz (pointer only)
- was: `20261103/cloudflare-gateway/73/github-build1/pluginpackages-0.2.0.tar.gz` in the 20261103/cloudflare-gateway topic folder
- handling: cache
- pin: sha256 `5bfca3e141b1590d9cce7f02f07fa825e692dea79f45df704c1afc3e00b2f65d`
- captured: 2026-11-03T15:38:28Z
- rebuild: `scripts/publish.sh --github --dry-run (archives, index.json)`

## issue-20/github-build1/syncedhistory-0.2.0.tar.gz (pointer only)
- was: `20261103/cloudflare-gateway/73/github-build1/syncedhistory-0.2.0.tar.gz` in the 20261103/cloudflare-gateway topic folder
- handling: cache
- pin: sha256 `aad7aa2cd2854d53c70b883270ff860728f80dfa5f17714beb255d6a975f9a1e`
- captured: 2026-11-03T15:38:27Z
- rebuild: `scripts/publish.sh --github --dry-run (archives, index.json)`

## issue-20/github-build2/index.json (pointer only)
- was: `20261103/cloudflare-gateway/73/github-build2/index.json` in the 20261103/cloudflare-gateway topic folder
- handling: cache
- pin: sha256 `362b10276e578a76ea4a4caf58d61a93af4c2445bd5baba156e1d9afb25184ca`
- captured: 2026-11-03T15:38:28Z
- rebuild: `scripts/publish.sh --github --dry-run (archives, index.json)`

## issue-20/github-build2/pluginpackages-0.2.0.tar.gz (pointer only)
- was: `20261103/cloudflare-gateway/73/github-build2/pluginpackages-0.2.0.tar.gz` in the 20261103/cloudflare-gateway topic folder
- handling: cache
- pin: sha256 `5bfca3e141b1590d9cce7f02f07fa825e692dea79f45df704c1afc3e00b2f65d`
- captured: 2026-11-03T15:38:28Z
- rebuild: `scripts/publish.sh --github --dry-run (archives, index.json)`

## issue-20/github-build2/syncedhistory-0.2.0.tar.gz (pointer only)
- was: `20261103/cloudflare-gateway/73/github-build2/syncedhistory-0.2.0.tar.gz` in the 20261103/cloudflare-gateway topic folder
- handling: cache
- pin: sha256 `aad7aa2cd2854d53c70b883270ff860728f80dfa5f17714beb255d6a975f9a1e`
- captured: 2026-11-03T15:38:28Z
- rebuild: `scripts/publish.sh --github --dry-run (archives, index.json)`

## issue-20/local-mode/branch/index.json (pointer only)
- was: `20261103/cloudflare-gateway/73/local-mode/branch/index.json` in the 20261103/cloudflare-gateway topic folder
- handling: cache
- pin: sha256 `67e5b61653f467e378b242e43397e9d7921007555294577ee89dcfc79dc516bd`
- captured: 2026-11-03T15:38:15Z
- rebuild: `scripts/publish.sh --dry-run (archives, index.json, SHA256SUMS)`

## issue-20/local-mode/branch/pluginpackages-0.2.0.tar.gz (pointer only)
- was: `20261103/cloudflare-gateway/73/local-mode/branch/pluginpackages-0.2.0.tar.gz` in the 20261103/cloudflare-gateway topic folder
- handling: cache
- pin: sha256 `5bfca3e141b1590d9cce7f02f07fa825e692dea79f45df704c1afc3e00b2f65d`
- captured: 2026-11-03T15:38:14Z
- rebuild: `scripts/publish.sh --dry-run (archives, index.json, SHA256SUMS)`

## issue-20/local-mode/branch/syncedhistory-0.2.0.tar.gz (pointer only)
- was: `20261103/cloudflare-gateway/73/local-mode/branch/syncedhistory-0.2.0.tar.gz` in the 20261103/cloudflare-gateway topic folder
- handling: cache
- pin: sha256 `aad7aa2cd2854d53c70b883270ff860728f80dfa5f17714beb255d6a975f9a1e`
- captured: 2026-11-03T15:38:14Z
- rebuild: `scripts/publish.sh --dry-run (archives, index.json, SHA256SUMS)`

## issue-20/local-mode/main/index.json (pointer only)
- was: `20261103/cloudflare-gateway/73/local-mode/main/index.json` in the 20261103/cloudflare-gateway topic folder
- handling: cache
- pin: sha256 `67e5b61653f467e378b242e43397e9d7921007555294577ee89dcfc79dc516bd`
- captured: 2026-11-03T15:38:14Z
- rebuild: `scripts/publish.sh --dry-run (archives, index.json, SHA256SUMS)`

## issue-20/local-mode/main/pluginpackages-0.2.0.tar.gz (pointer only)
- was: `20261103/cloudflare-gateway/73/local-mode/main/pluginpackages-0.2.0.tar.gz` in the 20261103/cloudflare-gateway topic folder
- handling: cache
- pin: sha256 `5bfca3e141b1590d9cce7f02f07fa825e692dea79f45df704c1afc3e00b2f65d`
- captured: 2026-11-03T15:38:14Z
- rebuild: `scripts/publish.sh --dry-run (archives, index.json, SHA256SUMS)`

## issue-20/local-mode/main/syncedhistory-0.2.0.tar.gz (pointer only)
- was: `20261103/cloudflare-gateway/73/local-mode/main/syncedhistory-0.2.0.tar.gz` in the 20261103/cloudflare-gateway topic folder
- handling: cache
- pin: sha256 `aad7aa2cd2854d53c70b883270ff860728f80dfa5f17714beb255d6a975f9a1e`
- captured: 2026-11-03T15:38:14Z
- rebuild: `scripts/publish.sh --dry-run (archives, index.json, SHA256SUMS)`

## issue-20/main-publish/publish.sh (pointer only)
- was: `20261103/cloudflare-gateway/73/main-publish/publish.sh` in the 20261103/cloudflare-gateway topic folder
- handling: cache
- pin: sha256 `3a64fc5af285259a3e2fe0163b14543e73ff6c2235abae636b52e3852c81f595`
- captured: 2026-11-03T15:36:56Z
- rebuild: `git show 66119a84d4891967e7b21c0fb99e9717e39ae764^1:scripts/publish.sh`

## issue-20/postrebase/index.json (pointer only)
- was: `20261103/cloudflare-gateway/73/postrebase/index.json` in the 20261103/cloudflare-gateway topic folder
- handling: cache
- pin: sha256 `362b10276e578a76ea4a4caf58d61a93af4c2445bd5baba156e1d9afb25184ca`
- captured: 2026-11-03T15:52:05Z
- rebuild: `scripts/publish.sh --github --dry-run (archives, index.json)`

## issue-20/postrebase/pluginpackages-0.2.0.tar.gz (pointer only)
- was: `20261103/cloudflare-gateway/73/postrebase/pluginpackages-0.2.0.tar.gz` in the 20261103/cloudflare-gateway topic folder
- handling: cache
- pin: sha256 `5bfca3e141b1590d9cce7f02f07fa825e692dea79f45df704c1afc3e00b2f65d`
- captured: 2026-11-03T15:52:04Z
- rebuild: `scripts/publish.sh --github --dry-run (archives, index.json)`

## issue-20/postrebase/syncedhistory-0.2.0.tar.gz (pointer only)
- was: `20261103/cloudflare-gateway/73/postrebase/syncedhistory-0.2.0.tar.gz` in the 20261103/cloudflare-gateway topic folder
- handling: cache
- pin: sha256 `aad7aa2cd2854d53c70b883270ff860728f80dfa5f17714beb255d6a975f9a1e`
- captured: 2026-11-03T15:52:04Z
- rebuild: `scripts/publish.sh --github --dry-run (archives, index.json)`
