-- tower_branch_limit 逻辑测试（桩掉游戏外壳，只测插件自身逻辑）
-- 由 run.py 通过 lua51.dll 执行

local PLUGIN = os.getenv("TBL_PLUGIN")
local REAL_HOOKUTILS = os.getenv("TBL_HOOKUTILS")

_ = function(s)
	return s
end

------------------------------------------------------------------
-- 1. 桩：hook_utils
--    设了 TBL_HOOKUTILS 时加载「本体真实的 hook_utils.lua」，
--    用来验证插件对真实钩子 API 的用法（责任链 / auto_table / 优先级）。
------------------------------------------------------------------
if REAL_HOOKUTILS then
	print("[hook_utils] 使用本体真实实现: " .. REAL_HOOKUTILS)
	package.preload["hook_utils"] = function()
		return dofile(REAL_HOOKUTILS)
	end
else
	print("[hook_utils] 使用测试桩")
	package.preload["hook_utils"] = function()
	local M = {}
	M.auto_table_mt = {
		__index = function(t, k)
			local n = {}
			setmetatable(n, M.auto_table_mt)
			rawset(t, k, n)
			return n
		end,
	}

	function M:new()
		local n = {}
		setmetatable(n, M.auto_table_mt)
		return n
	end

	local function rebuild(obj, fn)
		local info = obj.__hooks[fn]
		local hooks = info.hooks
		if #hooks == 0 then
			obj[fn] = info.original
			return
		end
		local next_fn = info.original
		for i = #hooks, 1, -1 do
			local handler = hooks[i].handler
			local prev = next_fn
			next_fn = function(...)
				return handler(prev, ...)
			end
		end
		obj[fn] = next_fn
	end

	function M.HOOK(obj, fn, handler, priority)
		assert(type(obj) == "table", "HOOK: obj is not a table")
		assert(type(obj[fn]) == "function", "HOOK: missing function " .. tostring(fn))
		assert(type(handler) == "function", "HOOK: handler is not a function")
		obj.__hooks = obj.__hooks or {}
		if not obj.__hooks[fn] then
			obj.__hooks[fn] = { original = obj[fn], hooks = {} }
		end
		local info = obj.__hooks[fn]
		info.hooks[#info.hooks + 1] = { handler = handler, priority = priority or 0 }
		table.sort(info.hooks, function(a, b)
			return a.priority < b.priority
		end)
		rebuild(obj, fn)
	end

	function M.UNHOOK(obj, fn, handler)
		local info = obj.__hooks and obj.__hooks[fn]
		if not info then
			return
		end
		for i = #info.hooks, 1, -1 do
			if info.hooks[i].handler == handler then
				table.remove(info.hooks, i)
			end
		end
		rebuild(obj, fn)
	end

	return M
	end
end

------------------------------------------------------------------
-- 2. 桩：log / game_settings
------------------------------------------------------------------
package.preload["lib.klua.log"] = function()
	return {
		new = function()
			return {
				info = function() end,
				warning = function() end,
				error = function() end,
			}
		end,
	}
end

local GS_STUB = {
	archer_towers = {
		"tower_archer_1", "tower_archer_2", "tower_archer_3",
		"tower_ranger", "tower_musketeer", "tower_crossbow", "tower_totem",
	},
	mage_towers = {
		"tower_mage_1", "tower_mage_2", "tower_mage_3",
		"tower_archmage", "tower_sorcerer", "tower_wild_magus",
	},
	engineer_towers = {
		"tower_engineer_1", "tower_engineer_2", "tower_engineer_3",
		"tower_bfg", "tower_tesla",
	},
	barrack_towers = {
		"tower_barrack_1", "tower_barrack_2", "tower_barrack_3",
		"tower_paladin", "tower_barbarian",
	},
}
package.preload["kr1.game_settings"] = function()
	return GS_STUB
end

-- 插件配置（测试里直接指定，避免读真实 config 文件）
package.preload["tower_branch_limit.tower_branch_limit_config"] = function()
	return { max_branches_per_family = 2, lock_mode = "ever", lock_chosen_too = false }
end

------------------------------------------------------------------
-- 3. 桩：游戏外壳（TowerMenu / simulation / game）
------------------------------------------------------------------
game = {} -- 插件通过全局 game.store / game.game_gui 取运行时数据

local show_locks = nil       -- 本次菜单构建时看到的锁定集合
local show_len_during = nil  -- 菜单构建期间 locked_towers 的长度
local show_error = nil       -- 让 show 抛错以测试还原
local last_callback = nil

TowerMenu = {}

function TowerMenu:show(tower_menu)
	local locks = game.store.level.locked_towers
	local m = {}
	for _, n in ipairs(locks) do
		m[n] = true
	end
	show_locks = m
	show_len_during = #locks
	if show_error then
		error("boom")
	end
end

function TowerMenu:button_callback(button, item, entity, mouse_button, x, y)
	last_callback = item and item.action_arg
	return "callback-ran"
end

simulation = {
	do_tick = function(self, dt)
		return "tick"
	end,
}

------------------------------------------------------------------
-- 4. 载入插件
------------------------------------------------------------------
local hook = dofile(PLUGIN)

------------------------------------------------------------------
-- 5. 测试框架
------------------------------------------------------------------
local passed, failed = 0, 0

local function check(name, cond, extra)
	if cond then
		passed = passed + 1
		print("PASS  " .. name)
	else
		failed = failed + 1
		print("FAIL  " .. name .. (extra and ("  <" .. tostring(extra) .. ">") or ""))
	end
end

local function new_store(extra_locks)
	local store = {
		ephemeral = {},
		towers = {},
		level = { locked_towers = {} },
	}
	if extra_locks then
		for _, n in ipairs(extra_locks) do
			store.level.locked_towers[#store.level.locked_towers + 1] = n
		end
	end
	return store
end

local next_id = 0
local function add_tower(store, name)
	next_id = next_id + 1
	store.towers[next_id] = { template_name = name }
	return next_id
end

local ARCHER_3 = { tower = { type = "archer", level = 3 } }
local ARCHER_1 = { tower = { type = "archer", level = 1 } }
local RANGER = { tower = { type = "ranger", level = 1 } }

local function open_menu(store, entity, locks_before)
	game.store = store
	game.game_gui = { selected_entity = entity or ARCHER_3 }
	show_locks, show_len_during = nil, nil
	local ok, err = pcall(function()
		TowerMenu:show()
	end)
	return ok, err
end

------------------------------------------------------------------
-- 6. 初始化
------------------------------------------------------------------
hook.cfg = { max_branches_per_family = 2, lock_mode = "ever", lock_chosen_too = false }
hook:init({ entry = "tower_branch_limit" })

check("init: do_tick 钩子已挂上", simulation.__hooks ~= nil and simulation.__hooks.do_tick ~= nil)
check("init: TowerMenu.show 钩子已挂上", TowerMenu.__hooks ~= nil and TowerMenu.__hooks.show ~= nil)
check("init: TowerMenu.button_callback 钩子已挂上", TowerMenu.__hooks.button_callback ~= nil)
check("init: simulation.do_tick 仍可调用", simulation:do_tick(0.016) == "tick")

------------------------------------------------------------------
-- 用例 1：一局刚开始，什么都没有 —— 不锁
------------------------------------------------------------------
do
	local store = new_store({ "tower_bfg" })
	local ok = open_menu(store)
	check("1a 无四级塔时不锁任何分支", ok and show_locks["tower_ranger"] == nil and show_locks["tower_musketeer"] == nil)
	check("1b 关卡原有锁定仍然生效", show_locks["tower_bfg"] == true)
	check("1c 菜单期间临时并入、事后还原", #store.level.locked_towers == 1, #store.level.locked_towers)
end

------------------------------------------------------------------
-- 用例 2：已有 1 种四级箭塔 —— 仍不锁
------------------------------------------------------------------
do
	local store = new_store()
	add_tower(store, "tower_ranger")
	open_menu(store)
	check("2a 只有 1 种时其余分支不锁", show_locks["tower_musketeer"] == nil and show_locks["tower_crossbow"] == nil)
	check("2b 事后还原", #store.level.locked_towers == 0)
end

------------------------------------------------------------------
-- 用例 3：已有 2 种四级箭塔 —— 其余锁死，已选的仍可建
------------------------------------------------------------------
do
	local store = new_store()
	add_tower(store, "tower_ranger")
	add_tower(store, "tower_musketeer")
	open_menu(store)
	check("3a 用满 2 种后第三种被锁", show_locks["tower_crossbow"] == true)
	check("3b 第四种也被锁", show_locks["tower_totem"] == true)
	check("3c 已选中的分支不锁(游侠)", show_locks["tower_ranger"] == nil)
	check("3d 已选中的分支不锁(火枪)", show_locks["tower_musketeer"] == nil)
	check("3e 只锁四级塔，不碰初级塔", show_locks["tower_archer_2"] == nil)
	check("3f 事后还原", #store.level.locked_towers == 0, #store.level.locked_towers)
end

------------------------------------------------------------------
-- 用例 4：塔系互不影响（箭塔用满，法塔不受影响）
------------------------------------------------------------------
do
	local store = new_store()
	add_tower(store, "tower_ranger")
	add_tower(store, "tower_musketeer")
	open_menu(store, { tower = { type = "mage", level = 3 } })
	check("4a 法塔不受箭塔影响", show_locks["tower_archmage"] == nil and show_locks["tower_sorcerer"] == nil)
	open_menu(store, { tower = { type = "archer", level = 3 } })
	check("4b 箭塔照旧被锁", show_locks["tower_crossbow"] == true)
end

------------------------------------------------------------------
-- 用例 5：一/二级塔菜单不受影响
------------------------------------------------------------------
do
	local store = new_store()
	add_tower(store, "tower_ranger")
	add_tower(store, "tower_musketeer")
	open_menu(store, ARCHER_1)
	check("5a 一级塔菜单不注入锁定", show_locks["tower_crossbow"] == nil)
	open_menu(store, RANGER)
	check("5b 四级塔自身菜单不注入锁定", show_locks["tower_crossbow"] == nil)
end

------------------------------------------------------------------
-- 用例 6：ever 模式卖塔不解锁；current 模式解锁
------------------------------------------------------------------
do
	local store = new_store()
	add_tower(store, "tower_ranger")
	add_tower(store, "tower_musketeer")
	open_menu(store) -- 记录历史
	store.towers = { [1] = { template_name = "tower_ranger" } } -- 卖掉火枪
	open_menu(store)
	check("6a ever 模式：卖塔后仍锁", show_locks["tower_crossbow"] == true)

	hook.cfg = { max_branches_per_family = 2, lock_mode = "current", lock_chosen_too = false }
	local store2 = new_store()
	add_tower(store2, "tower_ranger")
	add_tower(store2, "tower_musketeer")
	open_menu(store2)
	check("6b current 模式：卖塔前锁", show_locks["tower_crossbow"] == true)
	store2.towers = { [1] = { template_name = "tower_ranger" } }
	open_menu(store2)
	check("6c current 模式：卖塔后解锁", show_locks["tower_crossbow"] == nil)

	hook.cfg = { max_branches_per_family = 2, lock_mode = "ever", lock_chosen_too = false }
end

------------------------------------------------------------------
-- 用例 7：lock_chosen_too = true —— 连已选分支一起锁
------------------------------------------------------------------
do
	hook.cfg = { max_branches_per_family = 2, lock_mode = "current", lock_chosen_too = true }
	local store = new_store()
	add_tower(store, "tower_ranger")
	add_tower(store, "tower_musketeer")
	open_menu(store)
	check("7a 用满后连游侠也锁", show_locks["tower_ranger"] == true)
	check("7b 用满后连火枪也锁", show_locks["tower_musketeer"] == true)
	check("7c 其余分支照样锁", show_locks["tower_crossbow"] == true)
	hook.cfg = { max_branches_per_family = 2, lock_mode = "ever", lock_chosen_too = false }
end

------------------------------------------------------------------
-- 用例 8：上限可配（0 = 不限制；1 = 只能有一个分支）
------------------------------------------------------------------
do
	hook.cfg = { max_branches_per_family = 0, lock_mode = "ever", lock_chosen_too = false }
	local store = new_store()
	add_tower(store, "tower_ranger")
	add_tower(store, "tower_musketeer")
	open_menu(store)
	check("8a 上限 0 = 完全不限制", show_locks["tower_crossbow"] == nil)

	hook.cfg = { max_branches_per_family = 1, lock_mode = "ever", lock_chosen_too = false }
	local store2 = new_store()
	add_tower(store2, "tower_ranger")
	open_menu(store2)
	check("8b 上限 1 = 选一种后即锁其余", show_locks["tower_musketeer"] == true)
	check("8c 上限 1 = 已选的仍可建", show_locks["tower_ranger"] == nil)

	hook.cfg = { max_branches_per_family = 2, lock_mode = "ever", lock_chosen_too = false }
end

------------------------------------------------------------------
-- 用例 9：show 抛错时也必须还原锁定表
------------------------------------------------------------------
do
	local store = new_store({ "tower_bfg" })
	add_tower(store, "tower_ranger")
	add_tower(store, "tower_musketeer")
	show_error = true
	local ok = open_menu(store)
	show_error = nil
	check("9a show 内部报错会向外抛出", ok == false)
	check("9b 报错后锁定表已还原", #store.level.locked_towers == 1, #store.level.locked_towers)
end

------------------------------------------------------------------
-- 用例 10：选中分支会被记进本局历史（决定 ever 模式）
------------------------------------------------------------------
do
	local store = new_store()
	game.store = store
	local item = { action = "tw_upgrade", action_arg = "tower_ranger" }
	local r = TowerMenu:button_callback(nil, item, nil, 1, 0, 0)
	check("10a 正常升级会继续走原逻辑", r == "callback-ran")
	check("10b 选中的分支写入本局历史", store.ephemeral.tower_branch_limit.seen["tower_ranger"] == true)
	-- 再选第二种
	TowerMenu:button_callback(nil, { action = "tw_upgrade", action_arg = "tower_musketeer" }, nil, 1, 0, 0)
	add_tower(store, "tower_ranger")
	open_menu(store)
	check("10c 历史里已有两种 -> 其余被锁", show_locks["tower_crossbow"] == true)
end

------------------------------------------------------------------
-- 用例 11：菜单过期时的越权升级会被拦下
------------------------------------------------------------------
do
	local store = new_store()
	add_tower(store, "tower_ranger")
	add_tower(store, "tower_musketeer")
	game.store = store
	last_callback = nil
	local r = TowerMenu:button_callback(nil, { action = "tw_upgrade", action_arg = "tower_crossbow" }, nil, 1, 0, 0)
	check("11a 越权升级被拦截(不执行原逻辑)", r == nil and last_callback == nil)
	check("11b 拦截后菜单被刷新且该分支显示为锁", show_locks["tower_crossbow"] == true)
end

------------------------------------------------------------------
-- 用例 12：非四级塔目标 / 随机塔按钮不受影响
------------------------------------------------------------------
do
	local store = new_store()
	game.store = store
	last_callback = nil
	TowerMenu:button_callback(nil, { action = "tw_upgrade", action_arg = "tower_archer_2" }, nil, 1, 0, 0)
	check("12a 升二级塔不受影响", last_callback == "tower_archer_2")
	last_callback = nil
	TowerMenu:button_callback(nil, { action = "tw_upgrade", action_arg = "tower_random_advanced_archer" }, nil, 1, 0, 0)
	check("12b 随机塔按钮不受影响", last_callback == "tower_random_advanced_archer")
	last_callback = nil
	TowerMenu:button_callback(nil, { action = "tw_sell" }, nil, 1, 0, 0)
	check("12c 卖塔按钮不受影响", last_callback == nil)
end

------------------------------------------------------------------
-- 用例 13：新一局（新 store）历史清空
------------------------------------------------------------------
do
	local store_a = new_store()
	add_tower(store_a, "tower_ranger")
	add_tower(store_a, "tower_musketeer")
	open_menu(store_a)
	check("13a 上一局已锁", show_locks["tower_crossbow"] == true)
	local store_b = new_store()
	open_menu(store_b)
	check("13b 新一局历史清空，不再锁", show_locks["tower_crossbow"] == nil)
end

------------------------------------------------------------------
-- 用例 15：跨塔系不串味（历史集合必须按塔系隔离）
------------------------------------------------------------------
do
	local store = new_store()
	game.store = store
	-- 先在法塔上「选」满两个分支
	TowerMenu:button_callback(nil, { action = "tw_upgrade", action_arg = "tower_archmage" }, nil, 1, 0, 0)
	TowerMenu:button_callback(nil, { action = "tw_upgrade", action_arg = "tower_sorcerer" }, nil, 1, 0, 0)

	open_menu(store, { tower = { type = "archer", level = 3 } })
	check("15a 法塔选满不影响箭塔分支", show_locks["tower_crossbow"] == nil and show_locks["tower_ranger"] == nil)

	open_menu(store, { tower = { type = "engineer", level = 3 } })
	check("15b 法塔选满不影响炮塔分支", show_locks["tower_bfg"] == nil and show_locks["tower_tesla"] == nil)

	open_menu(store, { tower = { type = "barrack", level = 3 } })
	check("15c 法塔选满不影响兵营分支", show_locks["tower_paladin"] == nil)

	open_menu(store, { tower = { type = "mage", level = 3 } })
	check("15d 法塔自己才被锁", show_locks["tower_wild_magus"] == true)
	check("15e 已选中的法塔分支不锁", show_locks["tower_archmage"] == nil and show_locks["tower_sorcerer"] == nil)
end

------------------------------------------------------------------
-- 用例 14：unload 撤销所有钩子
------------------------------------------------------------------
do
	local store = new_store()
	add_tower(store, "tower_ranger")
	add_tower(store, "tower_musketeer")
	hook:unload({ entry = "tower_branch_limit" })
	open_menu(store)
	check("14a 卸载后不再注入锁定", show_locks["tower_crossbow"] == nil)
	check("14b do_tick 钩子已移除", simulation.__hooks.do_tick == nil or #simulation.__hooks.do_tick.hooks == 0)
	check("14c show 钩子已移除", TowerMenu.__hooks.show == nil or #TowerMenu.__hooks.show.hooks == 0)
	check("14d button_callback 钩子已移除", TowerMenu.__hooks.button_callback == nil or #TowerMenu.__hooks.button_callback.hooks == 0)
end

------------------------------------------------------------------
print(string.format("\n===== %d passed, %d failed =====", passed, failed))
if failed > 0 then
	error(string.format("%d test(s) failed", failed))
end
