--=====================================================================
-- tower_branch_limit —— 四级塔双分支限制
--
-- 原版前三代里，三级塔升四级时只有两个分支可选；Dove 版因为整合了三代
-- 防御塔，同一个塔系（箭塔/法塔/炮塔/兵营）的四级分支多达十几个。
--
-- 本插件让每个塔系在一局游戏内最多只能选用 N（默认 2）种四级塔分支：
-- 用满之后，该塔系其余四级塔分支会显示为本体的「锁定」图标，不能再升级；
-- 已经选中的分支仍然可以继续建造（与原版「可以造很多座同一分支」一致）。
--
-- 实现方式：只挂钩子，不改本体任何文件。
--   TowerMenu.show            —— 打开塔菜单前，把本应锁定的分支临时并入
--                                store.level.locked_towers，本体随即自己画出锁
--                                图标；菜单构建完立刻还原，不污染关卡数据。
--   TowerMenu.button_callback —— 记录玩家最终选中的分支（"ever" 模式的依据），
--                                并拦截极少数「菜单已过期」造成的越权升级。
--   simulation.do_tick        —— 兜底重挂：TowerMenu 是全局类，一旦被重新定义
--                                就自动重新挂钩子。
--=====================================================================
local hook_utils = require("hook_utils")
local HOOK = hook_utils.HOOK
local UNHOOK = hook_utils.UNHOOK
local hook = hook_utils:new()
local log = require("lib.klua.log"):new("tower_branch_limit")
local GS = require("kr1.game_settings")

-- tower.type -> 该塔系在 GS 里的塔列表（下标 1..3 是初级塔，4 起是四级塔）
local FAMILY_LIST = {
	archer = "archer_towers",
	mage = "mage_towers",
	engineer = "engineer_towers",
	barrack = "barrack_towers",
}

local state = {
	game_gui = nil,
	menu_class = nil, -- 已经挂上钩子的 TowerMenu 类对象
	installed = false,
}

-- store.ephemeral 不可用时的兜底容器（弱键，随 store 回收）
local FALLBACK_STATE = setmetatable({}, { __mode = "k" })

local function contains(list, value)
	for i = 1, #list do
		if list[i] == value then
			return true
		end
	end
	return false
end

local function count_keys(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

local function get_game_gui()
	if state.game_gui then
		return state.game_gui
	end

	local ok, m = pcall(require, "game_gui")

	if ok and type(m) == "table" then
		state.game_gui = m
		return m
	end

	return nil
end

-- 本局的插件状态。挂在 store.ephemeral 上，换关 / 重开会自动清空。
local function game_state(store)
	local eph = store.ephemeral

	if eph then
		local s = eph.tower_branch_limit

		if not s then
			s = { seen = {} }
			eph.tower_branch_limit = s
		end

		return s
	end

	local s = FALLBACK_STATE[store]

	if not s then
		s = { seen = {} }
		FALLBACK_STATE[store] = s
	end

	return s
end

-- 模板名 → 所属塔系。不是四级塔则返回 nil。
local function family_of_tower(template_name)
	if not template_name then
		return nil
	end

	for family, list_name in pairs(FAMILY_LIST) do
		local list = GS[list_name]

		for i = 4, #list do
			if list[i] == template_name then
				return family, i
			end
		end
	end

	return nil
end

-- 本局已经占用的四级塔种类（键为模板名）
-- record = true 时，把场上现存的种类并进本局历史（"ever" 模式）
local function used_kinds(store, list, record)
	local kinds = {}
	local is_fourth = {}

	for i = 4, #list do
		is_fourth[list[i]] = true
	end

	for _, e in pairs(store.towers or {}) do
		local n = e and e.template_name

		if n and is_fourth[n] and not e.pending_removal then
			kinds[n] = true
		end
	end

	if record then
		local st = game_state(store)

		for n in pairs(kinds) do
			st.seen[n] = true
		end

		-- 只把「本塔系」的历史种类并进来，避免跨塔系串味
		for i = 4, #list do
			local n = list[i]

			if st.seen[n] then
				kinds[n] = true
			end
		end
	end

	return kinds
end

-- 当前该塔系应当锁定的四级塔名单；无需锁定则返回 nil
local function locked_towers_for(store, family)
	local c = hook.cfg

	if not c or not store then
		return nil
	end

	local max_n = tonumber(c.max_branches_per_family) or 0

	if max_n <= 0 then
		return nil
	end

	local list = GS[FAMILY_LIST[family]]

	if not list then
		return nil
	end

	local kinds = used_kinds(store, list, c.lock_mode ~= "current")

	if count_keys(kinds) < max_n then
		return nil
	end

	local locked = {}

	for i = 4, #list do
		local n = list[i]

		if c.lock_chosen_too or not kinds[n] then
			locked[#locked + 1] = n
		end
	end

	if #locked == 0 then
		return nil
	end

	return locked
end

-- 把 TowerMenu 的钩子挂上（幂等；TowerMenu 被重新定义后会自动重挂）
local function install_menu_hooks()
	local TM = TowerMenu

	if type(TM) ~= "table" or type(TM.show) ~= "function" or type(TM.button_callback) ~= "function" then
		return false
	end

	if state.installed and state.menu_class == TM then
		return true
	end

	HOOK(TM, "show", hook.TowerMenu.show)
	HOOK(TM, "button_callback", hook.TowerMenu.button_callback)

	state.menu_class = TM
	state.installed = true

	log.info("tower_branch_limit: TowerMenu hooks installed")

	return true
end

--=========================== 钩子 ===========================

function hook.TowerMenu.show(show, self, tower_menu)
	local store = game and game.store
	local level_locks = store and store.level and store.level.locked_towers
	local injected = nil
	local original_len = 0

	if level_locks then
		original_len = #level_locks

		local gg = (game and game.game_gui) or get_game_gui()
		local entity = gg and gg.selected_entity
		local tw = entity and entity.tower
		local family = tw and FAMILY_LIST[tw.type]

		-- 只有「初级塔升到三级、准备选四级分支」这一档菜单需要处理
		if family and tw.level == 3 then
			injected = locked_towers_for(store, tw.type)
		end
	end

	-- 临时把锁定名单接在关卡锁定表后面，本体随即按它画锁图标
	if injected then
		for i = 1, #injected do
			level_locks[original_len + i] = injected[i]
		end
	end

	local ok, err = pcall(show, self, tower_menu)

	-- 无论成败都还原，绝不把临时锁定留在关卡数据里
	if injected then
		for i = #level_locks, original_len + 1, -1 do
			level_locks[i] = nil
		end
	end

	if not ok then
		error(err, 0)
	end
end

function hook.TowerMenu.button_callback(cb, self, button, item, entity, mouse_button, x, y)
	local store = game and game.store

	if store and item and item.action == "tw_upgrade" then
		local family = family_of_tower(item.action_arg)

		if family then
			local locked = locked_towers_for(store, family)

			if locked and contains(locked, item.action_arg) then
				-- 菜单是旧的（打开之后该塔系分支被用满了）：拒绝升级并刷新菜单
				log.warning("tower_branch_limit: refused stale upgrade to %s", tostring(item.action_arg))
				pcall(function()
					self:show()
				end)

				return
			end

			-- 记入本局已选用的分支
			game_state(store).seen[item.action_arg] = true
		end
	end

	return cb(self, button, item, entity, mouse_button, x, y)
end

function hook.simulation.do_tick(next, self, dt)
	local r = next(self, dt)

	if state.installed and state.menu_class == TowerMenu then
		return r
	end

	install_menu_hooks()

	return r
end

--======================= 插件生命周期 =======================

function hook:init(plugin_data)
	self.plugin_data = plugin_data

	package.loaded["tower_branch_limit.tower_branch_limit_config"] = nil
	self.cfg = require("tower_branch_limit.tower_branch_limit_config")

	state.game_gui = nil
	state.menu_class = nil
	state.installed = false

	HOOK(simulation, "do_tick", self.simulation.do_tick)

	-- game_gui 可能还没加载，挂不上就交给 do_tick 兜底重试
	install_menu_hooks()
end

function hook:on_config_change(new_config)
	self.cfg = new_config
end

function hook:unload(plugin_data)
	if state.menu_class then
		UNHOOK(state.menu_class, "show", self.TowerMenu.show)
		UNHOOK(state.menu_class, "button_callback", self.TowerMenu.button_callback)
	end

	UNHOOK(simulation, "do_tick", self.simulation.do_tick)

	state.menu_class = nil
	state.installed = false
	state.game_gui = nil
end

hook.reload = hook.init

return hook
