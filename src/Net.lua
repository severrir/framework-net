--!strict
-- Net - lightweight networking wrapper
-- Same module on server and client. Declare remotes by name, no manual creation.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local IS_SERVER = RunService:IsServer()

local Net = {}
Net.Debug = false

-- Optional server-side hooks, nil by default so plain Net behaves exactly like before.
-- Middleware(player, name, ...) runs after cooldown + type checks pass. Return false to drop the call.
-- OnReject(player, name, reason) runs whenever a call is dropped ("cooldown" or "types").
Net.Middleware = nil :: ((Player, string, ...any) -> boolean)?
Net.OnReject = nil :: ((Player, string, string) -> ())?

--==============================================================
-- Remote container
--==============================================================

local folder: Folder

if IS_SERVER then
	local existing = ReplicatedStorage:FindFirstChild("_Net")
	if existing then
		folder = existing :: Folder
	else
		folder = Instance.new("Folder")
		folder.Name = "_Net"
		folder.Parent = ReplicatedStorage
	end
else
	folder = ReplicatedStorage:WaitForChild("_Net") :: Folder
end

local function getRemote(name: string, className: string): Instance
	if IS_SERVER then
		local r = folder:FindFirstChild(name)
		if not r then
			r = Instance.new(className)
			r.Name = name
			r.Parent = folder
		end
		return r
	end

	local r = folder:WaitForChild(name, 10)
	if not r then
		error(`[Net] remote "{name}" never replicated`)
	end
	return r
end

--==============================================================
-- Rate limiting
--==============================================================

local lastCall: { [Player]: { [string]: number } } = {}

Players.PlayerRemoving:Connect(function(player)
	lastCall[player] = nil
end)

local function allowed(player: Player, key: string, cooldown: number): boolean
	if cooldown <= 0 then
		return true
	end

	local map = lastCall[player]
	if not map then
		map = {}
		lastCall[player] = map
	end

	local now = os.clock()
	local previous = map[key]
	if previous and now - previous < cooldown then
		return false
	end

	map[key] = now
	return true
end

--==============================================================
-- Hooks
--==============================================================

local function reject(player: Player, name: string, reason: string)
	local hook = Net.OnReject
	if hook then
		local ok, err = pcall(hook, player, name, reason)
		if not ok then
			warn(`[Net] OnReject errored: {err}`)
		end
	end
end

local function passes(player: Player, name: string, ...: any): boolean
	local hook = Net.Middleware
	if not hook then
		return true
	end
	local ok, result = pcall(hook, player, name, ...)
	if not ok then
		-- a broken hook should never break the game's remotes
		warn(`[Net] Middleware errored: {result}`)
		return true
	end
	return result ~= false
end

--==============================================================
-- Type validation
--==============================================================

local function typesOk(types: { string }?, ...: any): boolean
	if not types then
		return true
	end

	local args = table.pack(...)
	if args.n ~= #types then
		return false
	end

	for i, expected in types do
		local value = args[i]
		if typeof(value) ~= expected then
			return false
		end
		-- reject NaN, which passes every numeric comparison
		if expected == "number" and value ~= value then
			return false
		end
	end

	return true
end

--==============================================================
-- Event
--==============================================================

local Event = {}
Event.__index = Event

function Event:Expect(...: string)
	self._types = { ... }
	return self
end

function Event:Fire(player: Player, ...: any)
	assert(IS_SERVER, "Net: Fire is server-only (use FireServer on the client)")
	if Net.Debug then
		print(`[Net] -> {player.Name} {self._name}`, ...)
	end
	self._remote:FireClient(player, ...)
end

function Event:FireAll(...: any)
	assert(IS_SERVER, "Net: FireAll is server-only")
	if Net.Debug then
		print(`[Net] -> all {self._name}`, ...)
	end
	self._remote:FireAllClients(...)
end

function Event:FireExcept(except: Player, ...: any)
	assert(IS_SERVER, "Net: FireExcept is server-only")
	for _, player in Players:GetPlayers() do
		if player ~= except then
			self._remote:FireClient(player, ...)
		end
	end
end

function Event:FireServer(...: any)
	assert(not IS_SERVER, "Net: FireServer is client-only")
	if Net.Debug then
		print(`[Net] -> server {self._name}`, ...)
	end
	self._remote:FireServer(...)
end

function Event:Listen(callback: (...any) -> ()): RBXScriptConnection
	if IS_SERVER then
		return self._remote.OnServerEvent:Connect(function(player: Player, ...)
			if not allowed(player, self._name, self._cooldown) then
				reject(player, self._name, "cooldown")
				return
			end
			if not typesOk(self._types, ...) then
				if Net.Debug then
					warn(`[Net] {self._name} rejected bad args from {player.Name}`)
				end
				reject(player, self._name, "types")
				return
			end
			if not passes(player, self._name, ...) then
				return
			end

			local ok, err = pcall(callback, player, ...)
			if not ok then
				warn(`[Net] {self._name} handler errored: {err}`)
			end
		end)
	end

	return self._remote.OnClientEvent:Connect(function(...)
		local ok, err = pcall(callback, ...)
		if not ok then
			warn(`[Net] {self._name} handler errored: {err}`)
		end
	end)
end


-- Function

local Func = {}
Func.__index = Func

function Func:Expect(...: string)
	self._types = { ... }
	return self
end

function Func:Handle(callback: (Player, ...any) -> ...any)
	assert(IS_SERVER, "Net: Handle is server-only")

	self._remote.OnServerInvoke = function(player: Player, ...)
		if not allowed(player, self._name, self._cooldown) then
			reject(player, self._name, "cooldown")
			return nil
		end
		if not typesOk(self._types, ...) then
			if Net.Debug then
				warn(`[Net] {self._name} rejected bad args from {player.Name}`)
			end
			reject(player, self._name, "types")
			return nil
		end
		if not passes(player, self._name, ...) then
			return nil
		end

		local ok, result = pcall(callback, player, ...)
		if not ok then
			warn(`[Net] {self._name} handler errored: {result}`)
			return nil
		end
		return result
	end
end

function Func:Invoke(...: any): any
	assert(not IS_SERVER, "Net: Invoke is client-only")

	local ok, result = pcall(function(...)
		return self._remote:InvokeServer(...)
	end, ...)

	if not ok then
		warn(`[Net] {self._name} invoke failed: {result}`)
		return nil
	end
	return result
end

--==============================================================
-- Public
--==============================================================

local eventCache: { [string]: any } = {}
local funcCache: { [string]: any } = {}

type Spec = string | { name: string, cooldown: number? }

local function unpackSpec(spec: Spec): (string, number)
	if typeof(spec) == "string" then
		return spec, 0
	end
	return spec.name, spec.cooldown or 0
end

function Net.Event(spec: Spec)
	local name, cooldown = unpackSpec(spec)

	local cached = eventCache[name]
	if cached then
		return cached
	end

	local self = setmetatable({
		_remote = getRemote(name, "RemoteEvent") :: RemoteEvent,
		_name = name,
		_cooldown = cooldown,
		_types = nil,
	}, Event)

	eventCache[name] = self
	return self
end

function Net.Function(spec: Spec)
	local name, cooldown = unpackSpec(spec)

	local cached = funcCache[name]
	if cached then
		return cached
	end

	local self = setmetatable({
		_remote = getRemote(name, "RemoteFunction") :: RemoteFunction,
		_name = name,
		_cooldown = cooldown,
		_types = nil,
	}, Func)

	funcCache[name] = self
	return self
end

return Net
