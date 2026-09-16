# kswapd 页缓存磨床 —— 最小复现

（英文完整版见 [README.md](README.md)，机制源码引用见 [docs/MECHANISM.md](docs/MECHANISM.md)）

## 复现的是什么

**碎片化（空闲很多、但没有任何 ≥1MB 的连续空闲块）的 NUMA 节点上，一个进程
顺序读大文件时：预读的大 folio 申请失败 → 分配慢路径唤醒 kswapd → kswapd
按 LRU 回收文件页（就是这次读正在填的缓存）→ 只要顺序读还在继续，kswapd
就被反复叫醒、持续把缓存磨掉。** 同机上一个依赖缓存的负载随即掉到磁盘速度，
而 `free` 还显示着十几 GB 空闲。

这是 LKML 那个帖子「碎片化下 kswapd 即便空闲充足也大量回收 file folio」的
本体。**不需要 THP 负载、不需要规整压力、不需要内存紧张**——泵就是受害者
自己的预读。

（此前的弯路：以为高阶压力必须由 THP 分配者提供。实测不成立——
`defrag=madvise` 的 THP 缺页是申请者自己直接回收、根本不叫 kswapd
（`GFP_TRANSHUGE_LIGHT` 不含 `__GFP_KSWAPD_RECLAIM`）；`defer` 路径虽然叫醒
kswapd，但每次唤醒只咬一口就睡，只有零散爆发。）

## 三个臂（约 12 分钟）

| 臂 | 做什么 | 看什么 |
|---|---|---|
| **A** | 顺序预热 12GB 文件集，然后随机 4KB 测 60s | 对照：无碎片，kswapd 全程静默，缓存完整，百万级 ops/s |
| **C** | 丢缓存 → 造碎片 arena → 同样顺序预热 → 同样测量 | 处理组：预热期间 kswapd 持续回收 |
| **C2** | 不重新预热，再测一次 | 缓存不会自愈 |

A 与 C 的唯一差别：预热时内存碎不碎。

## 跑法

```sh
make
sudo install -m 0440 sudoers.example /etc/sudoers.d/kswapd-treadmill   # 按需改路径/用户名
tmux new-session -d -s treadmill "$PWD/scripts/run.sh"                # 必须脱离终端跑
tail -f results/*/run.log
```

可用环境变量：`TOTAL_GB FILE_GB SECS THREADS NODE DATA_DIR MEAS_CPUS
FRAG_CTL SUDO REPEAT_MEASURE`（见英文 README 的表）。

**要求**：内存 ≥ 文件集 × 2.2；`read_ahead_kb > 0`；慢盘（效果与盘的延迟成
正比，NVMe 上很小且很快自愈）；`frag_pin` 需要 root 或 `CAP_IPC_LOCK`。

## 结果怎么读

脚本结束自动跑 `scripts/analyze.py`，出两张表 + 判定行。关键列：

- `freeMB` / `o5..o10` —— 是内存紧张，还是只是碎？
- `pgscanK/s`、`stealF/s` —— kswapd 每秒扫多少页 / 偷多少文件页（磨床本体）
- `reflt/s` —— 受害者重新缺页（被偷走的页又被访问）
- `kswapdCPU%` —— kswapd 在窗口里烧的 CPU
- `filepgMB` —— **页缓存绝对大小（首行>末行）**，判断「缓存此刻到底有没有被偷」的唯一硬证

### 参考运行（94GB 双 NUMA、LVM 两块机械盘 ≈ 380 随机 4KB IOPS、
`read_ahead_kb=512`、`max_sectors_kb=1024` ⇒ 预读要 order-8 = 1MB 的块）

```
arm          ops/s    hit%   ...  freeMB  pgscanK/s  stealF/s  kswapdCPU%    filepgMB
A          2853463  100.00   ...   50462          0         0        0.0   13720>13721
C              459   16.74   ...   15220       4757      4757        0.1    3702>3793

phase       secs  freeMB       pgscanK/s  stealF/s  kswapdCPU%    filepgMB
A_warm        --   50456               0         0        0.0   13720>13720
C_warm        49   15350           46390     46471        1.6    1451>3704
```

最后一行是关键：**预热读了 12GB，结束时缓存里只剩 3.7GB，而空闲仍显示
15.3GB 未动**——kswapd 用 49 秒、每秒 4.6 万页的速度把它磨掉了。

三个必看的签名：

1. A 臂 kswapd 完全静默（`pgscanK/s = 0`），命中 100%，百万 ops/s。
2. C 臂预热期 `pgscanK/s` 数万/秒、`stealF/s` 同量级、而 `freeMB` 还有上万 MB。
3. C 臂测量窗内 **`filepgMB` 基本不动**——缓存不是「测量时被偷的」，是
   **测量开始前就没了**。伤害发生在填充期，这是本复现最反直觉的一点。

`oom_kill` 与 `pswpout` 全程不动：这里没有任何内存压力。

## 机制（源码行号见 docs/MECHANISM.md）

1. 页缓存的预读分配带 `__GFP_KSWAPD_RECLAIM`（`fs/inode.c:278`
   的 `GFP_HIGHUSER_MOVABLE`；`gfp_types.h:259`）。
2. 顺序读会把预读阶数往上顶（`readahead.c:712` `ra->order += 2`），
   本机到 order-8（1MB）——这就是碎片必须击穿的那个阶。
3. 申请失败 → `__alloc_pages_slowpath` → `if (alloc_flags & ALLOC_KSWAPD)
   wake_all_kswapds()`（`page_alloc.c:4814`）**先叫醒 kswapd，再降级重试**。
   失败的那次申请已经完成了它唯一的副作用：叫醒。
4. kswapd 每次醒来只回收 `compact_gap(order)` = **32 页**
   （`vmscan.c:7017`、`compaction.h:67`），然后 `sc->order` 降 0，
   按 order-0 水位判定（空闲十几 GB，当然满足）→ 继续睡。
   参考运行 4.6 万页/秒 ÷ 32 页 ≈ **每秒 1400 次唤醒**——伤害是频率，不是单次量。
5. 随机 4KB 读不是顺序流，`ra->order` 回到 0，order-0 分配必然成功 →
   不叫 kswapd → 缓存保持填充期结束时的样子。

## 对三派补丁的含义

| 改法 | 本场景下的效果 |
|---|---|
| 限 `sc->nr_to_reclaim` | 几乎无用：每次唤醒本来就只咬 32 页，放血靠的是唤醒频率 |
| 改叫醒 kcompactd | 治本：order-8 块存在的话，申请根本不会失败，谁都不用醒 |
| 预读分配剥掉 `__GFP_KSWAPD_RECLAIM` | 直接关泵。预读失败反正降级 order-0，而在空闲充足时叫 kswapd 来偷「预读正想填的缓存」很难自圆其说 |

## 这个复现的边界

- arena 是最坏情况（每个 2MB 帧钉 1.5MB、只留 512KB），真实机器没这么整齐；
  但要求仅仅是「没有 order-8 空闲块」，长 uptime + 不可搬移页（mlock、大页、
  slab、驱动缓冲）迟早会到那一步。
- 测量窗头 10-20 秒的命中率虚高伪影未完全解释（不是缓存被偷：同窗口
  `filepgMB` 是平的），不影响结论。
- 「关掉预读预热」这个能彻底隔离泵的实验在慢盘上做不了（12GB 按单页读、
  380 IOPS 要两小时），用 A/C 对照代替。
