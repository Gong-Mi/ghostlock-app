# XRing O1 kernelsu.ko 本地构建

在 Termux 上从上游 KernelSU 源码编出 XRing O1 可用的 `kernelsu.ko`。
产物与官方 CI ko 结构完全对齐（同 UNDEF 符号数、同空 `__versions` CRC 表、
同模块参数集），唯一区别是**编译期结构偏移来自 XRing 6.6.30 设备树**而非
GKI 6.6.127 参考树。

## 用法

```bash
bash ksu-ko/build.sh            # 默认基线 v3.3.0
bash ksu-ko/build.sh v3.2.5     # 指定 tag
KSRC=~/Xiaomi_Kernel_OpenSource/common-ogki \
KSU_SRC=~/kernelsu_upstream \
bash ksu-ko/build.sh            # 自定义路径
```

依赖：`clang llvm make bison flex bc python3 pyelftools`（pkg 装）。
脚本自建 `bionic-shim` 和 `bcwrap`（$TMPDIR 下，幂等）。

## 为什么不用官方预编 ko

逆向对比结论（2026-09-08，证据在 ~/ksu-compare/）：

| | 官方 v3.3.0 CI ko | ayyy XRing ko | 本脚本产物 |
|---|---|---|---|
| 编译树 | GKI 6.6.127 | XRing 6.6.77 设备树 | **XRing 6.6.30 开源树** |
| UNDEF 符号 | 218 | 220 | 218 |
| `__versions` CRC | 0 项 | 1 项 | 0 项 |
| 模块参数 | allow_shell, norc | + keep_permissive, disable_syscall_hooks, init_stage | allow_shell, norc |
| dispatcher 失败兜底 | **无** | kretprobe+kprobe 全套 | **无（=官方行为）** |
| selinux_hide kprobe 兜底 | **无** | 有 | **无（=官方行为）** |

vermagic flags（`SMP preempt mod_unload modversions aarch64`）三者逐字符一致，
且 `__versions` section 存在时 MODVERSIONS 加载器只比对 flags ——
所以 **vermagic 不是官方 ko 失败的原因**。

官方 ko 在 XRing 上失败的根因（按权重）：

1. **结构偏移不匹配**：GKI 6.6.127 树编译期烧死的内核结构假设 ≠ XRing 6.6.77 树。
   ksuinit 只能运行时改符号地址，改不了编译期偏移。hook 写错位置 → execve 坏 →
   ENOSYS + sync I/O error（毒 adbd 根因链）。
2. **缺兜底代码**（本脚本产物同样缺，属于"与官方差别"的待缩小项）：
   - XRing 上 `__arm64_sys_ni_syscall` 槽位/tracepoint dispatcher 建不起来时
     （`ksu_dispatcher_nr < 0`），官方/本产物无 fallback → su hook 静默失效；
     ayyy 有 kretprobe（execve + setresuid entry/ret + task_work）+ 4 个
     per-syscall kprobe 兜底。
   - selinux_hide 直接 patch_text `write_op`/`sel_handle_status_ops` 失败
     （read-only tables）时，官方/本产物放弃；ayyy 用 register_kprobe 兜底。
3. 越狱流参数（keep_permissive 等）：late-load 流程配合用。

## 已知的坑（脚本已内置处理）

- `HOST_EXTRACFLAGS` 命令行赋值会覆盖 `scripts/*/Makefile` 里的 `+=`（make 变量
  语义），所以 selinux/genheaders/mdp 想要的 include 路径必须全部显式列出。
- `gen-hyprel` 在 autoconf.h 生成前编译，需要先放 stub 再 syncconfig 重生成真的。
- dtc 的 yaml 支持引用树里 Makefile 没编进来的 `dt_to_yaml` → `-DNO_YAML`。
- objsec.h 的 `flask.h` 在 KOUT 生成，靠 `KCFLAGS=-I$KOUT/security/selinux/include`。
- clang>=21 对内核头报 `-Wdefault-const-init-var-unsafe`（error）→ KCFLAGS 关掉。
- 无 vmlinux/Module.symvers → `KBUILD_MODPOST_WARN=1` 把 modpost 未定义符号
  报错降级。这是设计使然：空 CRC 表 + 运行时符号解析正是官方 ko 的形态。

## 真机测试流程（violin）

```bash
adb push ~/kernelsu_upstream/kernel/kernelsu.ko /data/local/tmp/
adb shell 'chmod 755 /data/local/tmp/kernelsu.ko'
# 经 ghostlock exploit 拿 root 后（或已 root 设备）:
adb shell 'su -c "insmod /data/local/tmp/kernelsu.ko allow_shell=1"'
adb shell 'su -c "dmesg | tail -30"'
# 验收：dmesg 无 ENOSYS/sync I/O error；id → uid=0；adbd 存活
```

失败对照（缩小差别的迭代方向，按优先级）：
1. dmesg 出现 `hook_manager` / `selinux_hide` init 报错 → 移植 ayyy fallback
2. execve ENOSYS / adbd 死亡 → dispatcher 假设失败，优先移植差异 1
3. SELinux 状态异常 → 移植差异 2
4. late-load 后 enforcing 恢复时机不对 → 移植 keep_permissive 参数

## 基线说明

- 内核树：`Xiaomi_Kernel_OpenSource` @ `99a9aff00`（6.6.30-4k，MODVERSIONS=y）。
  设备实际跑 6.6.77，MODVERSIONS 下版本前缀由 CRC 表替代校验（ko 表为空 =
  不校验），同族 GKI 6.6.x 布局兼容；ayyy 的 6.6.77 ko 在 6.6.30 上实证可跑。
- KernelSU：上游 tag，默认 v3.3.0（UAPI 32601，配套管理器需同代）。
