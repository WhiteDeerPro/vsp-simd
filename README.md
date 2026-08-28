# Programmable Vision SIMD

这是一个面向图像与视频算法的可编程 SIMD 计算核项目。

项目已经形成一个可运行的 GROUP_EXEC cluster reference shell，但仍不是完整 VSP：

```text
VSP / SoC 子系统（未来）
└── 计算集群（开发中）
    ├── late-decode holding shell（参考 RTL 已实现，真实编码 hook 待填）
    ├── GROUP_EXEC exec shell（参考 RTL 已实现）
    │   ├── queue / RR live-head / atomic dispatch / per-group ingress
    │   ├── 4 × SIMD4 transaction wrapper
    │   └── completion tracker / result collector / reject sink
    ├── predecoder / compact decoder / class router（尚无 RTL）
    ├── VRF span engine（独立参考 RTL 已实现）
    ├── row-level exchange engine（独立 RTL 已实现，已接入共享 VRF 边界）
    └── owner/barrier/跨 class 顺序与 sequencer controller（待实现）
```

“搜索、凝视、分层、附着、抽象、联合、追踪”属于软件算法。硬件不预设这些语义，只提供能够忠实、高效编纂这些算法的通用原语。

## 当前内容

- 当前 controller profile 以 `4×8-bit` SIMD4 作为调度颗粒，叶模块保留参数用于
  健壮性验证；
- BYTE/HALF/WORD 动态边界的加减、移位、整体最值和有/无符号比较；
- 每 byte lane 的饱和、乘法与乘加等窄运算；
- 条件选择、移位 widening、公共移位对齐的三输入 `ARF+VRF-A±VRF-B`、宽值直接截位、舍入缩放和饱和 narrow；
- 由外部 sequencer 提供的广播立即数，可替代 VRF-B 驱动普通 ALU、MAC 和宽窄转换；
- 向量掩码执行；叶执行接口返回 merge 值，状态化 datapath 通过 masked RF write
  保留未激活 lane；
- 窄结果与宽结果分离，使累加精度独立于 8-bit 窄结果；
- 参数化组合 Bênes 网络，用于研究任意跨 lane 置换；
- SIMD group 内的一份直接 crossbar，支持重复索引的 gather、lane broadcast 与 permutation；
- 可接相邻 SIMD group 边界的双向 slide，用于组成更宽的逻辑执行组；
- mask-aware 的组合 reduction tree，可求和、最小值、最大值和获胜 lane；
- 由 `ABSDIFF_U + REDUCE_SUM_U` 组合出的 SAD 验证内核；
- 由外部微操作驱动的单通道 3×3 Gaussian，覆盖 slide、连续 ARF MAC、tail mask 与最终舍入窄化；
- 外部 sequencer 发射的 VRF-N/ARF/MRF 状态化数据通路壳；
- operation/mode/writeback/route/reduction 的共享合法性检查；
- 默认 `4 group / 2 queue / 2 slot` 的 GROUP_EXEC reference frontend：单 admission、
  有序 FIFO、round-robin live-head、opaque locked shadow、显式 reject credit
  和 terminal pop；
- 多 context、多 issue slot 的 owner 检查、原子 group-mask 分发和错误 reject；
- 单 group 的 decoded EXEC、RF state-write 与 VRF state-read ready/valid，
  tagged child completion/data response、可背压 result capture 和状态传输仲裁；
- 默认 `4 group / 2 alloc slot / 2 context / 4 entry` 的 GROUP_EXEC command
  completion tracker：按 `context+tag` 聚合可乱序/同拍 child completion，
  独立跟踪 expected result mask，并以可背压 RR 输出唯一 command completion；
- 默认 `4 group / 2 context / 2 slot` 的 `simd_cluster_exec_shell`：完整 decoded
  GROUP_EXEC admission、slot-specific resource grant、原子 tracker commit、每 group
  单项 ingress、四个 transaction wrapper、state-read/write child lane、reject completion
  与 RR result collector；
- `simd_issue_decode_shell`：每 issue slot 一项的 late-decode holding 边界，保存
  raw/resolved/cached provenance 与 class/response/resource/canonical 输出；当前使用
  可替换 hook，不定义最终 32-bit/16-bit 编码；
- 独立 `vsp_vrf_span_engine`：VRF-only，一个 active parent、一个
  outstanding memory beat，按 group 升序在连续 4-byte beat 上执行
  LOAD/STORE，并报告 stop-on-first 的 partial masks/bytes；
- `vsp_cluster_actor_shell`：MEMORY span actor 与 row-exchange engine 作为
  `vsp_cluster_vrf_service` 的两个 client 同时在线，共用同一组 group VRF
  state-read/write 端点；已验证 EXCHANGE 到真实 group VRF row 的置换、
  inverse-route 恢复、稀疏 source mask 与两 client 并发在飞的返回归属；
- Verilator lint 与自检仿真。

当前 `simd_cluster_exec_shell` 采用 full-decoded reference profile：入口直接提供
canonical GROUP_EXEC 控制，内部 queue、dispatcher、per-group ingress、wrapper、
tracker、reject buffer 和 result collector 已组成可背压事务闭环。可信
state-read/write child lane 使外部 actor 能传输 VRF row；它们不是算术指令。
`simd_issue_decode_shell` 已给出晚译码后的稳定 holding 边界，但 compact uword 的
真实 parser/predecoder、class router 和 encoded 格式尚未实现，也尚未重排到当前
frontend 的 queue-head 路径。因此 reference shell 不能被称为完整 decoder、
controller 或 sequencer。
`vsp_cluster_actor_shell` 让 row-exchange engine 成为共享 VRF service 的第二个
client，与 MEMORY span actor 共用 group VRF 端点。它证明的是接线与并发返回归属，
不表示 route table、EXCHANGE class router、跨 class program order 或共享资源仲裁
已经存在；并发命令不重叠 VRF row 仍由上层保证。exchange engine 要求二次幂
`GROUP_COUNT` 与 4-byte VRF row，因此非二次幂参数稳健性继续由
`vsp_cluster_memory_shell` 承担，两者是并列的 integration profile。

`vsp_vrf_span_engine` 已独立实现 MEMORY parent 行为，但尚未接入
class router、local SRAM 或 DMA，不表示整个存储路径已闭合。
它区分 execution context 与 address context，并携带
`LOCAL/PHYSICAL/TRANSLATED` address-space 类别；这只定义可插入未来
翻译/路由 adapter 的有序 data-memory 逻辑口，当前没有 MMU、TLB、
PTW、cache 或取指逻辑。

术语上，当前内部信号名为 `op_i`/`exec_op_i`；6-bit `simd_op_e`
只是 canonical `GROUP_EXEC` 的 function，不是完整 opcode。项目尚未定义
32/16-bit instruction；queue 的 32/16/16 默认宽度只是 opaque
elaboration profile，不是编码格式。
program-level RF_FILL 的 bulk data 不进入指令字或指令队列，候选边界归入
[数据准备与 DMA](docs/design/data-movement.md)。独立处理器所需的取指、分支和异常
不在当前路线内，物理 RF、流水线和访存组织仍待选择。

## 目录结构

```text
rtl/
├── pkg/            # 公共类型、操作码与参数
├── units/          # lane 内算术、移位、mask 与 reduction 单元
├── permute/        # group 内 crossbar、route 与 compact
├── group/          # 寄存器文件、执行级与 group 数据通路
├── interconnect/   # group 之上的交换网络实验
├── cluster/        # 多 group 所有权、发射与后续集群控制
├── memory/         # 独立 VSP MEMORY/span engine 参考 RTL
└── files.mk        # 各验证目标唯一、有序的 RTL 文件清单
sim/                # Verilator 自检 testbench 与行为参考模型
docs/               # 架构现状、候选设计、Q&A、负载和验证方法
```

这里采用浅层分类：模块边界不因整理目录而改变，后续加入乘法卷积/部分积单元时先归入 `units/`，达到需要独立演进的规模后再细分。

## 构建与验证

```bash
make lint
make test
```

默认的可再生 Verilator 产物集中在 `build/`，`make clean` 可将其全部清除。若工作区上传器不读取 `.gitignore`，建议直接在工作区外构建，并用 quiet 模式避免回传冗长的编译命令：

```bash
make -s BUILD_DIR=/tmp/vsp-build lint
make -s BUILD_DIR=/tmp/vsp-build test
make BUILD_DIR=/tmp/vsp-build clean
```

`BUILD_DIR` 可换成任意专用构建目录；`clean` 带有保护，不会删除 `/`、当前工作区或其父目录。

文档从[文档导航](docs/README.md)开始。当前控制主线：

- [架构范围工作稿](docs/architecture/overview.md)
- [SIMD4 集群控制工作稿](docs/design/cluster-control.md)
- [队列、微指令与译码候选](docs/design/instruction-delivery.md)
- [数据准备与 DMA 边界](docs/design/data-movement.md)
- [架构问题集](docs/explorations/architecture-qa.md)
- [VSP/SIMD 集群实验路线](docs/design/development-roadmap.md)
