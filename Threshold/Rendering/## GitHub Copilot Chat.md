## GitHub Copilot Chat

- Extension: 0.43.0 (prod)
- VS Code: 1.115.0 (41dd792b5e652393e7787322889ed5fdc58bd75b)
- OS: darwin 25.2.0 arm64
- GitHub Account: Halopend

## Network

User Settings:
```json
  "http.systemCertificatesNode": false,
  "github.copilot.advanced.debug.useElectronFetcher": true,
  "github.copilot.advanced.debug.useNodeFetcher": false,
  "github.copilot.advanced.debug.useNodeFetchFetcher": true
```

Connecting to https://api.github.com:
- DNS ipv4 Lookup: 140.82.113.6 (1 ms)
- DNS ipv6 Lookup: ::ffff:140.82.113.6 (2 ms)
- Proxy URL: None (0 ms)
- Electron fetch (configured): Error (9 ms): Error: net::ERR_ADDRESS_INVALID
	at SimpleURLLoaderWrapper.<anonymous> (node:electron/js2c/utility_init:2:10684)
	at SimpleURLLoaderWrapper.emit (node:events:519:28)
  {"is_request_error":true,"network_process_crashed":false}
- Node.js https: Error (15 ms): Error: connect EADDRNOTAVAIL 140.82.113.6:443 - Local (0.0.0.0:0)
	at internalConnect (node:net:1110:16)
	at defaultTriggerAsyncIdScope (node:internal/async_hooks:472:18)
	at GetAddrInfoReqWrap.emitLookup [as callback] (node:net:1523:9)
	at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:134:8)
- Node.js fetch: Error (14 ms): TypeError: fetch failed
	at node:internal/deps/undici/undici:14902:13
	at process.processTicksAndRejections (node:internal/process/task_queues:103:5)
	at async t._fetch (/Users/halopend/.vscode/extensions/github.copilot-chat-0.43.0/dist/extension.js:5293:5228)
	at async t.fetch (/Users/halopend/.vscode/extensions/github.copilot-chat-0.43.0/dist/extension.js:5293:4540)
	at async u (/Users/halopend/.vscode/extensions/github.copilot-chat-0.43.0/dist/extension.js:5325:186)
	at async Sg._executeContributedCommand (file:///Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/workbench/api/node/extensionHostProcess.js:501:48675)
  Error: connect EADDRNOTAVAIL 140.82.113.6:443 - Local (0.0.0.0:0)
  	at internalConnect (node:net:1110:16)
  	at defaultTriggerAsyncIdScope (node:internal/async_hooks:472:18)
  	at GetAddrInfoReqWrap.emitLookup [as callback] (node:net:1523:9)
  	at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:134:8)

Connecting to https://api.githubcopilot.com/_ping:
- DNS ipv4 Lookup: 140.82.114.21 (11 ms)
- DNS ipv6 Lookup: ::ffff:140.82.114.21 (2 ms)
- Proxy URL: None (1 ms)
- Electron fetch (configured): Error (7 ms): Error: net::ERR_ADDRESS_INVALID
	at SimpleURLLoaderWrapper.<anonymous> (node:electron/js2c/utility_init:2:10684)
	at SimpleURLLoaderWrapper.emit (node:events:519:28)
  {"is_request_error":true,"network_process_crashed":false}
- Node.js https: Error (10 ms): Error: connect EADDRNOTAVAIL 140.82.114.21:443 - Local (0.0.0.0:0)
	at internalConnect (node:net:1110:16)
	at defaultTriggerAsyncIdScope (node:internal/async_hooks:472:18)
	at GetAddrInfoReqWrap.emitLookup [as callback] (node:net:1523:9)
	at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:134:8)
- Node.js fetch: Error (13 ms): TypeError: fetch failed
	at node:internal/deps/undici/undici:14902:13
	at process.processTicksAndRejections (node:internal/process/task_queues:103:5)
	at async t._fetch (/Users/halopend/.vscode/extensions/github.copilot-chat-0.43.0/dist/extension.js:5293:5228)
	at async t.fetch (/Users/halopend/.vscode/extensions/github.copilot-chat-0.43.0/dist/extension.js:5293:4540)
	at async u (/Users/halopend/.vscode/extensions/github.copilot-chat-0.43.0/dist/extension.js:5325:186)
	at async Sg._executeContributedCommand (file:///Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/workbench/api/node/extensionHostProcess.js:501:48675)
  Error: connect EADDRNOTAVAIL 140.82.114.21:443 - Local (0.0.0.0:0)
  	at internalConnect (node:net:1110:16)
  	at defaultTriggerAsyncIdScope (node:internal/async_hooks:472:18)
  	at GetAddrInfoReqWrap.emitLookup [as callback] (node:net:1523:9)
  	at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:134:8)

Connecting to https://copilot-proxy.githubusercontent.com/_ping:
- DNS ipv4 Lookup: 4.249.131.160 (9 ms)
- DNS ipv6 Lookup: ::ffff:4.249.131.160 (3 ms)
- Proxy URL: None (3 ms)
- Electron fetch (configured): Error (12 ms): Error: net::ERR_ADDRESS_INVALID
	at SimpleURLLoaderWrapper.<anonymous> (node:electron/js2c/utility_init:2:10684)
	at SimpleURLLoaderWrapper.emit (node:events:519:28)
  {"is_request_error":true,"network_process_crashed":false}
- Node.js https: Error (10 ms): Error: connect EADDRNOTAVAIL 4.249.131.160:443 - Local (0.0.0.0:0)
	at internalConnect (node:net:1110:16)
	at defaultTriggerAsyncIdScope (node:internal/async_hooks:472:18)
	at GetAddrInfoReqWrap.emitLookup [as callback] (node:net:1523:9)
	at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:134:8)
- Node.js fetch: Error (13 ms): TypeError: fetch failed
	at node:internal/deps/undici/undici:14902:13
	at process.processTicksAndRejections (node:internal/process/task_queues:103:5)
	at async t._fetch (/Users/halopend/.vscode/extensions/github.copilot-chat-0.43.0/dist/extension.js:5293:5228)
	at async t.fetch (/Users/halopend/.vscode/extensions/github.copilot-chat-0.43.0/dist/extension.js:5293:4540)
	at async u (/Users/halopend/.vscode/extensions/github.copilot-chat-0.43.0/dist/extension.js:5325:186)
	at async Sg._executeContributedCommand (file:///Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/workbench/api/node/extensionHostProcess.js:501:48675)
  Error: connect EADDRNOTAVAIL 4.249.131.160:443 - Local (0.0.0.0:0)
  	at internalConnect (node:net:1110:16)
  	at defaultTriggerAsyncIdScope (node:internal/async_hooks:472:18)
  	at GetAddrInfoReqWrap.emitLookup [as callback] (node:net:1523:9)
  	at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:134:8)

Connecting to https://mobile.events.data.microsoft.com: Error (7 ms): Error: net::ERR_ADDRESS_INVALID
	at SimpleURLLoaderWrapper.<anonymous> (node:electron/js2c/utility_init:2:10684)
	at SimpleURLLoaderWrapper.emit (node:events:519:28)
  {"is_request_error":true,"network_process_crashed":false}
Connecting to https://dc.services.visualstudio.com: Error (12 ms): Error: net::ERR_ADDRESS_INVALID
	at SimpleURLLoaderWrapper.<anonymous> (node:electron/js2c/utility_init:2:10684)
	at SimpleURLLoaderWrapper.emit (node:events:519:28)
  {"is_request_error":true,"network_process_crashed":false}
Connecting to https://copilot-telemetry.githubusercontent.com/_ping: Error (12 ms): Error: connect EADDRNOTAVAIL 140.82.114.21:443 - Local (0.0.0.0:0)
	at internalConnect (node:net:1110:16)
	at defaultTriggerAsyncIdScope (node:internal/async_hooks:472:18)
	at GetAddrInfoReqWrap.emitLookup [as callback] (node:net:1523:9)
	at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:134:8)
Connecting to https://copilot-telemetry.githubusercontent.com/_ping: Error (11 ms): Error: connect EADDRNOTAVAIL 140.82.114.21:443 - Local (0.0.0.0:0)
	at internalConnect (node:net:1110:16)
	at defaultTriggerAsyncIdScope (node:internal/async_hooks:472:18)
	at GetAddrInfoReqWrap.emitLookup [as callback] (node:net:1523:9)
	at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:134:8)
Connecting to https://default.exp-tas.com: Error (11 ms): Error: connect EADDRNOTAVAIL 13.107.13.93:443 - Local (0.0.0.0:0)
	at internalConnect (node:net:1110:16)
	at defaultTriggerAsyncIdScope (node:internal/async_hooks:472:18)
	at GetAddrInfoReqWrap.emitLookup [as callback] (node:net:1523:9)
	at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:134:8)

Number of system certificates: 8

## Documentation

In corporate networks: [Troubleshooting firewall settings for GitHub Copilot](https://docs.github.com/en/copilot/troubleshooting-github-copilot/troubleshooting-firewall-settings-for-github-copilot).