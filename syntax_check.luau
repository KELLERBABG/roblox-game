--!nocheck
--[[
	Compiles every Luau file in this project with the real Luau compiler that
	Lune embeds, without executing it. Catches syntax errors that `rojo build`
	cannot see (Rojo only copies text, it never compiles).

	    lune run syntax_check

	`src/` is walked recursively rather than listed, so a module added to the
	ladder stack or anywhere else can never silently escape this check. Only the
	root-level harnesses are named explicitly.

	`Visuals/` is deliberately NOT included: it is owned by a separate
	workstream that may be mid-edit, and a transient failure there says nothing
	about this code.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local function collectLuau(root: string, into: { string }): ()
	for _, entry in ipairs(fs.readDir(root)) do
		local path = root .. "/" .. entry
		if fs.isDir(path) then
			collectLuau(path, into)
		elseif string.sub(entry, -5) == ".luau" then
			table.insert(into, path)
		end
	end
end

local targets: { string } = {}

collectLuau("src", targets)
table.sort(targets)

table.insert(targets, "syntax_check.luau")
table.insert(targets, "test_rollmath.luau")
table.insert(targets, "test_perks.luau")

local failures = 0

for _, path in ipairs(targets) do
	if not fs.isFile(path) then
		print(string.format("MISSING  %s", path))
		failures += 1
		continue
	end

	local source = fs.readFile(path)

	-- Wrap so a malformed `--[[ ]]` banner cannot swallow the chunk boundary.
	local chunk, compileError = loadstring("return function()\n" .. source .. "\nend")

	if chunk == nil then
		failures += 1
		print(string.format("ERROR    %s\n         %s", path, tostring(compileError)))
	else
		local lines = 0
		for _ in string.gmatch(source, "\n") do
			lines += 1
		end
		print(string.format("OK       %s  (%d lines)", path, lines + 1))
	end
end

print("")
if failures == 0 then
	print(string.format("ALL %d FILES COMPILE", #targets))
else
	print(string.format("%d of %d FILE(S) FAILED TO COMPILE", failures, #targets))
end

process.exit(failures == 0 and 0 or 1)
