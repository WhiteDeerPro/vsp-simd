# I-side / D-side 内存模型边界

> 状态：逻辑端口和仿真合同已形成；product D-side 已接入 LSU、地址路由、共享 MMU、
> D-cache、local SRAM、uncached/device endpoint 和 physical fabric，并以 ordered lower
> port 结束。I-cache、外部 SoC target/bus、DMA 与一致性策略仍是后续产品集成项。本页
> 描述分层，不固定 cache 容量、行宽或替换算法。

![I-side / D-side 预期分层](memory-hierarchy.svg)

Graphviz 源文件为 [`memory-hierarchy.dot`](memory-hierarchy.dot)。

## 1. 为什么先分逻辑端口

程序流和数据流有不同事务语义，应在进入存储层时保持两个 client：

| 边界 | I-side program fetch | D-side vector memory |
|---|---|---|
| 操作 | 只读连续 uword bundle | LOAD/STORE beat |
| 当前宽度 | 最多 4×32-bit word | 默认 4 byte |
| 地址 | byte PC | effective data address |
| 写掩码 | 无 | byte strobe |
| 返回 | packed words + fault | read data/write ack + fault cause |
| 当前请求端能力 | program source 单 outstanding | memory engine 单 dmem beat outstanding |

这两个宽度都不是 cache line 规格。`4 words = 16 bytes` 只表示一次 fetch response
上限；`4-byte dmem beat` 只表示当前 SIMD4 VRF row 的传输颗粒。未来 cache line 可以
更宽，并由各自 provider 处理跨 line 的拆分、fill 和响应重组。

I/D 分开也不要求两套物理存储。两个 miss/writeback client 可以在下游通过有界公平
arbiter 共用一个 SRAM 或 SoC memory port；仲裁不得把 I/D 的 ready/valid、fault 和
outstanding 生命期合并为一套含糊状态。

## 2. 当前可执行模型

当前有两个彼此独立的仿真 endpoint：

- `vsp_ordered_ifetch_model`：read-only word backing、byte-PC、1–4 word response、
  address-space/fault 检查、可配置 fixed latency 与 ordered outstanding FIFO；
- `vsp_ordered_dmem_model`：byte backing、LOAD/STORE、write strobe、每个 STORE 一条
  acknowledgement、fault 与 ordered outstanding FIFO。

它们是协议 oracle，不是 cache。reset 丢弃在途响应但保留 backing 内容；初始化和
观察 sideband 不冒充 VSP transaction。

`vsp_dmem_subsystem_wrapper` 把相同 D-side logical beat 接到外部 LSU、
address-space/region router 和真实 MMU/TLB/PTW，并以四类 physical endpoint seam 结束。
`vsp_dmem_cached_fabric_wrapper` 再闭合 D-cache、local SRAM、uncached/device adapter 和
physical fabric；`vsp_uword_cached_program_wrapper` 直接连接 executable program 的
`dmem_*`。这些组合不替代上述 protocol oracle；当前证据及依赖基线见
[memory subsystem integration](../integration/memory-subsystem.md)。

现有 `vsp_uword_program_source` 仍直接连接 behavioral control store，且把 fetch fault
折叠为一个 bit。新 I-side 模型额外保留 `addr_space`、`addr_context` 和详细 fault cause，
因此接入程序闭环前还需要一个很薄的 launch-context/fault adapter，或等价地扩展
program-source 合同。该差异是显式待办，不应靠常量绑死后宣称 MMU 已兼容。

## 3. 地址空间和 MMU 扩展点

I-side 与 D-side request 都应最终携带：

```text
effective address + address-space kind + opaque address context
```

- `LOCAL`：路由到 VSP 本地存储，不要求页表翻译；
- `PHYSICAL`：已经是物理地址，但仍需保护和 endpoint 路由；
- `TRANSLATED`：每个实际 memory beat 经过 translation/protection；没有 translator 时
  返回 translation fault，而不是把地址当作 LOCAL 使用。

跨页 vector transfer 必须逐 beat 检查，不能只翻译 parent base 后假设后续虚拟页物理
连续。I-cache 若位于翻译之前，其 tag 必须包含足以区分 address context 的信息；若位于
翻译之后，则由前级 translation/TLB 提供物理地址。当前不选择其中一种物理实现。

execution context 负责 action 所有权和 completion 回送；address context 负责翻译/
保护域。两者不能互相替代。

## 4. I-cache 候选职责与当前 D-cache 边界

### I-cache role

- 接收 word-aligned byte PC 与 word count；
- 对跨 line bundle 做拆分和有序重组；
- response 被背压时保持全部 words/count/fault 稳定；
- miss request 的 PC、count、context 和 tag 必须在握手时锁存；
- program backing 被 host/DMA 修改后，通过 launch 边界 invalidate，或未来显式
  `FENCE.I`/invalidate 操作建立可见性。

### D-cache role

- 保持 LOAD data 与 STORE byte strobe/ack 语义；
- fault 与 partial-commit 顺序继续由 vector memory transaction engine 可观察；
- DMA/host 与 VSP 共享数据时需要明确 clean/invalidate/ownership 协议；当前不声明
  hardware coherence；
- 当前 `INDEX_U8` gather/scatter 已在 vector memory engine 内逐 lane 形成普通 D-side
  request；cache 不猜测 vector register 语义。未来 coalescer 或 gather/scatter 加速器仍应
  保持在 D-side request 层，不修改 I-side 合同。

当前 product wrapper 已按这些职责接入 writeable `param_cache`，但 geometry 仍是参数，
也尚未定义 DMA/host ownership。cache lower transaction 与 PTW、uncached/device traffic
在 physical fabric 合流；fabric 以下的目标译码和 SoC transport 不在 wrapper 内。

另一个 cacheless profile 仍可让 I-side 接 program SRAM、D-side 接 local SRAM，再由 DMA
在 kernel 启动/结束边界搬运；逻辑拆分并不要求所有 profile 都实例化 cache。

## 5. Sequencer 地址状态

`vsp_sequencer_state_engine` 已提供并接入第一版 address-state path：

- 默认每 execution context 具有 32 个 32-bit state register；寄存器 0 恒为零；
- `SMOVI`、`SADD`、`SADDI`，按 32-bit modulo arithmetic 工作；
- command/completion 均可背压，completion stalled 时不会重复写状态；
- 组合 base query 供 MEMORY decoder 在 **action admission** 时快照地址。

该模块不持有 PC、不发 memory request，也没有 flags、branch、loop、scalar load/store、
CSR 或中断入口。它只是 sequencer 生成地址、stride 和 count 的状态，不是一颗独立 CPU。
strict program wrapper 已把 CONTROL-state decoder、两词 MEMORY decoder、state query 与
现有 vector memory engine 接通；端到端回归覆盖 state 地址构造、VLOAD、EXEC、VSTORE
和 END。该接法仍是 slot-0/global-single-active 基线，不代表并发 action window 已绑定。

## 6. 后续实现顺序

1. 给 program launch 增加 I-side address-space/context，接通 ordered fetch provider、
   I-cache adapter 和现有 fabric I-cache master；
2. 给 generic ordered lower port 接入真实 SoC target decode/bus，并覆盖 RAM/MMIO fault、
   response 背压、reset epoch 与 quiescence；
3. 实现 LSU barrier 到 I/D cache、TLB 与 fabric action 的 maintenance policy bridge；
4. 把 state/MEMORY 的 resolved base 与 RAW/WAW 依赖纳入 multi-record action window；
5. 有 workload 命中率与带宽数据后，再选择 I-cache/D-cache line、容量和 replacement；
6. 引入 DMA 前定义数据 ownership 与 cache maintenance；引入 self-modifying program
   前定义 instruction visibility。

这里没有把 cache 设为必须。独立逻辑端口、地址元数据和事务合同才是本阶段需要保留的
设计空间。
