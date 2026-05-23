# PathMask 2.2.8

- Fix Holmes "Abnormal Environment (04)" misdetection (and similar App Zygote-based probes that survive Zygisk Next denylist). The detector declares its `HolmesService` with `android:isolatedProcess="true" android:useAppZygote="true"` plus a `zygotePreloadName="me.garfieldhan.holmes.HolmesZygotePreload"` callback, then runs its native `preload()` integrity check (`/proc/self/maps` scan, linker / PLT-GOT inspection) inside the App Zygote process *before* the service is forked. The probe result is stashed in a static field, copy-on-write inherits it into the forked service, and Binder transaction `1625` ships the code back to `MainActivity`.
- The kernel module's "isolated UID" check (`hide_isolated`) only covered the regular isolated range `99000-99999` (`FIRST_ISOLATED_UID` / `LAST_ISOLATED_UID` from `frameworks/base android/os/Process.java`). App Zygote isolated processes use a different range `90000-98999` (`FIRST_APP_ZYGOTE_ISOLATED_UID` / `LAST_APP_ZYGOTE_ISOLATED_UID`, with `NUM_UIDS_PER_APP_ZYGOTE = 100` per app). Without that range in `should_hide_for_current()`, the preload callback ran in deny scope but path masking did **not** kick in, so `/data/adb/...`, Zygisk shared libraries, and the configured target paths stayed visible.
- `is_android_isolated_uid()` now matches both ranges. Existing config keeps working: enabling `hide_isolated=1` (the default) automatically covers App Zygote services without any extra UID list.
- `deny_packages.conf` ships with `me.garfieldhan.holmes` added so the *main* (non-isolated) app process is also covered when `MainActivity` later reads back the preload state via Binder.

中文说明：

- 修复 Holmes "Abnormal Environment (04)" 误报（以及其它走 App Zygote 路径的检测，包括 Zygisk Next denylist 拦不住的）。Holmes 把检测服务声明为 `android:isolatedProcess="true" android:useAppZygote="true"`，再用 `zygotePreloadName="me.garfieldhan.holmes.HolmesZygotePreload"` 在 App Zygote fork 之前就调用 native `preload()` 做 `/proc/self/maps` 扫描 + linker / PLT-GOT 检测。结果落到静态字段，COW 进 service 进程，最后通过 Binder 1625 号事务返回给 `MainActivity`。
- 内核模块原本的 "隔离 UID" 判定（`hide_isolated`）只覆盖 `99000-99999`（`FIRST_ISOLATED_UID` / `LAST_ISOLATED_UID`，见 `frameworks/base android/os/Process.java`）。App Zygote 用的是另一段 `90000-98999`（`FIRST_APP_ZYGOTE_ISOLATED_UID` / `LAST_APP_ZYGOTE_ISOLATED_UID`，每个 app 占 `NUM_UIDS_PER_APP_ZYGOTE = 100` 个 UID）。这一段没纳入 `should_hide_for_current()`，导致 deny 模式下 preload 跑的时候我们的路径隐藏完全没生效，`/data/adb/...`、Zygisk so 库以及配置的目标路径全部能被它读到。
- `is_android_isolated_uid()` 现在两段都匹配。配置不变：开启 `hide_isolated=1`（默认开启）就自动覆盖 App Zygote 服务，不用单独加 UID。
- `deny_packages.conf` 内置加上 `me.garfieldhan.holmes`，主进程非隔离的那一份在 `MainActivity` 通过 Binder 回读 preload 状态时也能被覆盖。

# PathMask 2.2.7

- Fix `cat /system_ext/app/SoterService/SoterService.apk` and other openat-based reads still succeeding even after v2.2.5/v2.2.6. The remaining gap was that `inode_permission`, while EXPORT_SYMBOL, also gets ThinLTO-inlined into `link_path_walk` itself, so the kretprobe attached to it covers some openers (those keep firing the "fired (first time)" log) but never gets called from the regular path walk that openat triggers. Reading a file *inside* a hidden directory therefore went straight through.
- Add `__arm64_sys_openat` and `__arm64_sys_openat2` to the kretprobe set. The same syscall-table-pointer argument as the v2.2.5 hooks applies: those entry stubs cannot be inlined. Hit detection reuses the existing `regs[1]` filename + prefix-match logic.
- Solve the openat fd-leak problem that originally kept these two syscalls off the hook list. The exit handler now invokes a kprobe-resolved `close_fd()` to release the fd that the syscall body just allocated, then overrides the return value to `-ENOENT`. If `close_fd` cannot be resolved on a particular kernel, the openat hook self-disables (entry handler returns without setting `matched`), so the open is allowed through rather than risking an fd-table leak. All other syscall hooks remain active.
- Fix WebUI health check falsely reporting "有路径当前不存在" in global scope: now that the module's own syscall hooks intercept stat() for every UID, the WebUI's `[ -e ]` probe gets `-ENOENT` for paths that the kernel actually resolved successfully -- exactly the symptom of working as designed. The WebUI now skips the user-space stat probe in `loaded + scope=global` and reads `/sys/module/pathmask/parameters/resolved_count` instead, which is set during insmod (before any hook is active) and reflects the kernel's view. The diagnostic report's "target existence" section gets the same treatment. In `deny` scope the WebUI shell (uid=0) is normally not in the deny list, so the legacy `[ -e ]` probe is still fine and stays unchanged.
- Add a read-only sysfs parameter `/sys/module/pathmask/parameters/resolved_count` exposing how many target paths the module successfully resolved at insmod time.
- Fix stat()/access()/readlink() still returning the hidden inode on Android GKI 5.15+ kernels even after v2.2.4 by adding kretprobes hooked at the arm64 syscall entry stubs (`__arm64_sys_newfstatat`, `__arm64_sys_statx`, `__arm64_sys_faccessat`, `__arm64_sys_faccessat2`, `__arm64_sys_readlinkat`). These stubs are stored as function pointers in `sys_call_table[]`, which forces the linker to keep them out-of-line at a fixed address regardless of LTO. The previous `inode_permission` / `vfs_getattr` / `__arm64_sys_getdents64` hooks are kept as belt-and-suspenders.
- Per-symbol probe registration is tolerant: kernels missing one of the syscalls (e.g. some 5.10 builds without `faccessat2`) just log a warning and continue. Look for `pathmask: hooked __arm64_sys_*` lines in `dmesg` to confirm which probes attached.
- Fix silent hook miss on Android GKI 5.15+ kernels caused by ThinLTO inlining `security_inode_permission` and `security_inode_getattr`. Switch to `inode_permission` and `vfs_getattr`. Handle the `inode_permission` argument register that shifts from `x0` to `x1` starting with 5.12 (where `user_namespace` / `mnt_idmap` was prepended) via a compile-time check.
- Add a one-shot `pr_info` line the first time each hook actually fires so users can confirm in `dmesg` that the hook is doing real work.

中文说明：

- 修复 v2.2.5 / v2.2.6 之后 `cat /system_ext/app/SoterService/SoterService.apk` 仍然能读到内容的问题。原因是 `inode_permission` 虽然是 `EXPORT_SYMBOL`，但 `link_path_walk` 里那个调用也被 ThinLTO 内联了 —— 所以 kretprobe 对某些进入路径有效（`fired (first time)` 日志会出现），但走正常 path walk 的 openat 完全绕过它。结果：被隐藏目录的元数据看不见，但**目录里面的子文件**却能直接 open 读取。
- 新增 hook `__arm64_sys_openat` 和 `__arm64_sys_openat2`。这两个跟 v2.2.5 那五个 syscall hook 同一原理：它们必须以函数指针放进 `sys_call_table[]`，链接器无法内联，所以 hook 必中。命中判断复用现有的 `regs[1]` 用户态文件名 + 前缀匹配。
- 解决 openat 加 hook 的 fd 泄漏老问题（这也是 v2.2.5 当初没敢挂它的原因）：exit 处理器现在会先调用 kprobe 解析出来的 `close_fd()` 释放 syscall 体里已经分配好的 fd，再把返回值改写成 `-ENOENT`。如果当前内核解析不到 `close_fd`，openat hook 会自动禁用（entry 不会标记 matched，让 open 正常返回），其他 syscall hook 仍然全部生效，**不会有 fd 泄漏**。
- 修复 WebUI 在 global 模式下健康检查误报"有路径当前不存在"：WebUI 跑的 `[ -e ]` 现在也被自身 hook 拦下来，刚好是模块工作的副作用。global+模块已加载时 WebUI 改读 `/sys/module/pathmask/parameters/resolved_count`（这个值在 insmod 阶段写入，hook 都还没生效，是内核真实视角），不再做用户态 stat 探测。诊断报告里的 "target existence" 段同样处理。`deny` 模式下 WebUI 是 root shell（uid=0）不在黑名单里，原有 `[ -e ]` 仍然准确，保持不变。
- 内核新增只读 sysfs 参数 `/sys/module/pathmask/parameters/resolved_count`，输出模块加载时成功解析的目标路径数量。
- v2.2.5：新增 `__arm64_sys_newfstatat` / `__arm64_sys_statx` / `__arm64_sys_faccessat` / `__arm64_sys_faccessat2` / `__arm64_sys_readlinkat` 五个 syscall 入口 hook，绕开 ThinLTO 把 VFS helper 内联进 `vfs_statx` 等调用者导致 `vfs_getattr` / `inode_permission` hook 不触发的问题。原有 `inode_permission` / `vfs_getattr` / `__arm64_sys_getdents64` hook 保留作为兜底。
- 每个 syscall 的 kretprobe 注册可容错：某些内核（比如部分 5.10 没有 `faccessat2`、或者更老的内核没有 `openat2`）某个符号注册失败时只打 warning 并继续注册剩下的 hook。
- v2.2.4：修复 GKI 5.15+ 上 `security_inode_permission` / `security_inode_getattr` 被 ThinLTO 内联导致 hook 看似已挂、实际从未触发的问题。改为 hook `inode_permission` 和 `vfs_getattr`，并按内核版本编译期切换 inode 参数寄存器（`x0` → `x1`）。
- 新增"首次触发日志"：每个 hook 第一次真正被调用时打印一行 `pr_info`，方便从 dmesg 确认 hook 真的在工作。

# PathMask 2.2.3

- Fix silent reboot on Android GKI kernels with `CONFIG_CFI_CLANG=y` (e.g. OnePlus 11 android13-5.15) caused by Clang CFI checking the indirect call to kprobe-resolved `kern_path` / `path_put`. The two indirect call sites are now wrapped in `__nocfi` helpers; the rest of the module retains full CFI coverage. Behaviour on OEM kernels that prune `EXPORT_SYMBOL(kern_path)` / `path_put` is unchanged.
- Fix install-time config seed: previously, even if you edited `target_path.conf` / `deny_packages.conf` etc. inside the zip before flashing, the boot script would unconditionally re-add the demo defaults (`/dev/cpuset/scene-daemon`, `com.chunqiunativecheck`, ...) into `/data/adb/pathmask/*.conf`. Now the zip's own `*.conf` files are the single source of truth on first install; subsequent boots leave persisted user config alone.
- Drop the unused `.defaults_v1_seeded` marker and inlined hardcoded defaults from `service.sh`. The WebUI "恢复默认" button still writes its own demo defaults explicitly.
- Unify `target_wait_seconds.conf` + `package_wait_seconds.conf` into a single `wait_seconds.conf`. Existing installs are auto-migrated by taking the larger of the two old values; the legacy files are then deleted. The packaging scripts and the `PATHMASK_*_WAIT_SECONDS` envvars collapse into `WaitSeconds` / `PATHMASK_WAIT_SECONDS`.
- Fix worst-case boot delay: the path wait and the package-resolution wait used to consume `wait_seconds` each, so the boot service could spend up to 2x the configured value before deciding to skip loading. Both phases now share a single deadline computed once, capping the total budget at exactly `wait_seconds`. Default lowered from 90 s to 60 s.
- Surface boot-load progress in the WebUI: `service.sh` now writes its phase to `/data/adb/pathmask/boot_state` (`init`, `waiting-targets`, `waiting-packages`, `loaded`, `skipped-*`, `failed-*`, `paused`, ...) and the WebUI health view shows live "还需等待最多 X 秒" status while the script is still waiting, so the default no longer looks like a hang.
- `uninstall.sh` now also removes `/data/adb/pathmask` so a clean reinstall starts from the zip-bundled defaults instead of inheriting stale UID caches, fail counters, or `boot_state`. `rmmod` keeps a best-effort try too.

中文说明：

- 修复在 `CONFIG_CFI_CLANG=y` 的 Android GKI 内核（例如一加 11 android13-5.15）上，因 Clang CFI 校验 kprobe 解析后的 `kern_path` / `path_put` 间接调用而导致的静默重启。两处间接调用改为 `__nocfi` 包装函数，模块其余部分仍保留完整的 CFI 覆盖；对裁剪了 `EXPORT_SYMBOL(kern_path)` / `path_put` 的 OEM 内核行为不变。
- 修复刷入配置被覆盖的问题：之前即便在刷机前手动改了 zip 内的 `target_path.conf` / `deny_packages.conf` 等，开机脚本仍会无条件把 `/dev/cpuset/scene-daemon`、`com.chunqiunativecheck` 等示例项追加进 `/data/adb/pathmask/*.conf`。现在以 zip 内的 `*.conf` 为唯一初始来源，之后开机不再回写默认。
- 移除 `service.sh` 中未使用的 `.defaults_v1_seeded` 标记和写死的默认项。WebUI 的"恢复默认"按钮仍能按需写入示例配置。
- 合并 `target_wait_seconds.conf` 和 `package_wait_seconds.conf` 为单一的 `wait_seconds.conf`。旧版本的两个文件会被自动迁移（取较大者），合并后旧文件会被删除。打包脚本与 `PATHMASK_*_WAIT_SECONDS` 环境变量也统一为 `WaitSeconds` / `PATHMASK_WAIT_SECONDS`。
- 修复总开机延迟问题：之前路径等待和包名解析等待各自独占 `wait_seconds` 秒，最坏情况下要花 2 倍时间才会决定跳过加载。现在两个阶段共用同一个截止时间，总等待预算就等于 `wait_seconds`。默认值从 90 秒降为 60 秒。
- WebUI 现在能显示开机加载进度：`service.sh` 会把当前阶段写入 `/data/adb/pathmask/boot_state`（`init`、`waiting-targets`、`waiting-packages`、`loaded`、`skipped-*`、`failed-*`、`paused` 等），WebUI 健康检查会实时显示"还需等待最多 X 秒"，避免默认等待被误认为没有生效。
- 卸载脚本现在会一并删除 `/data/adb/pathmask`，下次重装会从 zip 内的默认配置开始，而不是继承旧的 UID 缓存、失败计数、`boot_state` 等。`rmmod pathmask` 仍是 best-effort 尝试。

# PathMask 2.2.0

- Module author is now `Andrea-lyz`.
- WebUI adds config validation for paths, deny scope, direct UIDs, target existence, and package UID hints.
- WebUI adds a temporary pause button. It unloads `pathmask` without disabling the module; reboot or save-and-hot-reload restores hiding.
- Boot service now records consecutive module load failures and skips automatic loading after repeated `insmod` failures.
- Save-and-hot-reload clears the load-failure guard and retries immediately.
- Release packages keep KMI-specific update metadata to avoid cross-installing the wrong kernel package.

中文说明：

- 模块作者已改为 `Andrea-lyz`。
- WebUI 新增配置校验：检查隐藏路径、黑名单模式、直接 UID、路径是否存在、包名是否可能解析失败。
- WebUI 新增“暂停隐藏”：临时卸载 `pathmask`，不会禁用模块；重启或“保存并热重载”即可恢复。
- 开机脚本新增连续加载失败保护，多次 `insmod` 失败后会自动跳过后续自动加载。
- “保存并热重载”会清除失败保护并立即重试。
- Release 包继续使用按 KMI 区分的更新信息，避免刷错内核版本包。
