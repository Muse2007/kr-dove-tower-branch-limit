# 离线逻辑测试

本体没有独立的 Lua 解释器，但自带 `lua51.dll`。这里用 Python + ctypes 起一个**真实的 Lua 状态**，
桩掉游戏外壳（`TowerMenu` / `simulation` / `game` / `kr1.game_settings`），只测插件自身的逻辑。

## 依赖

- 本体自带的 `lua51.dll`（在游戏根目录，和 `love.exe` 放一起）
- Python 3（只用标准库 `ctypes` / `argparse` / `tempfile`）

## 跑

```bash
# 基础模式：用测试桩 hook_utils
python run.py --dll "D:/Game/王国保卫战Dove版/lua51.dll"

# 加强模式：额外用「本体真实的 hook_utils.lua」再跑一遍
# （验证插件对真实钩子 API 的用法：责任链、auto_table、优先级、UNHOOK）
python run.py --dll "D:/Game/王国保卫战Dove版/lua51.dll" \
              --real-hookutils "D:/Game/王国保卫战Dove版/KingdomRushDove/plugin/all/hook_utils.lua"
```

插件与测试脚本的路径默认取仓库内的文件，也可以用 `--plugin` / `--test` 指定。

> 为什么先复制到临时目录？Lua 5.1 的 `fopen` 处理不了非 ASCII 路径，而游戏目录常带中文
> （例如 `王国保卫战Dove版`）。脚本会先把要加载的文件复制到 ASCII 临时目录再执行。

## 测试覆盖（共 49 项断言）

| 分组 | 覆盖内容 |
| --- | --- |
| 初始化 | 三个钩子成功挂载；`do_tick` 仍可正常调用（返回值透传） |
| 计数 | 0 / 1 / 2 种四级塔时的锁定表现；上限配成 `0`（不限制）与 `1` |
| 塔系隔离 | 箭塔用满不影响法塔 / 炮塔 / 兵营；法塔用满也不影响箭塔 |
| 菜单范围 | 一、二级塔菜单与四级塔自身菜单不受影响；只锁四级塔，不碰初级塔 |
| 锁定集合 | 已选中的分支不锁、未选中的锁；`lock_chosen_too = true` 时全部锁 |
| 计数模式 | `ever` 卖塔不解锁；`current` 卖塔后解锁 |
| 还原 | 菜单构建期间临时并入、结束后还原；**`show` 中途报错也必须还原** |
| 记账与拦截 | 选中分支写入本局历史；菜单过期时的越权升级被拦下并刷新菜单 |
| 生命周期 | 新一局历史清空；`unload` 撤销全部钩子 |

## 说明

测试只覆盖插件的**纯逻辑**（计数、锁定集合、钩子生命周期）。实机交互部分——锁图标在菜单里的
显示位置、点击手感、与其它插件共存——需要在游戏里实际确认。
