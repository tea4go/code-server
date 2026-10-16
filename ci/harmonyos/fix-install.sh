#!/bin/sh
# 让 code-server 的 linux-arm64 安装在 HarmonyOS（鸿蒙 PC）上可用。
#
# 需要两处修复：
#   1) 原生模块 .node 缺少 .codesign 会被内核拒载（dlopen 报 Permission denied）。
#      用 OHOS 工具链重建：harmonybrew 的 aarch64-linux-ohos-gcc/g++，其 ld 默认
#      --code-sign，产物自带有效签名（签名与内容绑定，无法搬运或伪造）。
#   2) 本机 node 的 process.platform 为 "openharmony"，而整个 bundle 是 linux-arm64
#      构建；VS Code 的子进程（ptyHost 等）据此抛 "Platform not supported"，集成
#      终端空白。VS Code 会剥离子进程的 NODE_OPTIONS/LD_PRELOAD，故需在子进程公共
#      入口 lib/vscode/out/bootstrap-fork.js 注入 process.platform="linux" 覆盖。
#
# 用法:
#   ci/harmonyos/fix-install.sh [安装目录]
#     安装目录缺省取最新的 ~/.local/lib/code-server-*-linux-arm64。
#   先构建到临时目录并逐个验证，全部通过才落地；幂等，可重复运行。
#   原文件会备份为同目录下的 *.orig。改动对运行中的实例需重启后生效。
#
# 环境变量:
#   HARMONYBREW_PREFIX  默认 ~/.harmonybrew
#   WORKDIR             构建临时目录，默认 ~/.cache/code-server-harmonyos
#   JOBS                并行编译数，默认 4（内存紧张时调小）
#
# 未处理（不影响基本使用）:
#   - kerberos：需 gssapi 开发头文件，缺失则自动跳过（仅 Kerberos 数据库认证需要）。
#   - 预编译的第三方 .node（如 copilot 扩展自带的 runtime.node）无源码可重建；
#     且 agentHost 依赖的路径 socket 在鸿蒙被禁，Copilot 功能不可用。
#
# 注意: 本脚本用 POSIX sh（鸿蒙 PC 只有 toybox sh，无 bash / jq）。
set -eu

say()  { printf '==> %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
die()  { printf '[err] %s\n' "$*" >&2; exit 1; }

# ---------- 定位安装目录 ----------
if [ $# -ge 1 ]; then
  INSTALL_DIR=$1
else
  INSTALL_DIR=$(ls -dt "$HOME"/.local/lib/code-server-*-linux-arm64 2>/dev/null | head -1 || true)
fi
if [ -z "${INSTALL_DIR:-}" ] || [ ! -d "$INSTALL_DIR" ]; then
  die "找不到安装目录；请作为参数传入"
fi
INSTALL_DIR=$(cd "$INSTALL_DIR" && pwd)
VSCODE_DIR=$INSTALL_DIR/lib/vscode
[ -d "$VSCODE_DIR" ] || die "$VSCODE_DIR 不存在（不是 code-server 安装目录？）"
say "安装目录: $INSTALL_DIR"

# ---------- 定位工具链 ----------
HB=${HARMONYBREW_PREFIX:-$HOME/.harmonybrew}
PATH="$HB/bin:$PATH"; export PATH

# 若 PATH 里没有 node，尝试 nvm 的安装位置（脱离登录会话运行时常发生）。
if ! command -v node >/dev/null 2>&1; then
  for nb in "$HOME"/.nvm/versions/node/*/bin; do
    if [ -x "$nb/node" ]; then
      PATH="$nb:$PATH"
      break
    fi
  done
  export PATH
fi

GCC=$(command -v gcc || true)
GXX=$(command -v g++ || true)
if [ -z "${GCC:-}" ] || [ -z "${GXX:-}" ]; then
  die "找不到 gcc/g++（需 harmonybrew 的 gcc，提供 aarch64-linux-ohos-*）"
fi
if ! "$GCC" -dumpmachine 2>/dev/null | grep -q ohos; then
  warn "gcc 可能不是 OHOS 工具链：$GCC（产物可能缺 .codesign）"
fi

PY=$(command -v python3 2>/dev/null || true)
if [ -z "${PY:-}" ]; then
  PY=$(ls "$HB"/bin/python3* 2>/dev/null | head -1 || true)
fi
[ -n "${PY:-}" ] || die "找不到 python3（node-gyp 需要；装 harmonybrew 的 python@3.12）"

NODE_BIN=$(command -v node || true)
[ -n "${NODE_BIN:-}" ] || die "PATH 里没有 node"
NODEDIR=$(dirname "$(dirname "$NODE_BIN")")
NG=$NODEDIR/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js
if [ ! -f "$NG" ]; then
  NG=$(find "$NODEDIR" -path '*node-gyp/bin/node-gyp.js' 2>/dev/null | head -1)
fi
[ -f "${NG:-}" ] || die "找不到 node-gyp（应随 npm 一起安装）"

say "gcc      = $GCC"
say "g++      = $GXX"
say "python   = $PY"
say "node     = $NODE_BIN"
say "node-gyp = $NG"

export CC=$GCC CXX=$GXX
export JOBS=${JOBS:-4}
export npm_config_nodedir="$NODEDIR"

# OHOS 的 <fortify/*.h> 只支持 Clang；某些模块（如 argon2）的 binding.gyp 会在未
# 预定义时追加 _FORTIFY_SOURCE=2，导致 GCC 报错。预先定义成 0（头文件条件是 >0）
# 即可让其跳过追加，同时不触发报错。
export CFLAGS="${CFLAGS:-} -D_FORTIFY_SOURCE=0"
export CXXFLAGS="${CXXFLAGS:-} -D_FORTIFY_SOURCE=0"
export CPPFLAGS="${CPPFLAGS:-} -D_FORTIFY_SOURCE=0"

WORK=${WORKDIR:-$HOME/.cache/code-server-harmonyos}
mkdir -p "$WORK"
say "构建目录: $WORK"

# ---------- 需要重建的模块 ----------
# 格式: 包名|安装目录内包路径|产物文件名|部署目标（相对安装目录）|是否可选(yes/no)
LIST=$WORK/modules.list
cat > "$LIST" <<'EOF'
argon2|node_modules/argon2|argon2.node|node_modules/argon2/build/Release/argon2.node|no
@parcel/watcher|lib/vscode/node_modules/@parcel/watcher|watcher.node|lib/vscode/node_modules/@parcel/watcher/build/Release/watcher.node|no
node-pty|lib/vscode/node_modules/node-pty|pty.node|lib/vscode/node_modules/node-pty/build/Release/pty.node|no
@vscode/sqlite3|lib/vscode/node_modules/@vscode/sqlite3|vscode-sqlite3.node|lib/vscode/node_modules/@vscode/sqlite3/build/Release/vscode-sqlite3.node|no
@vscode/native-watchdog|lib/vscode/node_modules/@vscode/native-watchdog|watchdog.node|lib/vscode/node_modules/@vscode/native-watchdog/build/Release/watchdog.node|no
@vscode/spdlog|lib/vscode/node_modules/@vscode/spdlog|spdlog.node|lib/vscode/node_modules/@vscode/spdlog/build/Release/spdlog.node|no
kerberos|lib/vscode/node_modules/kerberos|kerberos.node|lib/vscode/node_modules/kerberos/build/Release/kerberos.node|yes
EOF

dlopen_ok() {
  out=$("$NODE_BIN" -e 'const m={exports:{}};process.dlopen(m,process.argv[1]);console.log("OK")' "$1" 2>&1 | tail -1)
  [ "$out" = OK ]
}
codesigned() {
  command -v readelf >/dev/null 2>&1 || return 1
  n=$(readelf -SW "$1" 2>/dev/null | grep -c codesign || true)
  [ "${n:-0}" -ge 1 ]
}

# ---------- 构建（先全部构建并验证，通过者才登记待部署） ----------
say "开始构建原生模块..."
DEPLOYED=$WORK/deployed.list
: > "$DEPLOYED"
while IFS='|' read -r pkg pkgdir artifact dest optional; do
  [ -n "${pkg:-}" ] || continue
  pj=$INSTALL_DIR/$pkgdir/package.json
  if [ ! -f "$pj" ]; then
    warn "跳过 $pkg：安装目录里没有 $pkgdir/package.json"
    continue
  fi
  ver=$("$NODE_BIN" -e "console.log(require('$pj').version)" 2>/dev/null || true)
  if [ -z "${ver:-}" ]; then
    warn "跳过 $pkg：读不到版本"
    continue
  fi

  tag=$(printf '%s' "$pkg" | tr '/@' '__')
  d=$WORK/$tag
  say "  构建 $pkg@$ver"
  rm -rf "$d"; mkdir -p "$d"
  if ! (
    cd "$d" || exit 1
    tb=$(npm pack "$pkg@$ver" 2>/dev/null | tail -1)
    [ -f "$tb" ] || { echo "PACK_FAIL"; exit 1; }
    tar xzf "$tb" || exit 1
    cd package || exit 1
    npm install --ignore-scripts --no-audit --no-fund >npm.log 2>&1 || { echo "NPM_INSTALL_FAIL"; tail -20 npm.log; exit 1; }
    "$NODE_BIN" "$NG" rebuild --nodedir="$NODEDIR" --python="$PY" >gyp.log 2>&1 || { echo "GYP_FAIL"; tail -30 gyp.log; exit 1; }
  ); then
    if [ "${optional:-}" = yes ]; then
      warn "跳过可选模块 $pkg（构建失败，详见 $d）"
      continue
    fi
    die "$pkg 构建失败（详见 $d 下的 npm.log / gyp.log）"
  fi

  art=$d/package/build/Release/$artifact
  reason=""
  if [ ! -f "$art" ]; then reason="未产出 $artifact"
  elif ! codesigned "$art"; then reason="产物缺 .codesign（工具链不对？）"
  elif ! dlopen_ok "$art"; then reason="产物 dlopen 失败"
  fi
  if [ -n "$reason" ]; then
    if [ "${optional:-}" = yes ]; then
      warn "跳过可选模块 $pkg：$reason"
      continue
    fi
    die "$pkg：$reason（详见 $d）"
  fi

  say "    验证通过: $artifact"
  printf '%s|%s\n' "$pkg" "$dest" >> "$DEPLOYED"
done < "$LIST"

[ -s "$DEPLOYED" ] || die "没有任何模块构建成功"

# ---------- 部署 ----------
say "部署到安装目录..."
while IFS='|' read -r pkg dest; do
  [ -n "${pkg:-}" ] || continue
  tag=$(printf '%s' "$pkg" | tr '/@' '__')
  art=$WORK/$tag/package/build/Release/$(basename "$dest")
  [ -f "$art" ] || continue
  dst=$INSTALL_DIR/$dest
  if [ ! -d "$(dirname "$dst")" ]; then
    warn "跳过部署 $pkg：目标目录不存在"
    continue
  fi
  if [ -f "$dst" ] && [ ! -f "$dst.orig" ]; then
    cp -p "$dst" "$dst.orig"
  fi
  # 目标可能正被运行中的 code-server 映射，直接覆盖会 EPERM；先写临时文件再原子改名。
  if ! cp "$art" "$dst.harmonyos.tmp"; then
    warn "部署 $pkg 失败：无法写入 $dest"
    continue
  fi
  mv "$dst.harmonyos.tmp" "$dst"
  say "  $pkg -> $dest"
done < "$DEPLOYED"

# ---------- platform 覆盖 ----------
BF=$VSCODE_DIR/out/bootstrap-fork.js
if [ ! -f "$BF" ]; then
  warn "找不到 $BF，跳过 platform 覆盖"
elif head -c 400 "$BF" | grep -q 'defineProperty(process'; then
  say "bootstrap-fork.js 已含 platform 覆盖，跳过"
else
  [ -f "$BF.orig" ] || cp -p "$BF" "$BF.orig"
  {
    printf '%s\n' 'try{Object.defineProperty(process,"platform",{value:"linux",configurable:true});}catch(e){}'
    cat "$BF.orig"
  } > "$BF.harmonyos.tmp"
  mv "$BF.harmonyos.tmp" "$BF"
  say "已注入 platform=linux 覆盖 -> lib/vscode/out/bootstrap-fork.js"
fi

# ---------- 最终校验 ----------
say "最终校验:"
fail=0
while IFS='|' read -r pkg dest; do
  [ -n "${pkg:-}" ] || continue
  dst=$INSTALL_DIR/$dest
  if [ ! -f "$dst" ]; then
    printf '  %-28s 缺失\n' "$pkg"; fail=1; continue
  fi
  cs=no; if codesigned "$dst"; then cs=yes; fi
  ok=no; if dlopen_ok "$dst"; then ok=yes; fi
  printf '  %-28s codesign=%s dlopen=%s\n' "$pkg" "$cs" "$ok"
  if [ "$cs" != yes ] || [ "$ok" != yes ]; then fail=1; fi
done < "$DEPLOYED"

if [ -f "$BF" ] && head -c 400 "$BF" | grep -q 'defineProperty(process'; then
  printf '  %-28s ok\n' "bootstrap-fork platform"
else
  printf '  %-28s 缺失\n' "bootstrap-fork platform"; fail=1
fi

if [ "$fail" = 0 ]; then
  say "完成。启动: $INSTALL_DIR/bin/code-server"
else
  die "有校验未通过（见上）；原文件备份在 *.orig，可据此回滚"
fi
