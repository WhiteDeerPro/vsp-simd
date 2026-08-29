# Internal EXEC uword profile v0

> 状态：内部实验 profile v0。本文给出一套可实现、可验证的
> `32-bit base + optional 32-bit extension` 编码，用于把当前 canonical EXEC
> 控制压缩后交给 sequencer、控制存储和 issue queue。
> 它不定义外部软件 ISA，不声明 RVV 二进制兼容，也不改变
> `simd_op_e` 在 SIMD4 边界上的 canonical function 角色。reference action wrapper
> 已使用本 profile；standalone uword bundle predecoder 已复用其 packet 长度规则，
> admission/queue-head 集成仍在后续。

## 1. 目标与适用范围

当前 `simd_cluster_exec` 接收完全展开的 EXEC 控制。默认 SIMD4 profile 下，若把
expanded immediate、所有 RF 地址、writeback、reduction 和 boundary operand 全部
平铺，payload 远宽于 32 bit。profile v0 使用 format-specific layout，让不同操作族
重叠使用相同 bit 位置，再由 canonical expander 还原现有接口。

本 profile 的编码容量为：

```text
physical narrow width  = 8 bit
accumulator width      = 32 bit
VRF address capacity   = 16 rows
ARF address capacity   = 8 rows
MRF address capacity   = 4 rows
```

当前默认配置恰好是 `16 VRF / 8 ARF / 4 MRF`，当前 reference expander
也以这个容量为目标。较小配置只有在 expander 或其外层增加实际 row 范围
检查后才能复用本 profile。需要更大 RF、不同基础数据宽度或不同
accumulator 宽度时，应定义另一个内部 profile，而不是改变 v0 对同一 bit pattern 的
解释。

profile v0 覆盖当前 EXEC function，包括：

- 普通 VRF 算术、逻辑、比较、选择和 scalar-immediate 形式；
- byte MUL/MAC；
- WIDEN、WADD/WSUB、RSHIFT_RND、NCLIP 和 NSLICE；
- COMPRESS/EXPAND；
- MRF boolean operation；
- SIMD4-local GATHER/BROADCAST/zero-fill SLIDE；
- 显式 RF writeback、narrow export 和 byte reduction 的合法组合。

local route 使用固定 `PASS_A/BYTE` 语义。MEMORY、CONTROL 与跨组 16-lane gather
不属于本 profile。

## 2. 与 action envelope 的边界

一项已组包的 EXEC entry 逻辑上由三部分组成：

```text
encoded EXEC        = base_word + optional extension_word
resolved sideband   = target_group_mask + 其他动态 sequencer 状态
issue envelope      = context + tag
```

以下信息不进入 base 或 extension：

| 信息 | 来源与用途 |
|---|---|
| dispatch class | 对本 profile 隐含为 `EXEC` |
| target group mask | resolved sideband；宽度随 `GROUP_COUNT` 变化 |
| context | 通常由 per-context queue 身份隐含 |
| tag | admission/issue envelope 分配 |
| response kind | 由 export、reduction 和 compact function 派生 |
| exact/shared resource | 由 predecoder/expander 从 function、operand 和 writeback 派生 |
| RF data、boundary data | operand/state-transfer/staging 通道 |

因此 profile v0 可以先用于内部 decoder 与 EXEC queue 实验，而不要求先定义统一的
EXEC/MEMORY/CONTROL action encoding。

## 3. 共同编码

### 3.1 Base format

所有 base word 都使用：

```text
31          28 27                                  0
+--------------+------------------------------------+
| fmt[3:0]     | format-specific payload[27:0]      |
+--------------+------------------------------------+
```

format summary：

| `fmt` | 名称 | extension |
|---:|---|---|
| `0x0` | reserved | 不适用 |
| `0x1` | ALU | `bimm` 选择 |
| `0x2` | CMP | `bimm` 选择 |
| `0x3` | SELECT | `bimm` 选择 |
| `0x4` | MUL | `bimm` 选择 |
| `0x5` | MAC_RR | 禁止 |
| `0x6` | MAC_RI | 必须存在 |
| `0x7` | WIDE_CONVERT | `bimm` 选择 |
| `0x8` | WADD_WSUB | 禁止；align 在 base 内 |
| `0x9` | COMPACT | 禁止 |
| `0xa` | MRF_LOGIC | 禁止 |
| `0xb` | 外层 MEMORY class | 不适用 |
| `0xc` | 外层 CONTROL class | 不适用 |
| `0xd` | ROUTE | 禁止 |
| `0xe..0xf` | reserved | 不适用 |

`alu_op`、`cmp_op`、`wide_op` 等都是 format-local sub-op。它们不是
`simd_op_e` 的截短形式，也不能绕过映射表直接驱动 datapath。

从本 EXEC expander 看，`0xb/0xc` 仍不是合法 EXEC format。独立的 mixed-uword
framing experiment 在更外层暂用它们预判 `MEMORY/CONTROL` class，并用
`header[27:26]` 表示 0..3 个 opaque body word；该规则定义在 `vsp_uword_pkg`，不属于
本文的 MEMORY/CONTROL semantic encoding。若以后的 EXEC profile 要复用这两个
值，必须同时版本化或替换外层 framing，不能静默重叠。

### 3.2 Execution mask selector

`mask_sel[2:0]` 合并 `mask_enable` 与 `exec_mask_addr`：

| `mask_sel` | canonical expansion |
|---:|---|
| `0` | `mask_enable=0`，所有 physical lane 激活 |
| `1..4` | `mask_enable=1`，`exec_mask_addr=mask_sel-1` |
| `5..7` | illegal |

MRF_LOGIC 不含 `mask_sel`。它把两个 MRF 端口当作数据源，canonical expander 固定
输出 `mask_enable=0`。

### 3.3 Reduction selector

`red[2:0]` 合并 `reduce_enable` 与 `reduce_op`：

| `red` | canonical expansion |
|---:|---|
| `0` | `reduce_enable=0` |
| `1` | `REDUCE_OP_SUM_U` |
| `2` | `REDUCE_OP_SUM_S` |
| `3` | `REDUCE_OP_MIN_U` |
| `4` | `REDUCE_OP_MIN_S` |
| `5` | `REDUCE_OP_MAX_U` |
| `6` | `REDUCE_OP_MAX_S` |
| `7` | illegal |

`red!=0` 时 expander 置 `reduce_enable=1`。最终仍必须通过
`simd_op_can_reduce(op, elem_mode)`；当前 reduction 只接受 BYTE mode 的窄结果。

### 3.4 Optional extension

带 `bimm` 的 format 使用以下规则：

- `bimm=0`：不消费 extension，canonical `use_imm=0`，`vb` 是 VRF-B 地址；
- `bimm=1`：必须紧跟一个 32-bit extension，base 中 `vb` 必须为零，canonical
  `use_imm=1` 且 `imm=extension_word`；
- MAC_RR 等价于固定 `bimm=0`；MAC_RI 等价于固定 `bimm=1`；
- 缺少所需 extension，或为禁止 extension 的 format 附带 `ext_valid`，均为
  `EXTENSION`；
- base 与 extension 必须在 admission 时原子组包，不能先把 base 放入 queue 再等待
  第二个 word。

为了让一种立即数只有一种 v0 表示，未被当前操作消费的高位必须为零：

| 使用者 | extension 中可非零的位 |
|---|---|
| ALU/CMP/SELECT，BYTE | `[7:0]` |
| ALU/CMP/SELECT，HALF | `[15:0]` |
| ALU/CMP/SELECT，WORD | `[31:0]` |
| MUL/MAC | `[7:0]` |
| WIDE_CONVERT shift | `[4:0]` |

有符号 BYTE/HALF 常数仍用相应低位的二补码。例如 signed BYTE `-1` 写成
`0x000000ff`，由 lane operation 将低 8 bit 解释为有符号值。

窄 SHL/SHR 仍接收所选 element width 的完整 scalar immediate，再由现有执行语义
只读取其低 `log2(element width)` 位。这是明确的 masked-shift 语义；例如 BYTE
immediate `8` 与 `0` 产生相同 shift amount，但 canonical immediate 本身不同。

控制存储可以把 extension 放在 base 后一个 word；queue 实现则可以保存
`{base, ext_valid, ext}`、保存 extension reference，或在更浅的 holding 中保存展开值。
这些是存储实现选择，不改变本文的编码语义。

## 4. Format layouts

### 4.1 `fmt=0x1`：ALU

```text
31:28  fmt = 0x1
27:23  alu_op
22:21  elem_mode
20:17  va
16:13  vb
12:9   vd
8:6    mask_sel
5      bimm
4      write_vrf
3      export_narrow
2:0    red
```

`alu_op` 到 canonical `simd_op_e` 的映射：

| `alu_op` | canonical function | `alu_op` | canonical function |
|---:|---|---:|---|
| `0x00` | `SIMD_OP_ADD` | `0x0b` | `SIMD_OP_AVG_U` |
| `0x01` | `SIMD_OP_SUB` | `0x0c` | `SIMD_OP_AVG_S` |
| `0x02` | `SIMD_OP_ADD_SAT_U` | `0x0d` | `SIMD_OP_AND` |
| `0x03` | `SIMD_OP_SUB_SAT_U` | `0x0e` | `SIMD_OP_OR` |
| `0x04` | `SIMD_OP_ADD_SAT_S` | `0x0f` | `SIMD_OP_XOR` |
| `0x05` | `SIMD_OP_SUB_SAT_S` | `0x10` | `SIMD_OP_SHL` |
| `0x06` | `SIMD_OP_MIN_U` | `0x11` | `SIMD_OP_SHR_U` |
| `0x07` | `SIMD_OP_MAX_U` | `0x12` | `SIMD_OP_SHR_S` |
| `0x08` | `SIMD_OP_MIN_S` | `0x13` | `SIMD_OP_ABS_SAT_S` |
| `0x09` | `SIMD_OP_MAX_S` | `0x14` | `SIMD_OP_PASS_A` |
| `0x0a` | `SIMD_OP_ABSDIFF_U` | `0x15..0x1f` | reserved |

`ABS_SAT_S` 和 `PASS_A` 不消费 B；它们要求 `bimm=0` 且 `vb=0`。其他 function
按 `bimm` 选择 VRF-B 或广播 scalar immediate。`write_vrf`、`export_narrow` 和
`red` 相互独立，最终 capability 由共享 legality helper 复核。

### 4.2 `fmt=0x2`：CMP

```text
31:28  fmt = 0x2
27:26  cmp_op
25:24  elem_mode
23:20  va
19:16  vb
15:12  vd
11:10  md
9:7    mask_sel
6      bimm
5      write_vrf
4      write_mrf
3      export_narrow
2:0    reserved = 0
```

| `cmp_op` | canonical function |
|---:|---|
| `0` | `SIMD_OP_CMPEQ` |
| `1` | `SIMD_OP_CMPGT_U` |
| `2` | `SIMD_OP_CMPGT_S` |
| `3` | reserved |

CMP 可以同时把全一/全零窄结果写入 VRF，并把 predicate 写入 MRF；它也可以只导出
窄结果。CMP 不提供 reduction 字段。

### 4.3 `fmt=0x3`：SELECT

```text
31:28  fmt = 0x3
27:26  elem_mode
25:22  va
21:18  vb
17:14  vd
13:11  mask_sel
10:9   select_mrf
8      bimm
7      write_vrf
6      export_narrow
5:3    red
2:0    reserved = 0
```

canonical function 固定为 `SIMD_OP_SELECT`。`mask_sel` 决定是否提交某个 logical
element，`select_mrf` 独立决定该 element 选择 A 还是 B。`bimm=1` 时 B 来自广播
scalar immediate；BYTE mode 下可以对 SELECT 结果附加 reduction。

### 4.4 `fmt=0x4`：MUL

```text
31:28  fmt = 0x4
27     signed
26:23  va
22:19  vb
18:15  vd
14:12  ad
11:9   mask_sel
8      bimm
7      write_vrf
6      write_arf
5      export_narrow
4:2    red
1:0    reserved = 0
```

`signed=0/1` 分别展开成 `SIMD_OP_MUL_U/S`，element mode 固定为 BYTE。VRF 接收
乘积低 8 bit，ARF 接收完整乘积；两者可以同时写。export 和 reduction 观察的仍是
窄乘积结果。

### 4.5 `fmt=0x5/0x6`：MAC_RR / MAC_RI

```text
31:28  fmt = 0x5 (MAC_RR) 或 0x6 (MAC_RI)
27     signed
26:23  va
22:19  vb
18:16  as
15:13  ad
12:9   vd
8:6    mask_sel
5      write_vrf
4      write_arf
3      export_narrow
2:0    red
```

`signed=0/1` 分别展开成 `SIMD_OP_MAC_U/S`，element mode 固定为 BYTE。

- MAC_RR：`use_imm=0`，`vb` 是 VRF-B 地址，不允许 extension；
- MAC_RI：`use_imm=1`，必须有 extension，`vb=0`；
- `as` 和 `ad` 分开保存，因此累加源 ARF 与目的 ARF 可以不同；
- 当前窄结果是乘积低 8 bit，不是累加结果低 8 bit；
- VRF/ARF 可双写，export/reduction 观察窄结果。

### 4.6 `fmt=0x7`：WIDE_CONVERT

```text
31:28  fmt = 0x7
27:25  wide_op
24:21  src0
20:17  vb
16:13  dst
12:10  mask_sel
9      bimm
8      write_dst
7      export_narrow
6:4    red
3:0    reserved = 0
```

| `wide_op` | canonical function | `src0` | `dst` |
|---:|---|---|---|
| `0` | `SIMD_OP_WIDEN_U` | VRF-A | ARF |
| `1` | `SIMD_OP_WIDEN_S` | VRF-A | ARF |
| `2` | `SIMD_OP_RSHIFT_RND_U` | ARF source | ARF |
| `3` | `SIMD_OP_RSHIFT_RND_S` | ARF source | ARF |
| `4` | `SIMD_OP_NCLIP_U` | ARF source | VRF |
| `5` | `SIMD_OP_NCLIP_S` | ARF source | VRF |
| `6` | `SIMD_OP_NSLICE` | ARF source | VRF |
| `7` | reserved | - | - |

ARF 地址只使用 `src0/dst[2:0]`，对应的 bit 3 必须为零。`vb` 在 register form 中
提供每 physical lane 的 shift amount；immediate form 使用 extension 低 5 bit。
element mode 固定为 BYTE。

WIDEN 和 RSHIFT_RND 要求 `export_narrow=0`、`red=0`；`write_dst` 表示写 ARF。
NCLIP/NSLICE 的 `write_dst` 表示写 VRF，并允许 export 和 byte reduction。

### 4.7 `fmt=0x8`：WADD_WSUB

```text
31:28  fmt = 0x8
27:26  wide_add_op
25:22  va
21:18  vb
17:15  as
14:12  ad
11:9   mask_sel
8:4    align
3      write_arf
2:0    reserved = 0
```

| `wide_add_op` | canonical function |
|---:|---|
| `0` | `SIMD_OP_WADD_U` |
| `1` | `SIMD_OP_WADD_S` |
| `2` | `SIMD_OP_WSUB_U` |
| `3` | `SIMD_OP_WSUB_S` |

element mode 固定为 BYTE。两个 VRF source 都是数据，因此不使用 extension；5-bit
`align` 直接放在 base。expander 可以统一输出 `use_imm=1`、
`imm[4:0]=align`。`align=0` 与当前 `use_imm=0` 的执行语义相同。

### 4.8 `fmt=0x9`：COMPACT

```text
31:28  fmt = 0x9
27     expand
26:25  elem_mode
24:21  va
20:17  vd
16:14  mask_sel
13:12  md
11     write_vrf
10     write_mrf
9      export_narrow
8:6    red
5:0    reserved = 0
```

`expand=0/1` 分别展开成 `SIMD_OP_COMPRESS/EXPAND`。VRF 与 MRF 可以同时写；
count result 由 function 自动产生，不占 base 字段。reduction 仍只在 BYTE mode 合法。
即使不写 RF、不 export 且不 reduction，compact count 仍构成一个 group result。

### 4.9 `fmt=0xa`：MRF_LOGIC

```text
31:28  fmt = 0xa
27:26  mask_op
25:24  ma
23:22  mb
21:20  md
19:16  vd
15     write_mrf
14     write_vrf
13     export_narrow
12:0   reserved = 0
```

| `mask_op` | canonical function |
|---:|---|
| `0` | `SIMD_OP_MAND` |
| `1` | `SIMD_OP_MOR` |
| `2` | `SIMD_OP_MXOR` |
| `3` | `SIMD_OP_MNOT` |

`ma/mb` 分别展开到 canonical `exec_mask_addr/select_mask_addr`，此时它们是数据源；
`mask_enable=0`，element mode 固定为 BYTE，reduction 关闭。MNOT 要求 `mb=0`。
结果可以同时写 MRF、物化成 VRF 全一/全零 byte，或作为 narrow result 导出。

### 4.10 `fmt=0xd`：ROUTE

```text
31:28  fmt = 0xd
27:26  route_op
25:22  va
21:18  vd
17:15  mask_sel
14     write_vrf
13     export_narrow
12:10  red
9:2    route_ctrl
1:0    reserved = 0
```

ROUTE 固定展开成 `SIMD_OP_PASS_A / ELEM_MODE_BYTE / route_enable=1`，只控制每个
SIMD4 内已经存在的 source-A 4×4 crossbar：

| `route_op` | `route_ctrl` | canonical route |
|---:|---|---|
| `0` | 四个 2-bit index；lane `n` 使用 `[2n+1:2n]` | `GATHER` |
| `1` | `[1:0]` 为 source lane，`[7:2]=0` | `BROADCAST` |
| `2` | `[2:0]` 为 amount `0..4`，`[7:3]=0` | `SLIDE_UP` |
| `3` | `[2:0]` 为 amount `0..4`，`[7:3]=0` | `SLIDE_DOWN` |

SLIDE 的 `route_lower/route_upper` 在本 profile 固定为零，因此是组内 zero-fill
语义；跨组 boundary operand 不塞进控制字。`PASS_A + write_vrf` 是独立搬运，
`export_narrow` 与 `red` 则观察 route 后的结果。其他 ALU 与 route 的融合形式暂不
编码，可先用 ROUTE 临时行再执行下一条 ALU。

示例：

```text
EXEC_ROUTE op=gather va=1 vd=2 i0=3 i1=2 i2=1 i3=0
=> 0xd048406c
```

## 5. Canonical expansion

expander 对每个合法 base 生成完整、确定的 canonical EXEC bundle。没有在某个
format 中出现的字段必须规范成零，不继承上一条 entry 的值。

### 5.1 固定派生

| canonical 字段 | v0 派生规则 |
|---|---|
| `dispatch_class` | `EXEC` |
| `route_enable` | ROUTE 为 `1`，其他 format 为 `0` |
| `route_op/index/broadcast/slide` | ROUTE 由 `route_op/route_ctrl` 派生，其他 format 全零 |
| `route_lower/route_upper` | 不来自 uword；本 profile 始终输出零 |
| `mask_enable/mask_addr` | 由 `mask_sel` 派生；MRF_LOGIC 固定 mask disabled |
| `reduce_enable/reduce_op` | 由 `red` 派生 |
| `use_imm/imm` | 由 `bimm` 或 MAC_RI 派生；WADD_WSUB 使用 inline align |
| `write_vrf/write_arf/write_mrf` | 由各 format 的显式 write bit 与 operation family 派生 |
| `elem_mode` | ALU/CMP/SELECT/COMPACT 使用字段；其他 format 固定 BYTE |

format-specific sub-op 先映射成 `simd_op_e`，然后复用
`simd_op_mode_legal`、`simd_op_can_write_*`、`simd_op_can_reduce` 和
`simd_exec_requires_result`。predecoder 的 cached metadata 和 selected-head
expander 必须从同一份映射派生，不能维护两套可独立变化的 function 表。

### 5.2 Writeback 与 result

writeback bit 不能只按 function 自动固定，因为当前 canonical EXEC 允许以下组合：

- CMP、COMPACT、MRF_LOGIC 的 VRF+MRF 双写；
- MUL/MAC 的 VRF+ARF 双写；
- RF writeback 与 narrow export、reduction 同时发生。

profile v0 不编码独立 `response_kind`。精确 result 形状派生为：

```text
has_narrow        = export_narrow
has_reduce        = (red != 0)
has_count         = (fmt == COMPACT)
needs_group_result = has_narrow || has_reduce || has_count
```

每条已接受 EXEC 仍产生 command completion；`needs_group_result` 只决定是否还需要
独立 group result record。tracker 的 expected-result mask 为：

```text
needs_group_result ? target_group_mask : 0
```

profile v0 保持当前 canonical EXEC 行为：允许一个 operation 不写 RF、不 export、
不 reduction，只产生 command completion。`NO_EFFECT` cause 为后续可能采用更严格
profile 时保留，v0 decoder 不因“没有数据结果”而产生该 cause。

### 5.3 Resource metadata

resource 不属于编码。predecoder/expander 至少根据 format 与 modifier 派生：

- 使用的 VRF-A、VRF-B、ARF 和两个 MRF read port；
- VRF/ARF/MRF write port；
- SIMD4-local route fabric；
- reduction 与 group-result buffer；
- immediate extension dependency。

exact resource 必须由硬件派生；sequencer 不另带一份可与 uword 冲突的资源声明。
bank、latency 和物理端口冲突以后可以扩充 sched metadata，而不改变 profile v0 的
operation 语义。`vsp_exec_uword_expander` 已在内部识别实际 RF 读写以检查地址，并已
接到 strict action-stream reference wrapper。该 wrapper 因为全局不重叠执行而把
`cmd_exact_resource` 显式置零；这只绕过当前不需要的并发仲裁，不等同于已经定义
resource bits。metadata 仍属于 admission/queue-head predecoder 工作项。

## 6. Illegal 与 reserved 规则

任何非法 entry 都必须遵守现有 ordered error 模型：不进入 group execution、不修改
VRF/ARF/MRF、不产生 partial multicast；只有 error completion 获得可靠存储空间后
才能释放 queue entry。

### 6.1 Profile-local error cause

`error_cause[3:0]` 使用：

| 值 | 名称 | 含义 |
|---:|---|---|
| `0x0` | `NONE` | 没有错误 |
| `0x1` | `BAD_FORMAT` | `fmt` 为 reserved |
| `0x2` | `BAD_SUBOP` | format 内 sub-op 为 reserved |
| `0x3` | `RESERVED_BITS` | 要求为零的 bit 非零 |
| `0x4` | `EXTENSION` | extension 缺失、多余或与 format 不匹配 |
| `0x5` | `IMMEDIATE` | extension 中未使用的 immediate 高位非零 |
| `0x6` | `MASK` | `mask_sel` 未定义 |
| `0x7` | `REDUCTION` | `red` 未定义或 operation/mode 不允许 reduction |
| `0x8` | `MODE` | element mode 未定义或 operation 不支持该 mode |
| `0x9` | `WRITEBACK_OR_EXPORT` | write/export 与 operation capability 不匹配 |
| `0xa` | `ADDRESS` | RF 地址超过实际 implementation profile |
| `0xb` | `UNUSED_FIELD` | 不消费的 source/destination 字段没有规范成零 |
| `0xc` | `NO_EFFECT` | 为后续较严格 profile 保留；v0 不产生 |
| `0xd` | `INTERNAL` | predecode/expander 映射不一致等内部错误 |
| `0xe..0xf` | reserved | - |

一项 entry 同时触发多个条件时，使用上表从 `BAD_FORMAT` 到 `INTERNAL` 的顺序选择
第一个 cause。`error_cause` 是内部 completion 诊断，不是处理器 trap、系统异常或
外部 ISA cause。

### 6.2 必须检查的条件

1. `fmt=0x0/0xb/0xc/0xe/0xf`；
2. ALU/CMP/WIDE 等 format 的 reserved sub-op；
3. 任意 `reserved=0` 位非零；
4. extension presence 与 `bimm`、MAC_RR/MAC_RI 不一致；
5. immediate 未使用高位非零；
6. `mask_sel=5..7`；
7. `red=7`，或 shared helper 判定该 function/mode 不可 reduction；
8. 未定义 element mode，或 function 只支持 BYTE 而编码了其他 mode；
9. writeback/export 超过 `simd_op_can_write_*` 与 narrow-result capability；
10. 任一实际使用的 RF 地址超出本 implementation 的 row 数，包括
    WIDE_CONVERT 的 ARF `src0/dst[3]` 置一；
11. 未使用字段没有规范成零，例如：
    - immediate form 的 `vb` 非零；
    - ABS/PASS 尝试使用 immediate；
    - ABS/PASS 的 `vb` 非零；
    - MNOT 的 `mb` 非零；
    - disabled write 的 destination 非零；
    - BROADCAST/SLIDE 未使用的 `route_ctrl` 高位非零；
    - SLIDE amount 超过 SIMD4 支持的 `0..4`；
12. cached predecode 与 selected-head canonical expansion 对 format、result 或 resource
    的解释不一致。

第 12 项是内部一致性错误。它不应由普通 uword bit pattern 主动选择，也不能降级成
可执行 operation。

## 7. Admission、queue 与 expander

建议的逻辑边界为：

```text
control-store word stream
        -> byte-PC source                                  [已有参考]
        -> stateful assembler + framing/class predecode    [已有参考]
        -> action-envelope binding + class-specific decode [待实现]
        -> static legality + cached sched metadata         [待实现]
        -> per-context compact queue
        -> selected-head canonical expander
        -> exact legality/resource check
        -> EXEC class path
```

assembler 必须先取得完整 record，EXEC adapter 才能报告 admission valid。静态错误也
以完整 entry 入队并按 context 顺序退休，不能在 enqueue 时越过更老 action。

`vsp_uword_predecoder` 已组合划分一个 bundle 内的完整 record 与未完成尾部；它没有
ready/valid、stream-end 或跨 bundle storage，因此不替代 assembler。
`vsp_uword_program_frontend` 已提供一个独立的线性 byte-PC/control-store/assembler
reference，并串行输出完整或 EOF 截断 record；它尚未接本节后续的 envelope、
class-specific decode 与 queue。对一条完整
EXEC record，word 0 是 base，word 1（若存在）是 extension，body word 不再按 header
分类。结构长度由 `vsp_exec_uword_extension_required()` 与 canonical expander 共享。

`vsp_exec_uword_expander` 的 `base_valid_i` 表示输入 packet 已经结束，而不是“base
到了、extension 也许稍后到”。因此 `out_valid_o=base_valid_i`；若格式要求 extension
而 `extension_valid_i=0`，它立即产生一条 `EXTENSION` illegal record。流式 control
store 若需要跨拍取得第二个 word，必须在 collector 内等待，不能把半条 packet 的
`base_valid_i` 提前送给 expander。

`vsp_cluster_controller_wrapper` 也沿用这项合同：完整 base 与可选 extension 必须在
`action_valid_i` 前关联好。`action_exec_extension_required_diag_o` 只用于观察当前
packet 的格式需求，不能作为“先提交 base、下一拍再补 extension”的 refill 请求。

当前 `simd_issue_queue` 的 `UWORD_W`、`RESOLVED_W` 和 `SCHED_META_W` 都是 opaque
参数；`simd_issue_decode_stage` 的 hook 也还不是本 profile 的 parser。接入时可以先
建立独立 encoder/expander 与 round-trip test，再决定 queue 是直接保存 65-bit
`base+ext_valid+ext`，还是保存 compact extension reference。

## 8. 延期边界

### 跨组 route

profile v0 的 ROUTE 只覆盖每个 SIMD4 内的 4×4 source-A crossbar。独立的默认
16×16 `vsp_lane_gather` 尚未连接四个 group 的 VRF 读取、staging、写回、ownership、
资源预留和 completion，因此没有可执行编码。它以后仍应进入 EXEC，而不是增加新的
dispatch class；届时需要与本地 ROUTE 明确区分，并保持外层 `0xb/0xc`
MEMORY/CONTROL framing 不冲突。

### MEMORY 与 CONTROL

MEMORY 已有独立的 canonical decoded request，包括 LOAD/STORE、address space、
address context、effective address、group mask、VRF row 和 span。它不使用本 EXEC
layout。CONTROL 也不占用本文 format；当前 reference controller 只实现全局
`END`，一般化 barrier/admin、owner handoff 与 per-context control state 仍是后续工作。

### 外部 instruction 与工具链

外部 instruction、assembler/compiler 表示和 sequencer control-store 可以采用不同
编码。未来若增加软件可见 ISA，入口 decoder 只需产生本文定义的内部 packet 或同一
canonical EXEC bundle；profile v0 本身不要求 SIMD4 取指，也不引入 PC、branch、
exception 或独立 scalar CPU。
