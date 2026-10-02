"""离线逻辑测试：用本体自带的 lua51.dll 起一个真实 Lua 状态，跑插件的核心逻辑。

做法：桩掉游戏外壳（TowerMenu / simulation / game / GS），只测插件自身逻辑；
可选加载「本体真实的 hook_utils.lua」，用来验证插件对真实钩子 API 的用法。

用法：
    python run.py --dll "<游戏目录>/lua51.dll"
    python run.py --dll "<游戏目录>/lua51.dll" --real-hookutils "<游戏目录>/plugin/all/hook_utils.lua"

参数也可用环境变量给：TBL_DLL / TBL_PLUGIN / TBL_HOOKUTILS

注意：Lua 5.1 的 fopen 处理不了非 ASCII 路径（中文游戏目录），所以运行时会先把
脚本复制到一个临时目录再加载。
"""
import argparse
import ctypes
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
DEFAULT_PLUGIN = os.path.join(REPO, "tower_branch_limit", "tower_branch_limit.lua")
DEFAULT_TEST = os.path.join(HERE, "test.lua")


def parse_args():
    ap = argparse.ArgumentParser(description="tower_branch_limit 离线逻辑测试")
    ap.add_argument("--dll", default=os.environ.get("TBL_DLL"),
                    help="本体自带的 lua51.dll 路径（必填）")
    ap.add_argument("--plugin", default=os.environ.get("TBL_PLUGIN") or DEFAULT_PLUGIN,
                    help="插件入口文件路径，默认取仓库里的 tower_branch_limit/tower_branch_limit.lua")
    ap.add_argument("--test", default=DEFAULT_TEST, help="测试脚本路径，默认同目录的 test.lua")
    ap.add_argument("--real-hookutils", default=os.environ.get("TBL_HOOKUTILS"),
                    help="本体 plugin/all/hook_utils.lua 的路径；给了就用真实实现跑一遍")
    args = ap.parse_args()
    if not args.dll:
        ap.error("需要 --dll 指向本体自带的 lua51.dll")
    for p in (args.dll, args.plugin, args.test):
        if not os.path.isfile(p):
            ap.error("文件不存在: %s" % p)
    return args


def stage(args, work):
    """把脚本复制到 ASCII 临时目录（Lua 5.1 打不开非 ASCII 路径）。"""
    plugin = os.path.join(work, "tower_branch_limit.lua")
    test = os.path.join(work, "test.lua")
    shutil.copyfile(args.plugin, plugin)
    shutil.copyfile(args.test, test)
    env = dict(os.environ)
    env["TBL_PLUGIN"] = plugin
    if args.real_hookutils:
        hu = os.path.join(work, "real_hook_utils.lua")
        shutil.copyfile(args.real_hookutils, hu)
        env["TBL_HOOKUTILS"] = hu
    else:
        env.pop("TBL_HOOKUTILS", None)
    return test, env


def main():
    args = parse_args()

    work = tempfile.mkdtemp(prefix="tbl_test_")
    # 注意：环境变量必须在 ctypes.CDLL 之前设好 —— MSVC 运行时只在 DLL 加载时
    # 快照一次进程环境，之后再改 os.environ，DLL 里的 getenv 看不到。
    saved = {k: os.environ.get(k) for k in ("TBL_PLUGIN", "TBL_HOOKUTILS")}
    test_path, env = stage(args, work)
    os.environ.update(env)

    try:
        lua = ctypes.CDLL(args.dll)
        lua.luaL_newstate.restype = ctypes.c_void_p
        lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
        lua.luaL_loadfile.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        lua.luaL_loadfile.restype = ctypes.c_int
        lua.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
        lua.lua_pcall.restype = ctypes.c_int
        lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                      ctypes.POINTER(ctypes.c_size_t)]
        lua.lua_tolstring.restype = ctypes.c_char_p

        L = lua.luaL_newstate()
        lua.luaL_openlibs(L)

        rc = lua.luaL_loadfile(L, test_path.encode("utf-8"))
        if rc != 0:
            msg = lua.lua_tolstring(L, -1, None)
            print("LOAD ERROR:\n" + (msg or b"").decode("utf-8", "replace"))
            return 2

        rc = lua.lua_pcall(L, 0, -1, 0)
        if rc != 0:
            msg = lua.lua_tolstring(L, -1, None)
            print("RUNTIME ERROR:\n" + (msg or b"").decode("utf-8", "replace"))
            return 1

        print("ALL TESTS OK")
        return 0
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
