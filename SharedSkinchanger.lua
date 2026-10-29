-- Shared Skinchanger: players running this script see each other's skins, knives, StatTrak, name tags, agents, gloves,
-- and the killfeed icon / kill screen skin name of the weapon that killed them.
-- Each client reads what gamesense's own changers put on its weapons/player and sends it to the other players on the
-- server over Steam networking messages (through Valve's relay when no direct route exists). Incoming data goes into one table per player (remote / agents / gloves); the small appliers
-- below write it onto that player's weapons, model, gloves and the player_death event, all locally.

local ffi = require "ffi"

-- failures worth knowing about go to gamesense's error log, at most once per 30s per kind of message
local warned = {}
local function warn(kind, s)
	local now = globals.realtime()
	if warned[kind] and now - warned[kind] < 30 then return end
	warned[kind] = now
	client.error_log("[SharedSkins] " .. s)
end

-- ---- packet codec (pure Lua) -------------------------------------------------
-- weapon, 12 bytes: magic(1) defindex(2) paintkit(2) seed(2) wear(1, 0..255 -> 0..1) stattrak(4, 0xFFFFFFFF = none)
--   a souvenir weapon has its own magic and no stattrak (souvenir and StatTrak exclude each other)
-- agent,   3 bytes: magic(1) player model index(2); model indices match across clients on one server
-- name tag, 4..23 bytes: magic(1) key(2) text(1..20); key = weapon defindex, or 0 for "the knife" (a player has one)
local MAGIC, MAGIC_AGENT, MAGIC_NAME, MAGIC_SOUVENIR = 0xA9, 0xA8, 0xA7, 0xAA
local NAME_MAX = 20 -- the game's own name tag limit

local function clean_name(s) -- also used on text from the network, so strip control characters
	s = s:gsub("%c", ""):sub(1, NAME_MAX)
	return s ~= "" and s or nil
end

local function encode(defindex, paintkit, seed, wear, stattrak, souvenir)
	stattrak = not souvenir and stattrak and stattrak >= 0 and math.min(stattrak, 0xFFFFFFFE) or 0xFFFFFFFF
	return string.char(souvenir and MAGIC_SOUVENIR or MAGIC,
		defindex % 256, math.floor(defindex / 256),
		paintkit % 256, math.floor(paintkit / 256),
		seed % 256, math.floor(seed / 256),
		math.floor(math.min(math.max(wear, 0), 1) * 255 + 0.5),
		stattrak % 256, math.floor(stattrak / 256) % 256, math.floor(stattrak / 65536) % 256, math.floor(stattrak / 16777216))
end

local function decode(s)
	if #s == 3 and s:byte(1) == MAGIC_AGENT then return { agent = s:byte(2) + s:byte(3) * 256 } end
	if #s >= 4 and #s <= NAME_MAX + 3 and s:byte(1) == MAGIC_NAME then
		local n = clean_name(s:sub(4))
		return n and { name = n, key = s:byte(2) + s:byte(3) * 256 }
	end
	if #s ~= 12 then return end
	local m, d1, d2, p1, p2, s1, s2, w, t1, t2, t3, t4 = s:byte(1, 12)
	if m ~= MAGIC and m ~= MAGIC_SOUVENIR then return end -- untrusted input: ignore anything else
	local st = t1 + t2 * 256 + t3 * 65536 + t4 * 16777216
	return { defindex = d1 + d2 * 256, paintkit = p1 + p2 * 256, seed = s1 + s2 * 256, wear = w / 255,
		stattrak = st ~= 0xFFFFFFFF and st or -1, souvenir = m == MAGIC_SOUVENIR }
end

do -- self-check
	local t = decode(encode(7, 44, 661, 0.5, 1234567))
	assert(t and t.defindex == 7 and t.paintkit == 44 and t.seed == 661 and math.abs(t.wear - 0.5) < 0.01 and t.stattrak == 1234567)
	assert(decode(encode(7, 44, 661, 0.5)).stattrak == -1 and not decode(encode(7, 44, 661, 0.5)).souvenir)
	local sv = decode(encode(7, 44, 661, 0.5, 99, true)) -- a souvenir never carries a StatTrak counter
	assert(sv and sv.souvenir and sv.stattrak == -1 and sv.paintkit == 44)
	assert(decode("garbage!") == nil and decode("x") == nil and decode(("x"):rep(12)) == nil)
	local n = decode("\xA7\x09\x01Hello")
	assert(n and n.name == "Hello" and n.key == 265 and decode("\xA7\0\0") == nil and decode("\xA7\0\0a\1b").name == "ab")
	assert(decode("\xA7\0\0" .. ("n"):rep(NAME_MAX + 1)) == nil)
end

-- ---- UI + shared state ---------------------------------------------------------
-- the toggle lives in gamesense's Skins tab; fall back to the Lua tab if that container isn't available
local ok_ui, ui_enable = pcall(ui.new_checkbox, "SKINS", "Model options", "Shared skins")
if not ok_ui then ui_enable = ui.new_checkbox("LUA", "A", "Shared skins") end

local is_knife_def -- defined with the knife table below
-- the box edits the tag of the weapon we are holding (switching weapons shows that weapon's tag)
local ok_name = pcall(ui.new_label, "SKINS", "Weapon skin", "Name tag")
local ui_name
if ok_name then ui_name = ui.new_textbox("SKINS", "Weapon skin", "Name tag")
else
	ui.new_label("LUA", "A", "Name tag")
	ui_name = ui.new_textbox("LUA", "A", "Name tag")
end
-- Souvenir is per weapon, like the name tag: the checkbox shows (and edits) the held weapon's setting. A souvenir has
-- gold quality and no StatTrak counter; knives and gloves have none.
local ok_souv, ui_souvenir = pcall(ui.new_checkbox, "SKINS", "Weapon skin", "Souvenir")
if not ok_souv then ui_souvenir = ui.new_checkbox("LUA", "A", "Souvenir") end
local request_refresh -- defined with the apply code below: asks the server to resend entities so changes show at once

-- The box above only shows ONE weapon's tag (the checkbox one weapon's souvenir), and neither is restored by config
-- loads. So all of our tags and souvenirs are also kept in one config string (ui.new_string: no menu item, saved and
-- restored with configs), written as "key:text" (name tag) and "s<defindex>" (souvenir) entries joined by ";", with
-- % ; : escaped as %XX. The string keeps its first name so configs saved with tags only still load.
local ok_store, ui_store = pcall(ui.new_string, "Shared skins name tags", "")
if not ok_store then warn("store", "name tags won't be saved in configs: " .. tostring(ui_store)) end

local tags = {} -- [key] = our own name tags, key as in the name packet
local souv = {} -- [defindex] = true: our weapons shown as souvenirs
local box_key, loaded_at = nil, -1
local function tag_key(def) return is_knife_def(def) and 0 or def end

local function esc(s) return (s:gsub("[%%;:]", function(c) return string.format("%%%02X", c:byte()) end)) end
local function unesc(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

local function serialize()
	local out, keys = {}, {}
	for k in pairs(tags) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do out[#out + 1] = k .. ":" .. esc(tags[k]) end
	keys = {}
	for k in pairs(souv) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do out[#out + 1] = "s" .. k end
	return table.concat(out, ";")
end

local MAX_ENTRIES = 48
local function parse(s) -- the string comes from a config file: validate like network input
	for k in pairs(tags) do tags[k] = nil end
	for k in pairs(souv) do souv[k] = nil end
	local n = 0
	for item in (s .. ";"):gmatch("([^;]*);") do
		if n >= MAX_ENTRIES then break end
		local sk, k, t = item:match("^s(%d+)$"), item:match("^(%d+):([^:]*)$")
		if sk then
			sk = tonumber(sk)
			if sk > 0 and sk < 100 then souv[sk], n = true, n + 1 end -- weapons only (guns and grenades are below 100)
		elseif k then
			k, t = tonumber(k), clean_name(unesc(t))
			if t and k <= 65535 then tags[k], n = t, n + 1 end
		end
	end
end

do -- self-check: names holding the separators, and a souvenir, survive the config string; bad entries are dropped
	tags[3], tags[0], souv[7] = "a:b;c%d", "Knife", true
	local s = serialize()
	for k in pairs(tags) do tags[k] = nil end
	souv[7] = nil
	parse(s)
	assert(tags[3] == "a:b;c%d" and tags[0] == "Knife" and souv[7] and not souv[8], "config string round trip")
	parse("bad;s500;s9999999999;12:x%00y;s3")
	assert(tags[12] == "xy" and souv[3] and not souv[500] and not tags[3], "config string validation")
	parse("")
	assert(not next(tags) and not next(souv))
end

local function read_store()
	local ok, v = pcall(ui.get, ui_store)
	return ok and type(v) == "string" and v or nil
end

local saved = "" -- what we last wrote into the config string (or read out of it)
local persist_at -- time an edit of ours is due to be written (nil = nothing waiting)
local function persist()
	if not ok_store then return end
	saved = serialize()
	if read_store() ~= saved then
		local ok, e = pcall(ui.set, ui_store, saved)
		if not ok then warn("persist", "name tags: couldn't write the config string: " .. tostring(e)) end
	end
end

-- A config was loaded: take the saved tags and make the box show the current weapon's again. Our own write can read
-- back as the old string for a moment, and acting on that put the old text back into the box while it was being edited,
-- so the string has to stay different for a second, and an edit that is still waiting to be written is newer than it.
-- (force: the post_config_load event says it IS a config load, so none of that waiting applies)
local diff_since
local function store_changed(now, force)
	if not ok_store then return end
	if force then persist_at = nil elseif persist_at then return end
	local s = read_store()
	if not s or s == saved then diff_since = nil; return end
	diff_since = diff_since or now
	if not force and now - diff_since < 1 then return end
	diff_since, saved = nil, s
	parse(s)
	loaded_at, box_key = now, nil
	if request_refresh then request_refresh() end -- our own weapons get the new tags and souvenirs
end
if ok_store then
	saved = read_store() or ""
	parse(saved) -- a config may already have been applied when the script is loaded
end

-- The box is polled, not called back (a text box may only report on enter). An edit belongs to the weapon the box is
-- showing. A config load sets the box too, to the text it was saved with (some other weapon's); that must not count
-- as an edit, so changes right around a config load are ignored: the box is then put back to the current weapon's tag.
-- The souvenir checkbox works the same way.
local shown, shown_souv = "", false -- what the box and the checkbox held when we last looked
local function take_edits(now) -- what the box and the checkbox hold now belongs to the weapon they were showing
	local editable = box_key and now - loaded_at >= 0.5
	local cur = ui.get(ui_name) or ""
	if cur ~= shown then
		if editable then
			tags[box_key] = clean_name(cur)
			persist_at = now + 1 -- the config string is written once the typing pauses, not on every keystroke
		end
		shown = cur
	end
	local cur_s = ui.get(ui_souvenir) and true or false
	if cur_s ~= shown_souv then
		if editable and box_key ~= 0 then -- (a knife has no souvenir)
			souv[box_key] = cur_s or nil
			persist_at = now + 1
			if request_refresh then request_refresh(true) end -- the real quality comes back / ours shows
		end
		shown_souv = cur_s
	end
	return cur, cur_s
end

local function sync_tag_box(held_def) -- called a few times a second
	local now = globals.realtime()
	local key = tag_key(held_def)
	store_changed(now)
	local cur, cur_s = take_edits(now)
	if persist_at and (now >= persist_at or key ~= box_key) then persist_at = nil; persist() end
	if key ~= box_key then
		box_key, shown = key, tags[key] or ""
		if cur ~= shown then ui.set(ui_name, shown) end
		shown_souv = key ~= 0 and souv[key] or false
		if cur_s ~= shown_souv then ui.set(ui_souvenir, shown_souv) end
	elseif key == 0 and cur_s then
		shown_souv = false
		ui.set(ui_souvenir, false)
	end
end

local names = {} -- [accountid] = { [key] = { text, seen } }
local had_name = false -- we put name tags on our own weapons and must take them off again
local had_souvenir = false -- same for the souvenir quality

-- the weapon's custom name (CEconItemView::m_szCustomName); the server resends it empty, so it's rewritten each update
local name_warned = false
local function set_name(weapon, text)
	if entity.get_prop(weapon, "m_szCustomName") == text then return end
	pcall(entity.set_prop, weapon, "m_szCustomName", text)
	-- (clearing with "" may not stick; the full update that follows a tag change resets it, so only a failed write warns)
	if not name_warned and text ~= "" and entity.get_prop(weapon, "m_szCustomName") ~= text then
		name_warned = true
		warn("name", "name tag: couldn't write m_szCustomName (read back " .. tostring(entity.get_prop(weapon, "m_szCustomName")) .. ")")
	end
end

local remote = {} -- [entindex] = { [defindex] = decoded skin }
local agents = {} -- [entindex] = player model index
local gloves = {} -- [entindex] = decoded glove skin
local agent_seen = {} -- [entindex] = realtime of the last agent packet (remote / gloves entries carry their own .seen)
local TTL = 10 -- seconds; senders repeat every SEND_EVERY (2s), so an entry not refreshed for this long was switched off

-- knives: def index, model suffix (models/weapons/v_knife_<suffix>.mdl, w_knife_<suffix>.mdl),
-- killfeed name (the player_death "weapon" field / icon-<name>.png), gamesense Knife changer dropdown entry
local KNIVES, KNIFE_EVENT, NATIVE_KNIFE = {}, {}, {}
for _, r in ipairs {
	{ 500, "bayonet", "bayonet", "Bayonet" }, -- the one knife whose definition name has no "knife_" part (weapon_bayonet)
	{ 503, "css", "knife_css", "Classic knife" }, { 505, "flip", "knife_flip", "Flip" }, { 506, "gut", "knife_gut", "Gut" },
	{ 507, "karam", "knife_karambit", "Karambit" }, { 508, "m9_bay", "knife_m9_bayonet", "M9 Bayonet" },
	{ 509, "tactical", "knife_tactical", "Tactical" }, { 512, "falchion_advanced", "knife_falchion", "Falchion" },
	{ 514, "survival_bowie", "knife_survival_bowie", "Survival bowie" }, { 515, "butterfly", "knife_butterfly", "Butterfly" },
	{ 516, "push", "knife_push", "Shadow dagger" }, { 517, "cord", "knife_cord", "Paracord" },
	{ 518, "canis", "knife_canis", "Survival" }, { 519, "ursus", "knife_ursus", "Ursus" },
	{ 520, "gypsy_jackknife", "knife_gypsy_jackknife", "Navaja" }, { 521, "outdoor", "knife_outdoor", "Nomad" },
	{ 522, "stiletto", "knife_stiletto", "Stiletto" }, { 523, "widowmaker", "knife_widowmaker", "Talon" },
	{ 525, "skeleton", "knife_skeleton", "Skeleton" },
} do
	KNIVES[r[1]], KNIFE_EVENT[r[1]], NATIVE_KNIFE[r[4]] = r[2], r[3], r[1]
end

local ok_ref, ref_knife_on, ref_knife = pcall(ui.reference, "SKINS", "Model options", "Knife changer")
local ok_agent, ref_agent_on = pcall(ui.reference, "SKINS", "Model options", "Agent changer")
if not ok_agent then warn("agent", "couldn't find gamesense's Agent changer: " .. tostring(ref_agent_on)) end
if not ok_ref then warn("knifechanger", "couldn't find gamesense's Knife changer: " .. tostring(ref_knife_on)) end

function is_knife_def(def) return def == 42 or def == 59 or KNIVES[def] ~= nil end

-- gloves: def index -> model suffix; the wearable uses the world model models/weapons/w_models/arms/w_glove_<suffix>.mdl
-- (gamesense's own glove entity does; the v_models/arms viewmodel versions are full arms that don't merge onto a player)
local GLOVES = {
	[4725] = "bloodhound_brokenfang", [5027] = "bloodhound", [5030] = "sporty", [5031] = "slick",
	[5032] = "handwrap_leathery", [5033] = "motorcycle", [5034] = "specialist", [5035] = "bloodhound_hydra",
}
local function glove_model_path(def) return "models/weapons/w_models/arms/w_glove_" .. GLOVES[def] .. ".mdl" end

-- ---- native handles (client.dll / engine.dll) ----------------------------------
-- All offsets and vtable slots below are for this build (csgo_legacy, engine 8802, Aug 2023). They were read out of
-- client.dll / engine.dll and checked against the 2018 source; a different build needs them re-checked.
pcall(ffi.cdef, "typedef struct ss_cc { void* create_fn; void* create_event_fn; const char* name; void* recv; struct ss_cc* next; int id; } ss_cc;")
local client_dll = ffi.cast("void***", client.create_interface("client.dll", "VClient018"))
local entlist = ffi.cast("void***", client.create_interface("client.dll", "VClientEntityList003"))
local get_client_entity = ffi.cast("void*(__thiscall*)(void*, int)", entlist[0][3])
local get_highest_index = ffi.cast("int(__thiscall*)(void*)", entlist[0][6])

local model_info = ffi.cast("void***", client.create_interface("engine.dll", "VModelInfoClient004"))
local get_model_index = ffi.cast("int(__thiscall*)(void*, const char*)", model_info[0][2])
local model_cache = {}
local function model_index(path)
	if model_cache[path] == nil or model_cache[path] <= 0 then model_cache[path] = get_model_index(model_info, path) end
	return model_cache[path]
end

-- our own glove: the player's wearable slot is one handle at player+0x2f14 (found in CSPlayer::EquipWearable;
-- entity.get_prop can't see m_hMyWearables). Handle = index (low 16 bits) | serial << 16.
local WEARABLE_OFFSET = 0x2f14
local function set_wearable_slot(ent, handle)
	local p = get_client_entity(entlist, ent)
	if p ~= nil then ffi.cast("uint32_t*", ffi.cast("uintptr_t", p) + WEARABLE_OFFSET)[0] = handle end
	return p
end
local function local_glove_entity(me)
	local p = get_client_entity(entlist, me)
	if p == nil then return end
	local h = ffi.cast("uint32_t*", ffi.cast("uintptr_t", p) + WEARABLE_OFFSET)[0]
	local idx = h ~= 0xFFFFFFFF and h % 65536
	return idx and idx > 0 and entity.get_prop(idx, "m_iItemDefinitionIndex") and idx or nil
end

-- ---- what we send --------------------------------------------------------------
-- the skin on the knife we last held (gamesense writes it onto the knife entity); shared even while holding a gun
local last_knife = { kit = 0, seed = 0, wear = 0, stattrak = -1 }

-- every packet we currently want to send
local function payloads()
	local list = {}
	local me = entity.get_local_player()
	if not me then return list end

	-- agent: our player's current model index, when gamesense's Agent changer is on
	local idx = ok_agent and ui.get(ref_agent_on) and entity.get_prop(me, "m_nModelIndex")
	if idx and idx > 0 and idx < 65536 then list[#list + 1] = string.char(MAGIC_AGENT, idx % 256, math.floor(idx / 256)) end

	for key, text in pairs(tags) do list[#list + 1] = string.char(MAGIC_NAME, key % 256, math.floor(key / 256)) .. text end

	local w = entity.get_player_weapon(me)
	local def = w and entity.get_prop(w, "m_iItemDefinitionIndex")
	local kit = w and entity.get_prop(w, "m_nFallbackPaintKit") or 0
	local seed = w and math.min(math.max(entity.get_prop(w, "m_nFallbackSeed") or 0, 0), 65535) or 0
	local wear = w and entity.get_prop(w, "m_flFallbackWear") or 0
	local stat = w and entity.get_prop(w, "m_nFallbackStatTrak") or -1

	if def and is_knife_def(def) then
		last_knife = { kit = math.min(math.max(kit, 0), 65535), seed = seed, wear = wear, stattrak = stat }
	end
	-- knife: follows gamesense's Knife changer whatever we hold, so others see it as soon as we pull it out
	local nk = ok_ref and ui.get(ref_knife_on) and NATIVE_KNIFE[ui.get(ref_knife)]
	if nk then list[#list + 1] = encode(nk, last_knife.kit, last_knife.seed, last_knife.wear, last_knife.stattrak) end

	-- gloves
	local g = local_glove_entity(me)
	local gdef = g and entity.get_prop(g, "m_iItemDefinitionIndex")
	if gdef and GLOVES[gdef] then
		list[#list + 1] = encode(gdef, math.min(math.max(entity.get_prop(g, "m_nFallbackPaintKit") or 0, 0), 65535),
			math.min(math.max(entity.get_prop(g, "m_nFallbackSeed") or 0, 0), 65535), entity.get_prop(g, "m_flFallbackWear") or 0)
	end

	-- every non-knife weapon we carry with a skin, not just the held one: a weapon we drop keeps its skin for whoever
	-- picks it up, so receivers must already know it
	local sent = {}
	for i = 0, 63 do
		local h = entity.get_prop(me, "m_hMyWeapons", i)
		local c = h and bit.band(h, 0xFFF)
		local d = c and c > 0 and entity.get_prop(c, "m_iItemDefinitionIndex")
		local k = d and entity.get_prop(c, "m_nFallbackPaintKit") or 0
		if d and not sent[d] and not is_knife_def(d) and k > 0 and k <= 65535 then
			sent[d] = true
			list[#list + 1] = encode(d, k, math.min(math.max(entity.get_prop(c, "m_nFallbackSeed") or 0, 0), 65535),
				entity.get_prop(c, "m_flFallbackWear") or 0, entity.get_prop(c, "m_nFallbackStatTrak") or -1, souv[d])
		end
	end
	return list
end

-- ---- steam ids -----------------------------------------------------------------
-- account id -> entindex for every connected player, including ones that are out of sight (dormant). The roster
-- comes from the player resource, not from entity.get_players, so a player who walks out of range keeps being
-- sent to and heard from: our data must not depend on whether the game is currently drawing him.
-- get_steam64 returns the bare account id in this build (e.g. 1096217980), and nil for bots.
local function players_by_steamid()
	local map = {}
	local pr = entity.get_player_resource()
	if not pr then return map end
	for i = 1, globals.maxplayers() do
		local connected = entity.get_prop(pr, "m_bConnected", i)
		if connected == 1 or connected == true then
			local aid = entity.get_steam64(i)
			if type(aid) == "number" and aid ~= 0 then map[aid] = i end
		end
	end
	return map
end

-- an agent index from the network is only used if it names a real player model (a peer could send any number)
local agent_ok = {}
local function is_agent_model(idx)
	if agent_ok[idx] then return true end
	if idx <= 0 or idx >= 4096 then return false end -- the engine's model table has 4096 slots
	local m = ffi.cast("void*(__thiscall*)(void*, int)", model_info[0][1])(model_info, idx)
	if m == nil then return false end
	local name = ffi.cast("const char*(__thiscall*)(void*, void*)", model_info[0][3])(model_info, m)
	agent_ok[idx] = name ~= nil and ffi.string(name):find("^models/player/custom_player/legacy/") ~= nil
	return agent_ok[idx]
end

-- ---- transport: Steam networking messages on a private channel -----------------
-- ISteamNetworkingMessages (the newer replacement of the legacy P2P API) connects two players directly or through
-- Valve's relay servers when they can't reach each other, so it works between any two networks. The legacy API did not:
-- across NATs its sessions timed out. A session is only accepted from players on our server.
local steamworks = require "gamesense/steamworks"
local ok_msgs, msgs = pcall(function() return steamworks.ISteamNetworkingMessages end)
if not ok_msgs or not msgs then
	warn("msgs", "ISteamNetworkingMessages is not available: " .. tostring(msgs))
	return
end
local CHANNEL, SEND_EVERY = 42, 2 -- channel is arbitrary; resend so late joiners catch up
local SEND_FLAGS = 8 + 32 -- reliable | restart a broken session by itself
local STEAMID64_BASE = 76561197960265728ULL -- public universe, individual account, desktop instance

local function identity_of(aid)
	local id = ffi.new("SteamNetworkingIdentity")
	id.m_eType = 16 -- k_ESteamNetworkingIdentityType_SteamID
	id.m_cbSize = 8
	ffi.cast("uint64_t*", id.m_szUnknownRawString)[0] = STEAMID64_BASE + aid
	return id
end

-- A peer's first message arrives as a session request, which must be accepted before anything is delivered. Accepting
-- is harmless for players without a pending request, so the whole roster (and only the roster) is accepted.
-- Every player on the server could get a session from us, but only the ones running this script ever answer. A session
-- to anyone else stays "finding route" and keeps retrying (STUN traffic, one console error per try) for as long as it
-- lives, so at most MAX_ATTEMPTS unanswered sessions exist at a time. Each gets ATTEMPT_SECS to connect, then it is
-- closed and tried again later, after a growing pause. A session that connects (or that the peer opened) is kept.
local MAX_ATTEMPTS, ATTEMPT_SECS, BACKOFF, BACKOFF_MAX = 3, 20, 60, 600
local peers = {} -- [account id] = { open = we send to him, up = connected, started, fails, retry_at }
local function session_state(aid)
	local ok, _, info = pcall(msgs.GetSessionConnectionInfo, identity_of(aid))
	return ok and info and info.m_eState or 0
end
local function manage_sessions(map, me, now)
	local trying = 0
	for aid, ent in pairs(map) do
		if ent ~= me then
			local p = peers[aid]
			if not p then p = { fails = 0, retry_at = 0 }; peers[aid] = p end
			pcall(msgs.AcceptSessionWithUser, identity_of(aid))
			local st = session_state(aid)
			p.up = st == 3 -- k_ESteamNetworkingConnectionState_Connected
			if p.up then
				p.open, p.fails = true, 0
			elseif p.open and (st >= 4 or now - p.started > ATTEMPT_SECS) then -- closed, failed or unanswered
				pcall(msgs.CloseSessionWithUser, identity_of(aid))
				p.open, p.fails = false, p.fails + 1
				p.retry_at = now + math.min(BACKOFF_MAX, BACKOFF * 2 ^ (p.fails - 1))
			end
			if p.open and not p.up then trying = trying + 1 end
		end
	end
	for aid, p in pairs(peers) do
		if not map[aid] then
			pcall(msgs.CloseSessionWithUser, identity_of(aid)) -- left the server: Steam keeps a session alive until it is closed
			peers[aid] = nil
		elseif not p.open and now >= p.retry_at and trying < MAX_ATTEMPTS then
			p.open, p.started, trying = true, now, trying + 1
		end
	end
end
local function close_all() -- toggle off: no session should keep retrying in the background
	for aid in pairs(peers) do pcall(msgs.CloseSessionWithUser, identity_of(aid)) end
	peers = {}
end

local clear_remote -- defined with the glove code below: forgets everyone and puts the game back as the server has it
local flush_doomed -- same: deletes the gloves retired since the last frame
local last_p, last_pop, queue = nil, 0, {}
local last_send, last_accept = 0, 0
local inbox = ffi.new("SteamNetworkingMessage_t*[32]")
local map, list, key, built = {}, {}, "", 0 -- peers and our packets, rebuilt a few times a second (not every frame)
local MAX_READS = 32 -- packets read per frame: anyone on the server can send us packets, so the loop must have a limit
local MAX_PER_PLAYER = 16 -- same reason: entries (weapons, name tags) kept per sender
local MAX_PACKET = 32 -- our packets are at most 24 bytes
local function room(t, k)
	if t[k] then return true end
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n < MAX_PER_PLAYER
end

-- Steam's message release function is a plain cdecl function (it reads the message from the stack). The wrapper's
-- struct declares the pointer __thiscall, which passes the message in a register: Steam would then "release" whatever
-- happened to be on the stack, corrupting memory at random. So it is called through a cdecl type of our own.
local release_ct = ffi.typeof("void(__cdecl*)(void*)")
local function release(m)
	if m.m_pfnRelease == nil then error("message has no release function") end
	ffi.cast(release_ct, m.m_pfnRelease)(m)
end

-- hands every waiting message to on_packet(sender account id, bytes); with on_packet == nil they are just thrown away
local function read_messages(on_packet)
	local ok, n = pcall(msgs.ReceiveMessagesOnChannel, CHANNEL, inbox, MAX_READS)
	if not ok or type(n) ~= "number" or n <= 0 then return end
	for i = 0, n - 1 do
		local m = inbox[i]
		if on_packet and m.m_identityPeer.m_eType == 16 then
			local size = tonumber(m.m_cbSize)
			local who = tonumber(ffi.cast("uint64_t*", m.m_identityPeer.m_szUnknownRawString)[0] - STEAMID64_BASE)
			if size > 0 and size <= MAX_PACKET and who > 0 and who < 4294967296 then
				pcall(on_packet, who, ffi.string(m.m_pData, size)) -- an error must not skip the release below
			end
		end
		if not pcall(release, m) then warn("release", "couldn't free a received Steam message: memory is leaking") end
	end
end

local function on_packet(who, data)
	local now = globals.realtime()
	local ent = map[who] -- ignore non-players
	local t = ent and decode(data) -- decode checks the length itself
	if t and t.name then
		names[who] = names[who] or {}
		if room(names[who], t.key) then names[who][t.key] = { text = t.name, seen = now } end
	elseif t and t.agent then
		if is_agent_model(t.agent) then agents[ent], agent_seen[ent] = t.agent, now end
	elseif t and GLOVES[t.defindex] then
		t.aid, t.seen = who, now
		gloves[ent] = t
	elseif t and (t.defindex < 100 or KNIVES[t.defindex]) then -- real weapon ids only
		t.aid, t.seen = who, now
		remote[ent] = remote[ent] or {}
		if KNIVES[t.defindex] then -- a player has one knife: drop the previous one, or old entries pile up and win later lookups
			for d in pairs(remote[ent]) do if KNIVES[d] then remote[ent][d] = nil end end
		end
		if room(remote[ent], t.defindex) then
			-- the sender only lists weapons he carries, but a weapon he dropped keeps his skin: while he is sharing at
			-- all, his other entries stay alive too
			for _, s in pairs(remote[ent]) do s.seen = now end
			remote[ent][t.defindex] = t
		end
	end
end

client.set_event_callback("paint", function()
	if flush_doomed then flush_doomed() end
	if not ui.get(ui_enable) then
		read_messages(nil) -- nobody is listening: don't let Steam queue what peers keep sending
		if next(peers) then close_all() end
		if next(remote) or next(agents) or next(gloves) or next(names) or had_name then clear_remote() end
		return
	end
	local me = entity.get_local_player()
	if not me then return end
	local now = globals.realtime()
	if now - built > 0.25 then
		built = now
		local hw = entity.get_player_weapon(me)
		local hd = hw and entity.get_prop(hw, "m_iItemDefinitionIndex")
		if hd then sync_tag_box(hd) end
		map, list = players_by_steamid(), payloads()
		key = table.concat(list)
	end
	if now - last_accept > 1 then
		last_accept = now
		manage_sessions(map, me, now)
	end

	if #list > 0 and #queue == 0 and (now - last_send > SEND_EVERY or key ~= last_p) then
		last_send, last_p = now, key -- also send immediately when the held weapon/skin changes
		for _, p in ipairs(list) do queue[#queue + 1] = p end
	end
	-- one packet per 100ms, to every player we have (or are trying to open) a session with
	if #queue > 0 and now - last_pop > 0.1 then
		last_pop = now
		local p = table.remove(queue, 1)
		for aid, ent in pairs(map) do
			if ent ~= me and peers[aid] and peers[aid].open then
				pcall(msgs.SendMessageToUser, identity_of(aid), p, #p, SEND_FLAGS, CHANNEL)
			end
		end
	end

	read_messages(on_packet)
end)

-- ---- apply: weapons ------------------------------------------------------------
-- set_prop writes raw memory and doesn't fire the game's "data changed" handler, so the weapon material only
-- rebuilds when the entity is next updated; we write on net_update_start (so the game's own post-update
-- processing sees our values) and also _end, and ask the server to resend when a skin changes.
-- ownership: the skin belongs to the weapon's original owner (stamped on first apply), so a dropped weapon keeps
-- its owner's skin, and a weapon someone else picked up isn't overwritten with the holder's skin.
local function is_knife(weapon) return is_knife_def(entity.get_prop(weapon, "m_iItemDefinitionIndex")) end

-- swap a knife to the shared model: the weapon's model and its world-model entity (other players only; ours is
-- gamesense's Knife changer's job)
local function apply_knife_model(weapon, def)
	local v, w = model_index("models/weapons/v_knife_" .. KNIVES[def] .. ".mdl"), model_index("models/weapons/w_knife_" .. KNIVES[def] .. ".mdl")
	entity.set_prop(weapon, "m_iItemDefinitionIndex", def)
	entity.set_prop(weapon, "m_iEntityQuality", 3)
	if w > 0 then
		entity.set_prop(weapon, "m_iWorldModelIndex", w)
		local wm = bit.band(entity.get_prop(weapon, "m_hWeaponWorldModel") or 0, 0xFFF)
		if wm > 0 and wm < 2048 then entity.set_prop(wm, "m_nModelIndex", w) end
	end
	if v > 0 then entity.set_prop(weapon, "m_nModelIndex", v) end
end

local function apply(weapon, skins, aid) -- skins: [defindex] = skin
	local knife = is_knife(weapon)
	local skin = skins[entity.get_prop(weapon, "m_iItemDefinitionIndex")]
	if not skin and knife then -- any shared knife applies to whatever knife the player holds
		for def, s in pairs(skins) do if KNIVES[def] then skin = s; break end end
	end
	if not skin then return end
	local tag = names[aid] and names[aid][knife and 0 or skin.defindex]
	set_name(weapon, tag and tag.text or "")
	if KNIVES[skin.defindex] and knife then apply_knife_model(weapon, skin.defindex) end
	entity.set_prop(weapon, "m_iItemIDHigh", -1) -- forces the fallback_* props to be used
	entity.set_prop(weapon, "m_iAccountID", aid)
	entity.set_prop(weapon, "m_OriginalOwnerXuidLow", aid)
	entity.set_prop(weapon, "m_OriginalOwnerXuidHigh", 17825793) -- 0x01100001: public universe, individual, desktop; the HUD resolves the owner's name from this
	entity.set_prop(weapon, "m_nFallbackPaintKit", skin.paintkit)
	entity.set_prop(weapon, "m_nFallbackSeed", skin.seed)
	entity.set_prop(weapon, "m_flFallbackWear", skin.wear)
	entity.set_prop(weapon, "m_nFallbackStatTrak", skin.stattrak)
	if skin.stattrak >= 0 then entity.set_prop(weapon, "m_iEntityQuality", knife and 12 or 9) end -- "strange"; the counter only shows with it
	if skin.souvenir and not knife then entity.set_prop(weapon, "m_iEntityQuality", 12) end -- "tournament" = souvenir
end

-- ---- apply: gloves on other players --------------------------------------------
-- Gloves are a separate CEconWearable entity. We create one client-side through the game's own ClientClass
-- factory, fill in its item props, then call its Equip(player) vfunc (slot 282), which hands it to the player's
-- EquipWearable (CSPlayer slot 270) and attaches it.
local EQUIP_SLOT = 282
local SETMODELINDEX_SLOT = 75 -- C_BaseEntity::SetModelIndex: writes m_nModelIndex AND installs the model pointer

local wearable_create
local function find_wearable_create()
	local cc = ffi.cast("ss_cc*(__thiscall*)(void*)", client_dll[0][8])(client_dll)
	while cc ~= nil do
		if ffi.string(cc.name) == "CEconWearable" then return ffi.cast("void*(__cdecl*)(int, int)", cc.create_fn) end
		cc = cc.next
	end
end

local glove_of = {} -- [player ent] = { idx = wearable entindex, ptr = its address, def, sig, mdl, tried = realtime }
local glove_fails = {} -- [player ent] = times the game refused to attach our glove (for the current glove type)
local glove_made = {} -- [player ent] = realtime we last created a glove entity for them

-- The ClientClass factory registers the entity as *networkable* (C_BaseEntity::Init -> AddNetworkableEntity), which
-- only allows slots 0..2047 (MAX_EDICTS). Slots 2049+ are the game's free list for client-only entities, so a
-- networkable entity put there stays on that free list and the next client-only entity the game allocates (a
-- ragdoll, a particle...) lands on the same slot and corrupts the entity lists: hangs and heap corruption.
-- So take the first free slot just past the server's highest, and refuse if there isn't one.
local MAX_NET_SLOT = 2040
local function create_wearable()
	wearable_create = wearable_create or find_wearable_create()
	if not wearable_create then return nil, "CEconWearable class not found" end
	local idx = get_highest_index(entlist) + 1
	while idx < MAX_NET_SLOT and get_client_entity(entlist, idx) ~= nil do idx = idx + 1 end
	if idx >= MAX_NET_SLOT then return nil, "no free networkable slot" end
	wearable_create(idx, math.random(1, 0xFFF))
	local ptr = get_client_entity(entlist, idx)
	if ptr == nil then return nil, "entity not in list after create" end
	return idx, ptr
end

local function set_model(st, mdl)
	if mdl > 0 and st.mdl ~= mdl then
		st.mdl = mdl
		ffi.cast("void(__thiscall*)(void*, int)", ffi.cast("void***", st.ptr)[0][SETMODELINDEX_SLOT])(st.ptr, mdl)
	end
end

local function glove_sig(skin) return skin.defindex .. ":" .. skin.paintkit .. ":" .. skin.seed .. ":" .. skin.wear end

local function set_glove_props(st, skin)
	local idx = st.idx
	entity.set_prop(idx, "m_iItemDefinitionIndex", skin.defindex)
	entity.set_prop(idx, "m_nFallbackPaintKit", skin.paintkit)
	entity.set_prop(idx, "m_nFallbackSeed", skin.seed)
	entity.set_prop(idx, "m_flFallbackWear", math.max(skin.wear, 0.00001)) -- gamesense's glove carries 1e-5, never exactly 0
	set_model(st, model_index(glove_model_path(skin.defindex)))
end

-- IClientNetworkable (the sub-object at +8): slot 5 OnDataChanged, 6 PreDataUpdate, 7 PostDataUpdate
local function networkable(ptr) return ffi.cast("void***", ffi.cast("uintptr_t", ptr) + 8) end
local function net_call(ptr, slot, arg)
	local n = networkable(ptr)
	ffi.cast("void(__thiscall*)(void*, int)", n[0][slot])(n, arg)
end

-- Hide a glove entity and free the player's wearable slot so a replacement can be equipped. The entity itself is deleted
-- a moment later (flush_doomed, from the paint callback): a glove that was only hidden stayed in the world for good, and
-- when its player left view range (the game then detaches his children) it showed up lying on the ground.
local doomed = {}
local function retire_glove(ent, st)
	if st.idx then
		pcall(entity.set_prop, st.idx, "m_fEffects", 161) -- EF_NODRAW
		doomed[#doomed + 1] = { st.idx, st.ptr }
	end
	pcall(set_wearable_slot, ent, 0xFFFFFFFF)
	glove_of[ent] = nil
end

flush_doomed = function()
	for i = #doomed, 1, -1 do
		local idx, ptr = doomed[i][1], doomed[i][2]
		doomed[i] = nil
		-- only if it's still our glove: the slot may have been recycled by a map change
		local def = get_client_entity(entlist, idx) == ptr and entity.get_prop(idx, "m_iItemDefinitionIndex")
		if def and GLOVES[def] then
			local n = networkable(ptr)
			pcall(function() ffi.cast("void(__thiscall*)(void*)", n[0][1])(n) end) -- IClientNetworkable::Release
		end
	end
end

local function apply_glove(ent, skin, aid)
	local st = glove_of[ent]
	-- The game builds a glove's custom paint material once, when the entity is created: from its model (it names the
	-- material slots after that glove, e.g. glove_bloodhound_left) and its paint kit. Changing either later does
	-- nothing visible: a new model keeps the old slot names, and a new paint kit on the same model is ignored (the
	-- first kit stays). So any change of glove type, paint kit, seed or wear gets a fresh entity; the old one is retired.
	if st and st.sig and st.sig ~= glove_sig(skin) then retire_glove(ent, st); st = nil; glove_fails[ent] = nil end
	if st and st.bad then
		-- the game didn't attach our glove to this player. Try again with a fresh entity after a pause, but only a few times.
		if globals.realtime() - st.bad < 10 or (glove_fails[ent] or 0) >= 3 then return end
		retire_glove(ent, st); st = nil
	end
	local ptr = st and get_client_entity(entlist, st.idx)
	if not (st and ptr ~= nil and ptr == st.ptr and entity.get_prop(st.idx, "m_iItemDefinitionIndex") ~= nil) then -- (get_classname returns nil above index 2047)
		if st and globals.realtime() - st.tried < 2 then return end
		local player = get_client_entity(entlist, ent)
		if player == nil then return end
		-- a sender who flips through skins quickly must not make us create an entity per packet
		if globals.realtime() - (glove_made[ent] or 0) < 1 then return end
		glove_made[ent] = globals.realtime()
		local idx, p = create_wearable()
		st = { tried = globals.realtime() }
		glove_of[ent] = st
		if not idx then warn("glovecreate", "glove create failed: " .. tostring(p)); return end
		st.idx, st.ptr, st.def = idx, p, skin.defindex
		pcall(entity.set_prop, idx, "m_bInitialized", 1)
		entity.set_prop(idx, "m_iItemIDHigh", -1)
		entity.set_prop(idx, "m_iItemIDLow", -1) -- gamesense's own glove has both -1
		entity.set_prop(idx, "m_iAccountID", aid)
		entity.set_prop(idx, "m_iEntityQuality", 4)
		-- def index and paint kit have to be on the entity before its data update runs: the skin material is built from them then
		set_glove_props(st, skin)
		-- a freshly created entity has never been through a data update, which is what registers it for rendering
		net_call(p, 6, 0) -- PreDataUpdate(DATA_UPDATE_CREATED)
		ffi.cast("void(__thiscall*)(void*, void*)", ffi.cast("void***", p)[0][EQUIP_SLOT])(p, player)
		if entity.get_prop(idx, "m_hOwnerEntity") ~= ent then
			-- Equip sets the owner when it attaches; if it didn't (the player's wearable slot may already hold a real
			-- glove from their inventory), our entity would float at the origin, so hide it and stop trying
			st.bad = globals.realtime()
			glove_fails[ent] = (glove_fails[ent] or 0) + 1
			entity.set_prop(idx, "m_fEffects", 161)
			warn("gloveattach", string.format("glove for player %d did not attach (try %d of 3)", ent, glove_fails[ent]))
			return
		end
		glove_fails[ent] = nil
		-- gamesense's own glove entity has effects=129 (bonemerge|fastcull) and moveparent = the player's handle.
		-- PostDataUpdate re-parents the entity to its *network* move parent (C_BaseEntity::PostDataUpdate ->
		-- HierarchySetParent(m_hNetworkMoveParent)), which would undo the parent Equip just set, so make the
		-- player's handle (GetRefEHandle, primary vtable slot 2) the network move parent first.
		entity.set_prop(idx, "m_fEffects", 129)
		st.sig = glove_sig(skin)
		entity.set_prop(idx, "moveparent", ffi.cast("uint32_t*(__thiscall*)(void*)", ffi.cast("void***", player)[0][2])(player)[0])
		net_call(p, 7, 0) -- PostDataUpdate(CREATED)
		net_call(p, 5, 0) -- OnDataChanged(CREATED)
	end
	-- a client-created entity starts out dormant (m_bDormant, entity+0xED) and nothing ever wakes it, so it's never drawn
	ffi.cast("uint8_t*", ffi.cast("uintptr_t", st.ptr) + 0xED)[0] = 0
	-- hide the player's default gloves (body group 1) so they don't poke through ours
	entity.set_prop(ent, "m_nBody", 1)
end

-- ---- forgetting players --------------------------------------------------------
-- cl_fullupdate is a cheat command (blocked with sv_cheats 0), so do what it does: CClientState::m_nDeltaTick = -1
-- makes the engine's next packet ask the server for a full update. Pointer to the client state from engine.dll
-- ("mov eax, [pClientState]"); the delta tick offset is 0x174 in this build.
local DELTA_TICK = 0x174
local cs_ptr = client.find_signature("engine.dll", "\xA1\xCC\xCC\xCC\xCC\x33\xD2\x6A\x00\x6A\x00\x33\xC9\x89\xB0")
local cs_var = cs_ptr and ffi.cast("uintptr_t**", ffi.cast("uintptr_t", cs_ptr) + 1)[0]
if not cs_var then warn("cs", "couldn't find the client state: skin updates need a manual refresh") end

local last_refresh = 0
local function refresh_server_state() -- the server resends entities, which rebuilds weapon materials from our values
	if globals.realtime() - last_refresh <= 4 then return false end -- at most one every 4 seconds: a peer flipping skins must not make everyone re-download the world
	last_refresh = globals.realtime()
	local state = cs_var and cs_var[0]
	if state ~= nil and state ~= 0 then
		local tick = ffi.cast("int32_t*", ffi.cast("uintptr_t", state) + DELTA_TICK)
		if tick[0] >= -1 and tick[0] < 0x10000000 then tick[0] = -1 -- sane value: it's the field we think it is
		else warn("delta", "client state delta tick looks wrong (" .. tick[0] .. "), not touching it") end
	end
	return true
end

-- Drop one player completely: their data, their glove entity, their hidden default hands.
local function forget_player(ent)
	remote[ent], agents[ent], agent_seen[ent], gloves[ent], glove_fails[ent] = nil, nil, nil, nil, nil
	local st = glove_of[ent]
	if st then
		retire_glove(ent, st)
		pcall(entity.set_prop, ent, "m_nBody", 0)
	end
end

-- Toggle turned off: forget everybody. What we wrote onto entities goes away with the server's next update of them.
clear_remote = function()
	local ents = {}
	for ent in pairs(remote) do ents[ent] = true end
	for ent in pairs(agents) do ents[ent] = true end
	for ent in pairs(gloves) do ents[ent] = true end
	for ent in pairs(ents) do forget_player(ent) end
	for aid in pairs(names) do names[aid] = nil end
	if had_name then -- take our own tags off our weapons
		local me = entity.get_local_player()
		for i = 0, 63 do
			local w = me and entity.get_prop(me, "m_hMyWeapons", i)
			w = w and bit.band(w, 0xFFF)
			if w and w > 0 and entity.get_prop(w, "m_iItemDefinitionIndex") then set_name(w, "") end
		end
		had_name = false
	end
	had_souvenir = false
	last_refresh = 0 -- the server's next update puts the real quality back on our weapons: don't wait out the 4 second spacing
	refresh_server_state()
end

-- Entries not refreshed for TTL seconds were switched off by their owner (or he left).
local function expire(now)
	local dropped = false
	for ent, skins in pairs(remote) do
		for def, s in pairs(skins) do
			if now - s.seen > TTL then skins[def] = nil; dropped = true end
		end
		if not next(skins) then remote[ent] = nil end
	end
	for ent, g in pairs(gloves) do
		if now - g.seen > TTL then
			gloves[ent] = nil
			local st = glove_of[ent]
			if st then retire_glove(ent, st); pcall(entity.set_prop, ent, "m_nBody", 0) end
			dropped = true
		end
	end
	for ent, t in pairs(agent_seen) do
		if now - t > TTL then agents[ent], agent_seen[ent] = nil, nil; dropped = true end
	end
	for aid, per in pairs(names) do
		for key, n in pairs(per) do
			if now - n.seen > TTL then per[key] = nil; dropped = true end
		end
		if not next(per) then names[aid] = nil end
	end
	return dropped
end

-- ---- apply: everything, every net update ---------------------------------------
local last_sig, need_refresh = "", false
request_refresh = function(now) -- now: skip the 4 second spacing between refreshes (a config load, an option switched)
	need_refresh = true
	if now then last_refresh = 0 end
end
local function apply_all()
	local me = entity.get_local_player()
	if not ui.get(ui_enable) or not me then return end
	local gone = expire(globals.realtime())
	local sig = ""
	local owners = {} -- [accountid] = { ent = player ent, skins = {...} }
	for ent, skins in pairs(remote) do
		for def, skin in pairs(skins) do
			owners[skin.aid] = { ent = ent, skins = skins }
			sig = sig .. "|" .. ent .. ":" .. def .. ":" .. skin.paintkit .. ":" .. skin.seed .. ":" .. skin.stattrak .. (skin.souvenir and "s" or "")
		end
	end
	for aid, per in pairs(names) do
		for key, n in pairs(per) do sig = sig .. "|n" .. aid .. ":" .. key .. n.text end
	end
	-- our own weapons: gamesense has no name tags or souvenirs, so put ours on
	if next(tags) or had_name or next(souv) or had_souvenir then
		for i = 0, 63 do
			local w = entity.get_prop(me, "m_hMyWeapons", i)
			w = w and bit.band(w, 0xFFF)
			local d = w and w > 0 and entity.get_prop(w, "m_iItemDefinitionIndex")
			if d then
				set_name(w, tags[tag_key(d)] or "")
				if souv[d] and not is_knife_def(d) and (entity.get_prop(w, "m_nFallbackPaintKit") or 0) > 0 then
					entity.set_prop(w, "m_iEntityQuality", 12)
					entity.set_prop(w, "m_nFallbackStatTrak", -1) -- souvenir and StatTrak exclude each other
				end
			end
		end
		had_name, had_souvenir = next(tags) ~= nil, next(souv) ~= nil
	end
	if next(agents) then
		-- keep the agent on dead players too: the ragdoll is built from the player's model at the moment of death.
		-- When a player comes back into range the server sends his real model again; writing only the netprop leaves the
		-- old model on screen until his next update, so install the model right now (SetModelIndex, as for ragdolls).
		for ent, idx in pairs(agents) do
			if entity.get_prop(ent, "m_nModelIndex") ~= idx then
				local p = get_client_entity(entlist, ent)
				if p ~= nil then
					ffi.cast("void(__thiscall*)(void*, int)", ffi.cast("void***", p)[0][SETMODELINDEX_SLOT])(p, idx)
				end
			end
		end
		-- and on the ragdoll itself. The server creates it once with the player's real model and never updates it, so
		-- writing the netprop isn't enough (nothing revalidates the model pointer): call SetModelIndex once per ragdoll.
		for _, rag in ipairs(entity.get_all("CCSRagdoll")) do
			local idx = agents[bit.band(entity.get_prop(rag, "m_hPlayer") or 0, 0xFFF)]
			local p = idx and get_client_entity(entlist, rag)
			-- a new ragdoll arrives with the player's real model in m_nModelIndex; once we've swapped it the prop reads
			-- idx, so "prop ~= idx" means "not done yet". (Caching by entity index or address doesn't work: the game
			-- reuses both for the next ragdoll.)
			if p ~= nil and entity.get_prop(rag, "m_nModelIndex") ~= idx then
				entity.set_prop(rag, "m_nModelIndex", idx)
				ffi.cast("void(__thiscall*)(void*, int)", ffi.cast("void***", p)[0][SETMODELINDEX_SLOT])(p, idx)
			end
		end
	end
	for ent, skin in pairs(gloves) do
		local dormant = entity.is_dormant(ent)
		local st0 = glove_of[ent]
		if dormant then
			if st0 then
				st0.was_dormant = true
				if st0.idx then entity.set_prop(st0.idx, "m_fEffects", 161) end -- detached while he's out of range: don't draw it on the ground
			end
		elseif st0 and st0.was_dormant then
			-- when a player leaves the PVS the game unlinks him from all his children (C_BaseEntity::UnlinkFromHierarchy),
			-- which detaches our glove; nothing re-links it when he returns, so make a fresh one
			retire_glove(ent, st0)
		end
		local alive = entity.is_alive(ent) and not dormant
		if alive then
			local ok, err = pcall(apply_glove, ent, skin, skin.aid)
			if not ok then warn("gloveerr", "glove error: " .. tostring(err)) end
		end
		-- while dead the game puts its own gloves on the ragdoll; ours would keep following the corpse's stale pose
		-- (EF_NODRAW = 32), so hide it until the player respawns (apply_glove restores effects to 129)
		local st = glove_of[ent]
		if st and st.idx and not st.bad then
			entity.set_prop(st.idx, "m_fEffects", alive and 129 or 161)
			entity.set_prop(ent, "m_nBody", 1) -- body 1 hides the default hands, dead or alive (the ragdoll copies it)
		end
	end
	if next(owners) then
		-- held weapons: claim only unowned ones (original owner 0) or ones already ours
		for aid, o in pairs(owners) do
			local w = entity.is_alive(o.ent) and entity.get_player_weapon(o.ent)
			local orig = w and entity.get_prop(w, "m_OriginalOwnerXuidLow")
			if w and (orig == 0 or orig == aid) then apply(w, o.skins, aid) end
		end
		-- every other weapon (dropped, or carried by someone else) whose original owner is a sharing player
		for i = 65, 1024 do
			local orig = entity.get_prop(i, "m_OriginalOwnerXuidLow")
			local o = orig and orig ~= 0 and owners[orig]
			if o then apply(i, o.skins, orig) end
		end
	end
	if gone or sig ~= last_sig then need_refresh, last_sig = true, sig end
	if need_refresh and refresh_server_state() then need_refresh = false end -- reprocess entities with our values
end
client.set_event_callback("net_update_start", apply_all)
client.set_event_callback("net_update_end", apply_all)

-- A config load changes gamesense's own skin settings and our souvenir switch, and brings back our saved name tags: take
-- the tags right now and have the server resend every entity, so all skins (ours included) are rebuilt from the new values.
client.set_event_callback("post_config_load", function()
	pcall(store_changed, globals.realtime(), true)
	request_refresh(true)
end)
-- an edit waits a second before it is written to the config string: make sure the config being saved has it
client.set_event_callback("pre_config_save", function()
	pcall(take_edits, globals.realtime()) -- the last keystrokes may not have been polled yet
	if persist_at then persist_at = nil; persist() end
end)

client.set_event_callback("player_disconnect", function(e)
	local ent = client.userid_to_entindex(e.userid)
	if ent and ent > 0 then forget_player(ent) end
end)

-- ---- killfeed icon + kill screen skin (native hook) ----------------------------
-- The server builds the player_death event from the killer's REAL weapon, so it names the default knife and carries no
-- skin. Both the killfeed icon (event field "weapon" -> icon-<weapon>.png) and the kill screen's "killed you with ..."
-- (field "weapon_fauxitemid" = 0xF000000000000000 | paintkit << 16 | defindex) read those fields, so we rewrite them
-- on the client before the HUD sees the event. gamesense only lets scripts read events, so this hooks slot 9
-- (FireEventClientSide) of the engine's IGameEventManager2 vtable.
-- Native calls are not allowed on arbitrary addresses, but ones into engine.dll are, and engine.dll has `jmp ecx`
-- thunks: a __thiscall call to one puts our first argument in ecx, so it jumps to any function we name (a stdcall call).
local KF_SLOT = 9
local kf = {}

local function kf_native()
	if kf.vp then return true end
	local gadget = client.find_signature("engine.dll", "\xFF\xE1\xCC\xCC\xCC\xCC\xCC")
	local s_mod  = client.find_signature("engine.dll", "\xFF\x15\xCC\xCC\xCC\xCC\x85\xC0\x74\x0B")
	local s_proc = client.find_signature("engine.dll", "\xFF\x15\xCC\xCC\xCC\xCC\xA3\xCC\xCC\xCC\xCC\xEB\x05")
	if not (gadget and s_mod and s_proc) then return false, "engine.dll signatures not found" end
	local function iat(sig) return ffi.cast("uint32_t**", ffi.cast("uintptr_t", sig) + 2)[0][0] end
	local call1 = ffi.cast("uint32_t(__thiscall*)(uint32_t, const char*)", gadget)
	local call2 = ffi.cast("uint32_t(__thiscall*)(uint32_t, uint32_t, const char*)", gadget)
	local k32 = call1(iat(s_mod), "kernel32.dll")
	local vp = k32 ~= 0 and call2(iat(s_proc), k32, "VirtualProtect") or 0
	if vp == 0 then return false, "couldn't resolve VirtualProtect" end
	kf.callvp = ffi.cast("int(__thiscall*)(uint32_t, void*, uint32_t, uint32_t, uint32_t*)", gadget)
	kf.vp = vp
	return true
end

local function kf_vt(p) return ffi.cast("void***", p)[0] end
local function kf_int(ev, k) return ffi.cast("int(__thiscall*)(void*, const char*, int)", kf_vt(ev)[6])(ev, k, 0) end
local function kf_str(ev, k)
	local p = ffi.cast("const char*(__thiscall*)(void*, const char*, const char*)", kf_vt(ev)[9])(ev, k, "")
	return p ~= nil and ffi.string(p) or ""
end
local function kf_set(ev, k, v) ffi.cast("void(__thiscall*)(void*, const char*, const char*)", kf_vt(ev)[16])(ev, k, v) end

local function faux_id(def, kit) -- CombinedItemIdMakeFromDefIndexAndPaint, as the decimal string the event carries
	local v = 0xF000000000000000ULL + kit * 65536ULL + def
	return (tostring(v):gsub("U?LL$", ""))
end
-- 17293822569102704672 is what the server sent for a default P2000 (def 32, no paint kit): a self-check on the formatting
local FAUX_OK = faux_id(32, 0) == "17293822569102704672"
if not FAUX_OK then warn("faux", "killfeed: item id formatting changed, kill screen skins disabled") end

-- the shared skins of whoever got the kill: other players from the network, ourselves from what we send
local function kf_skins_of(att)
	if att ~= entity.get_local_player() then return remote[att] end
	local mine = {}
	for _, p in ipairs(payloads()) do local t = decode(p); if t and t.defindex then mine[t.defindex] = t end end
	return mine
end

-- kills that are not made with the weapon the killer is holding: his held gun's skin must not be put on them
local NOT_HELD = { "hegrenade", "inferno", "molotov", "incgrenade", "flashbang", "smokegrenade", "decoy" }
local function held_kill(weapon)
	for _, n in ipairs(NOT_HELD) do if weapon:sub(1, #n) == n then return false end end
	return true
end

local function kf_rewrite(ev)
	if not FAUX_OK then return end
	local att = client.userid_to_entindex(kf_int(ev, "attacker"))
	if not att or att <= 0 then return end -- world / suicide
	local skins = kf_skins_of(att)
	if not skins then return end
	local weapon = kf_str(ev, "weapon")
	-- Name tags are not shown on the kill screen: its "killed you with ..." text is the item's localized name
	-- ("AWP | Dragon Lore"), which only contains a custom name for a real inventory item.
	if weapon:sub(1, 5) == "knife" then
		local kd
		for d in pairs(skins) do if KNIVES[d] then kd = d end end
		if not kd then return end
		kf_set(ev, "weapon", KNIFE_EVENT[kd])
		kf_set(ev, "weapon_fauxitemid", faux_id(kd, skins[kd].paintkit))
	elseif held_kill(weapon) then
		local w = entity.get_player_weapon(att)
		local def = w and entity.get_prop(w, "m_iItemDefinitionIndex")
		local s = def and skins[def]
		if s and s.paintkit > 0 then kf_set(ev, "weapon_fauxitemid", faux_id(def, s.paintkit)) end
	end
end

-- GetName is slot 1; only player_death is touched
local function kf_on_event(ev)
	if not ui.get(ui_enable) then return end
	local name = ffi.cast("const char*(__thiscall*)(void*)", kf_vt(ev)[1])(ev)
	if name ~= nil and ffi.string(name) == "player_death" then kf_rewrite(ev) end
end

local function kf_set_slot(value) -- write the vtable slot, with the page made writable for a moment
	local old = ffi.new("uint32_t[1]")
	local addr = ffi.cast("uint32_t*", kf.vt) + KF_SLOT
	if kf.callvp(kf.vp, addr, 4, 0x04, old) == 0 then return false end -- PAGE_READWRITE
	addr[0] = value
	kf.callvp(kf.vp, addr, 4, old[0], old)
	return true
end

local function kf_on()
	if kf.active then return end
	local ok, err = kf_native()
	if not ok then warn("kfnative", "killfeed: " .. tostring(err)); return end
	local mgr = client.create_interface("engine.dll", "GAMEEVENTSMANAGER002")
	if not mgr then warn("kfmgr", "killfeed: event manager not found"); return end
	kf.vt = ffi.cast("uint32_t**", mgr)[0]
	kf.orig_addr = kf.vt[KF_SLOT]
	kf.orig = ffi.cast("bool(__thiscall*)(void*, void*)", kf.orig_addr)
	-- a __thiscall method with one stack argument arrives as __fastcall(ecx = this, edx = unused, stack = event)
	kf.cb = ffi.cast("bool(__fastcall*)(void*, void*, void*)", function(this, edx, ev)
		pcall(kf_on_event, ev) -- a Lua error must never escape into the engine
		return kf.orig(this, ev)
	end)
	if not kf_set_slot(tonumber(ffi.cast("uint32_t", kf.cb))) then
		warn("kfvp", "killfeed: VirtualProtect failed"); return
	end
	kf.active = true
end

local function kf_off()
	if not kf.active then return end
	kf_set_slot(kf.orig_addr)
	kf.active = false
end

-- the hook only exists while the toggle is on
ui.set_callback(ui_enable, function()
	if ui.get(ui_enable) then
		local ok, e = pcall(kf_on)
		if not ok then warn("kferr", "killfeed error: " .. tostring(e)) end
	else
		kf_off()
	end
end)
-- on by default: set a moment after the script has loaded, so a value gamesense restores for the item doesn't undo it
-- (setting a checkbox from a script may not run its callback, so the hook is started here too)
client.delay_call(0.2, function()
	ui.set(ui_enable, true)
	local ok, e = pcall(kf_on)
	if not ok then warn("kferr", "killfeed error: " .. tostring(e)) end
end)

-- ---- unload ----------------------------------------------------------------------
-- The vtable slot must be restored before this script (and the callback it points to) is unloaded, or the next
-- event calls freed code and crashes the game. The glove entities we created outlive the script, so hide them
-- (EF_NODRAW; the game frees them on the next map/round change), give the players their default hands back, and free
-- their wearable slot so a reloaded script can equip its own glove.
client.set_event_callback("shutdown", function()
	pcall(kf_off)
	for ent, st in pairs(glove_of) do
		if st.idx then pcall(entity.set_prop, st.idx, "m_fEffects", 161) end
		pcall(entity.set_prop, ent, "m_nBody", 0)
		pcall(set_wearable_slot, ent, 0xFFFFFFFF)
		if st.idx then doomed[#doomed + 1] = { st.idx, st.ptr } end
	end
	pcall(flush_doomed) -- and delete them, so a reload doesn't leave a pile of hidden gloves behind
end)
