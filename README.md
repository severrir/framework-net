# Framework & Net

Two small, standalone Luau modules for Roblox: a service loader with a
two-phase boot, and a typed, rate-limited networking wrapper. Extracted from
a larger project as generic, reusable building blocks.

## Framework.lua

A minimal module loader that registers ModuleScripts and boots them in two
phases:

1. Init - every registered system's Init runs first, in order,
   wrapped in pcall so one broken system doesn't halt boot.
2. Start - once every Init has finished, every system's Start runs
   concurrently via task.spawn.

The split exists so a system can set up its own state in Init without
risking that another system reaches into it before it's ready. Calling
Framework.Get(name) from inside Init is a bug by construction - nothing
is guaranteed to exist yet at that point.

```lua
local Framework = require(path.to.Framework)

Framework.AddDeep(ServerScriptService.Services)
Framework.Start()
```

## Net.lua

A thin wrapper around RemoteEvent/RemoteFunction that adds:

- Typed remotes - declare expected argument types with :Expect(...);
  mismatched calls are rejected server-side before your handler ever runs.
- Rate limiting - an optional per-remote cooldown, enforced per player.
- Debug logging - toggle Net.Debug to log fires, invokes, and
  rejected calls.
- No manual remote creation - remotes are created and cached lazily by
  name, identical API on client and server.

```lua
local Net = require(path.to.Net)

local SetName = Net.Function({ name = "SetName", cooldown = 0.5 })
	:Expect("string")

-- server
SetName:Handle(function(player, newName)
	return applyName(player, newName)
end)

-- client
local ok = SetName:Invoke("NewName")
```

If a client sends the wrong argument types, the call is dropped before the
handler runs - no error, no exploit path, no crash.

## Why these exist

Server-authoritative design only works if the server can trust nothing the
client sends. Net makes type-checking and rate-limiting the default
instead of something you have to remember to add per remote. Framework
makes boot order - a common source of race-condition bugs in larger Roblox
codebases - explicit and enforced rather than implicit.
