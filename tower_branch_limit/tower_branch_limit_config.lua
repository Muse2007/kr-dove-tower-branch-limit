-- 四级塔双分支限制 —— 玩家可调参数
-- 在插件管理器中点击「配置」即可修改（改完记得点「应用」）。
return {
	-- 每个塔系（箭塔/法塔/炮塔/兵营）本局最多可以选用的「不同种类」四级塔数量。
	-- 设为 0 或负数表示不限制。
	max_branches_per_family = 2,

	-- 计数方式：
	--   "ever"    —— 只要本局建造过该种类的四级塔，就永久算作已占用（卖掉了解锁不了其它分支）。
	--   "current" —— 只统计场上现存的四级塔种类，卖掉后其它分支会重新解锁。
	lock_mode = "ever",

	-- 用满分支后，是否连「已经选中的种类」也一起锁掉。
	--   false —— 已选中的种类仍可继续重复建造，只锁没选过的种类（推荐）。
	--   true  —— 该塔系用满后不能再造任何四级塔。
	lock_chosen_too = false,

	-- 保留字段：字段名 → 配置面板上的显示名称
	key_label_map = {
		max_branches_per_family = "每系四级分支上限(0=不限制)",
		lock_mode = "计数方式(ever=累计 / current=现存)",
		lock_chosen_too = "用满后连已选分支一起锁定",
	},

	-- 保留字段：配置面板的显示顺序
	key_order_list = {
		"max_branches_per_family",
		"lock_mode",
		"lock_chosen_too",
	},
}
