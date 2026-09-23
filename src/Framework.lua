--!strict
-- Framework - module loader with a two-phase boot.
--
-- Add(folder) registers every ModuleScript in it.
-- Start() runs Init on all of them, then Start on all of them.
-- Get(name) looks one up by name from anywhere.
--
-- Two phases exist so a system can set up its own state (Init) before
-- any other system tries to reach it (Start). Never call Get in Init.

local Framework = {}

local systems: { [string]: any } = {}
local order: { any } = {}
local started = false

--==============================================================
-- Registration
--==============================================================

local function register(module: ModuleScript)
	local ok, result = pcall(require, module)
	if not ok then
		error(`[Framework] failed to require {module:GetFullName()}: {result}`, 0)
	end
	if typeof(result) ~= "table" then
		error(`[Framework] {module:GetFullName()} did not return a table`, 0)
	end

	local name = result.Name or module.Name
	if systems[name] then
		error(`[Framework] duplicate system name "{name}" ({module:GetFullName()})`, 0)
	end

	result.Name = name
	systems[name] = result
	table.insert(order, result)
end

-- Registers every ModuleScript directly inside `folder`.
function Framework.Add(folder: Instance)
	assert(not started, "[Framework] cannot Add after Start")

	for _, child in folder:GetChildren() do
		if child:IsA("ModuleScript") then
			register(child)
		end
	end
end

-- Same, but descends into subfolders.
function Framework.AddDeep(folder: Instance)
	assert(not started, "[Framework] cannot Add after Start")

	for _, descendant in folder:GetDescendants() do
		if descendant:IsA("ModuleScript") then
			register(descendant)
		end
	end
end

--==============================================================
-- Lookup
--==============================================================

function Framework.Get(name: string): any
	local system = systems[name]
	if not system then
		error(`[Framework] unknown system "{name}"`, 2)
	end
	return system
end

function Framework.IsStarted(): boolean
	return started
end


-- Boot
function Framework.Start()
	assert(not started, "[Framework] already started")
	started = true

	-- phase 1
	for _, system in order do
		if system.Init then
			local ok, err = pcall(system.Init, system)
			if not ok then
				warn(`[Framework] {system.Name}:Init errored: {err}`)
			end
		end
	end

	-- phase 2
	for _, system in order do
		if system.Start then
			task.spawn(function()
				local ok, err = pcall(system.Start, system)
				if not ok then
					warn(`[Framework] {system.Name}:Start errored: {err}`)
				end
			end)
		end
	end
end

return Framework
