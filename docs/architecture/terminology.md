# VSP 术语表

> 本页是项目术语的统一入口。它区分编程语义、当前集成、事务协议和独立实验；
> 这些名称不冻结最终 ISA、模块层级或物理实现。

## 1. 使用原则

- 在语义确实相同的地方采用 RISC-V Vector Extension（RVV）的通用词汇，例如
  vector operation、vector register、element、element width、mask 和 load/store。
- `SIMD group`、`execution cluster` 和 physical lane 描述 VSP 的物理组织；它们不是
  RVV ISA 状态，也不应机械替换成含义更宽泛的 Vector Unit。
- 网络拓扑只出现在实现或实验层。编程语义描述数据关系，不把 crossbar、Omega 或
  Bênes 写成操作语义。
- “参数可配置”不等于“当前已经部署”。必须分别写出当前实例和参数合法上限。
- 独立 RTL 能通过测试不等于它已经进入程序路径；实验模块必须明确标记 experimental。

## 2. 架构与编程语义

| 首选名称 | 当前含义 |
|---|---|
| VSP | 项目和未来子系统的名称；当前不强行展开缩写，也不等同于一颗自行取指的 CPU |
| vector operation | 对向量数据执行的一项操作。最终指令编码未定义时，优先于“vector instruction” |
| vector operand / result | 操作读入或产生的逻辑向量值 |
| vector register file (`VRF`) | 保存窄向量状态的寄存器文件 |
| element | 一项逻辑数据；当前由 1、2 或 4 个相邻 8-bit physical lane 组成 |
| element width | 每项 EXEC action 选择的 BYTE/HALF/WORD 宽度；不是 `vtype` CSR 状态 |
| mask / predicate | 决定哪些数据位置参与操作的条件；当前 MRF 按 physical byte lane 保存一位 |
| vector load / store | 在 dmem boundary 与分布式 VRF row 之间传输数据的 MEMORY action |
| `UNIT_STRIDE` | 线性地址模式；从 `base_eaddr + signed offset` 开始，按被选 group 的编号顺序搬运；uword span code `0` 表示填满全部被选 group，`1..31` 表示显式 byte span |
| `INDEX_U8` | 索引地址模式；每个被选 physical byte lane 从 `vi` VRF row 读取一个 unsigned 8-bit offset，并访问 `base_eaddr + signed offset + vi[lane]` |
| `VGATHER` | assembler 对 `LOAD + INDEX_U8` MEMORY record 的拼写；`vd` 是目标 VRF row，`vi` 是索引 VRF row |
| `VSCATTER` | assembler 对 `STORE + INDEX_U8` MEMORY record 的拼写；`vs` 是源 VRF row，`vi` 是索引 VRF row |
| lane reduction | 将多个活动 physical byte lane 合成为 32-bit scalar result |
| lane compress | 按 MRF 的 base-lane mask 稳定收集 physical byte lane |

`UNIT_STRIDE` 的 code `0` 在 action admission 后解析为
`4 * popcount(group_mask)` byte，因此同一编码可覆盖当前 4-group/16-byte 实例和
16-group/64-byte profile bound。code `1..31` 用于显式 span；大于 31 byte 且带 partial
tail 的传输需要拆分，不能把 code `0` 解释成零长度。

`VGATHER`/`VSCATTER` 仍属于 `MEMORY` dispatch class，不是新的执行 class。它们把
索引访存降为普通、对齐的 dmem LOAD/STORE beat：gather 从响应 beat 选择一个 byte，
scatter 只打开目标 byte strobe。`INDEX_U8` 不携带 `span_bytes`；每个被选 group 的四个
byte lane 都参与。重复 scatter offset 按 group、lane 的升序执行，较晚 lane 的写入最后
可见。

RVV 中的 `vector register group` 是由 LMUL/EMUL 组合的一组架构寄存器。它与本项目的
physical `SIMD group` 没有对应关系，文档不得把二者简称为同一个 “group”。

## 3. 微架构

| 首选名称 | 当前含义 |
|---|---|
| physical lane | 最小 8-bit 数据通路 slice；HALF/WORD 是多个 slice 组成的 element，不是新增 lane |
| SIMD group | 4 个 physical lane、group-local RF state 和执行路径组成的调度颗粒；一个 VRF row fragment 为 4 byte |
| group-local slot | 当前 wrapper 内选择 SIMD group endpoint 的局部序号 `0..GROUP_COUNT-1`；不是 PC、thread、context 或 issue slot |
| SIMD4 static ID | `SIMD4_BASE_ID + group-local slot` 形成的不可变 8-bit 拓扑身份；用于集成和观测，不是调度状态 |
| execution cluster | 多个 SIMD group 的发射、所有权、共享资源与完成集成域；当前产品参考实例为 4 group，即每个分布式 VRF row 共 16 byte |
| 16-group profile bound | 当前 memory engine/wrapper 接受的参数上限为 16 group，即每个分布式 VRF row 64 byte；这是当前 profile 上限，不表示已经部署 16-group 实例 |
| issue slot | 同一拍把一项已选 command 送入执行前端的瞬时发射口；当前产品 wrapper 为 1 个。它不保存 PC，不拥有程序，不是 hardware thread，也不是长期 context |
| execution context | 所有权、队列和完成回送身份；当前集成只有一个 context，并且 context 没有独立 PC |
| Vector ALU / execution path | 执行逐元素算术、逻辑与 lane reduction 的路径 |
| VRF row | 一个 SIMD group 内的 4×8-bit 物理寄存器片段；跨 group 的同一 row 编号构成当前 MEMORY action 的分布式向量 |
| accumulator register file (`ARF`) | VSP 特有的宽累加状态；当前每个 physical lane 保存一个 32-bit accumulator |
| mask register file (`MRF`) | VSP 特有的 base-lane-granular predicate state；不是 RVV 的独立 mask register file |
| vector memory engine | 把一项 `UNIT_STRIDE` 或 `INDEX_U8` parent command 分解成 VRF child transaction 与 dmem beat |
| VRF arbiter | 在 memory client 和 cluster VRF endpoint 之间选择 request，并把 completion/response 返回原 client |
| sequencer | 提供 action、地址状态和顺序控制的上级单元；SIMD group 不自行取指 |
| sequencer state engine | 保存地址等 32-bit state 并执行 `SMOVI/SADD/SADDI`，同时为 branch 提供无副作用双源读取；不持有 PC、不发 dmem request，也不是独立 scalar CPU |

必须区分三种常见的 “slot”：framer record slot 是同一 bundle 中的结构位置，issue slot
是瞬时发射口，group-local slot 是 endpoint 编号。三者都不是线程或独立 PC。

## 4. 控制与事务协议

| 首选名称 | 当前含义 |
|---|---|
| action | sequencer 交付的一项工作；当前集成对一个输入流严格按序接受和退休 |
| dispatch class | **internal action dispatch category**；决定 action 进入 `EXEC`、`MEMORY` 或 `CONTROL` 路径，不属于编程模型 |
| `EXEC` | 进入 SIMD group execution path 的 dispatch class；当前产品入口承载算术、逻辑、窄化与 reduction，不承载寄存器全域 VROUTE |
| `MEMORY` | 进入 vector memory engine 的 dispatch class；同时承载 `UNIT_STRIDE` 与 `INDEX_U8` |
| `CONTROL` | 进入 controller-local/state path 的 dispatch class；当前包含 state action、`J`、六种双寄存器比较 branch 和最终 `END` |
| branch redirect | sequencer-local CONTROL action 对唯一 program PC 的更新；会清除尚未发射的年轻 fetch/framer 状态，不创建新 context 或 PC |
| `END` | 等待 EXEC、MEMORY、VRF arbiter 和完成路径强静止后退休的流结束动作；不清 RF、不转移 owner |
| action completion | action 的统一有序退休记录；保留 class/context/tag/requested-group-mask 与 status |
| `program_done` | 成功 `END` completion 被接收时的单拍脉冲；不等同于 host interrupt |
| sequencer/control word (`uword`) | 候选紧凑内部控制存储格式；不是已冻结的 16/32-bit 外部 ISA instruction |
| control store | 保存内部 uword stream 的逻辑存储；当前 RTL 是 behavioral reference，不表示 I-cache 或物理 SRAM 已实现 |
| program source | 按 byte address 顺序请求 uword bundle 的模块；当前只有一个 `pc_q`、一个 launch range 和一个 fetch outstanding |
| uword byte PC | 当前唯一 control-word stream 的 byte cursor；每个 base/body/extension word 都使 record 地址增加 4 |
| uword bundle | 一次 fetch 返回的至多四个连续 32-bit stream word；不是四条可独立执行的线程指令 |
| uword record | 一个 header 加零至多个 body word 的结构记录 |
| multi-record framer | 跨 bundle 保存 tail，并可同时暴露若干完整 record；当前产品 wrapper 只将 record slot 0 放入 single-action holding |
| action adapter | 将 record 与 launch envelope/context/tag 组合并执行 class semantic decode |
| strict controller | 当前一次只拥有一个 active action 的 `EXEC/MEMORY/CONTROL` controller；保证跨 class 顺序 |
| request / response / completion | decoupled 协议中的请求、带数据返回和事务完成通知 |
| parent command | 一项 MEMORY action 在 vector memory engine 内保存的完整描述符 |
| child transaction / beat | parent 对一个 VRF group endpoint 或 dmem endpoint 发出的原子传输 |
| outstanding transaction | request 已被 endpoint 接受而相应 response 尚未完成的事务 |
| single-outstanding MEMORY | 当前为 `1 active parent + 1 dmem beat outstanding`；dmem 无 transaction ID，下一 beat 必须等待当前 response |
| address context | 交给 translation/protection subsystem 的 opaque domain handle；当前 trusted-uword profile 可直接提供，尚无 privilege 层校验 |
| AGU | 把 base、signed offset、group/lane 和 index byte 变为 effective address；不负责 response correlation 或 retirement |

当前只有一个程序 PC。fetch 一次可带四个 word、framer 可看见多个 record、执行前端可以
参数化多个 issue slot，这些事实都不会自动产生第二个 PC 或第二条线程。当前产品 wrapper
实际使用一个 issue slot，并由 strict controller 保持 global single-active。

## 5. 独立实验模块

下列 RTL/测试保留为 **experimental**，不属于当前 uword 产品路径：

- `vsp_ordered_action_window`：多 entry、多个 candidate view 的依赖/退休实验；view 不是
  issue slot，也不是 PC。
- `vsp_cluster_register_route_engine`、`vsp_route_rendezvous_table`、
  `vsp_route_wave_controller` 与 `vsp_cluster_route_wave_pipeline`：寄存器重排、participant
  配对和 wave fan-out 实验。它们没有连接当前 PC、framer、action adapter 或产品
  execution wrapper；当前 assembler 也不提供 `EXEC_ROUTE`/`VROUTE` 拼写。
- `vsp_ordered_ifetch_model` 与 `vsp_ordered_dmem_model`：可执行协议模型，不是 I-cache、
  D-cache、MMU、SRAM 或 DMA。

实验模块中的 route domain、participant、rendezvous entry、frontier 和 route wave 只在
相应 RTL/测试上下文内使用，不应据此宣称当前程序支持跨 PC 协作或全域寄存器路由。

## 6. RTL 命名

| 名称 | 用法 |
|---|---|
| `simd_*` | lane、SIMD group、execution cluster 等执行侧模块 |
| `vsp_*` | sequencer 可见的 engine、integration wrapper 或 VSP 子系统模块 |
| `*_engine` / `*_unit` | 保存并推进某类操作的功能模块 |
| `*_arbiter` | 竞争请求选择和返回归属保持 |
| `*_stage` | 流水或 elastic holding stage |
| `*_wrapper` | 组合既有模块并暴露参考集成边界；不表示完整 VSP |

新名称不使用 `Actor`、`Service` 或 `Shell`：硬件功能体写 engine/unit，接口使用方写
client，选择逻辑写 arbiter，集成边界写 wrapper，保存级写 stage。

## 7. RVV 对齐边界

对照采用 RISC-V International 的
[Vector Extension 规范](https://docs.riscv.org/reference/isa/v20260120/unpriv/v-st-ext.html)。
对齐发生在 element、register、mask、load/store 和 indexed addressing 等语义层，不声明
binary compatibility：

- VSP 当前没有 RVV-compatible `vl`、`vtype`、`LMUL` programming model；
- RVV mask bit 对应 logical element，VSP MRF 当前对应 physical byte lane；
- RVV widening/narrowing 的 EEW/EMUL 约束与 VSP 的独立 ARF/显式宽窄通路不同；
- VSP 已实现 `UNIT_STRIDE` 和 unsigned-byte `INDEX_U8`，但尚未覆盖 RVV constant-stride、
  ordered/unordered indexed 变体、完整 EEW/EMUL、mask/tail/fault-only-first 等合同；
- `VGATHER`/`VSCATTER` 是当前内部 assembler 拼写，不是 RVV 指令编码兼容声明。
