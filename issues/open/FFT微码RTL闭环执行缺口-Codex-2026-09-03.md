# FFT微码与RTL闭环执行缺口

**报告者**: Codex  
**日期**: 2026-09-03  
**优先级**: High  
**类型**: Enhancement  
**状态**: Open（静态BFP8真实RTL/VCS/Verdi闭环已通过；旧Q8.8/16-bit仍开放）

## 描述

仓库已有FFT测试信号、Q8.8旋转因子、bit-reverse表和
`examples/uword/dsp_fft_radix2.uasm`，但该微码文件明确是概念性结构，目前不能
作为64点FFT的端到端VSP实现。新增的`make test-vcs-fft64`可以在VCS中验证现有
数据和行为级radix-2算法，但不经过VSP取指、解码、SIMD执行和D-memory路径。

## 已确认缺口

1. 微码只加载了各16字节实部/虚部，没有遍历64个复数样本。
2. 首级蝶形引用VRF 2/3，但程序没有为它们装载对应的B输入。
3. 通用旋转因子复乘在ARF中产生部分积后，没有完成`NSLICE`、符号处理、
   Q8.8右移、舍入/截断及VRF回写。
4. 六级蝶形的索引生成、循环控制、跨16字节窗口搬运和逐级原位回写未实现。
5. 程序只存储一个16字节实部结果，没有输出64个复数频点。
6. 当前VCS demo没有实例化VSP DUT，不能给出硬件周期数或吞吐率。

## 要求建议

### 1. 固化数值语义

- 明确FFT数据格式、每级是否缩放、截断或舍入方式以及饱和/回绕策略。
- 明确有符号Q8.8复乘如何映射到现有8x8 `MUL_S/MAC_S`、ARF和
  `NSLICE/NCLIP`。
- 给出64点bin-8向量的逐级golden状态，便于定位首次偏差。

### 2. 完成可执行微码

- 实现64点bit-reverse装载或预重排输入约定。
- 实现全部6级、每级32个蝶形及twiddle索引循环。
- 按当前4-group/16-byte行宽分块调度，保证数据移动不依赖已退出产品路径的
  跨group寄存器路由。
- 将64个复数输出写回D-memory，并以合法`END`退休。

### 3. 增加端到端RTL TB

- 在VCS中实例化当前program/memory wrapper，装载组装后的FFT微码和现有fixture。
- 在启动前通过初始化端口将微码、输入、twiddle和输出缓冲区装入
  I/D共享lower backing SRAM；该模型作为本次仿真的L2/程序镜像替身。
- 不要求host或外部provider在运行时逐条供指，也不要求先实现真实
  L2/AXI/NoC。I-cache首次miss从backing SRAM正常refill即可。
- 对比行为级golden结果，至少检查bin 8/56、全频点误差界、程序完成状态和
  非法操作/协议错误。
- 记录总周期、EXEC/MEMORY action数量和D-memory请求数量。

### 4. 程序镜像与取指边界决策

- 当前RTL已有只读L1 I-cache（默认32-byte line、64 sets、2 ways），但仓库
  没有L2 cache实例。`shared physical fabric`下方只导出generic ordered
  lower request/response端口。
- 现有`vsp_uword_memory_system_wrapper` TB已在该lower端口接入
  `vsp_fabric_ordered_sram`，并用`backing_init_*`在launch前安装程序和数据；
  初始化本身不产生lower transaction。FFT VCS TB复用此机制。
- “去除取指要求”在本issue中指去除外部实时供指和真实L2前置，不是旁路
  PC/program source/framer/decode。否则无法证明汇编的变长微码在真实RTL
  程序路径上正确执行。
- 不直接回填I-cache内部SRAM：现有`param_cache`reset流程会逐set清除
  valid/tag/RR，而且没有对外的数据/tag/valid预装端口。直接backdoor写数据
  还需同步构造tag和valid，比预装lower backing SRAM更容易掩盖缓存与地址错误。

## 验收标准

- `dsp_fft_radix2.uasm`不再包含未完成占位或未初始化VRF引用。
- 汇编器测试覆盖该程序，并能生成稳定的hex/listing。
- VCS端到端回归执行真实VSP RTL，64点bin-8向量在已声明的Q8.8误差界内通过。
- 行为级VCS demo继续作为数据/算法参考，RTL测试不得仅复制同一实现作为oracle。
- 文档持续区分算法参考结果与RTL周期性能。

## 影响

本issue最初阻止仓库宣称“VSP RTL已运行完整64点FFT”。2026-09-04新增的原生
8-bit静态BFP profile现已在Verilator和VCS通过，因此可以在明确该数值契约时作此
声明；旧Q8.8/16-bit profile仍未闭环，历史周期估计也仍不能冒充实测性能。

## 提交29ff9a4验收结果（2026-09-03）

**验收结论**: 未通过FFT RTL/VCS入场检查，issue保持Open。

### 已通过项

- 新增的8个汇编示例均可由`vsp_uword_asm.py`生成hex/listing。
- `make test`默认Verilator回归全部通过，说明该提交没有破坏已有RTL基线。
- RTL独立`vsp_exec_uword_expander`回归仍通过1969项检查，说明已有
  format-0x7解码器本身可用。

上述结果不能验证新汇编器与RTL的跨层一致性：
`sim/vsp_uword_asm_tb.py`在该提交中未更新，没有覆盖任何`EXEC_WIDE_*`编码。

### Blocker A：EXEC_WIDE_RI扩展标志缺失

汇编器为`EXEC_WIDE_RI`输出两个word，但没有置位base word bit 9。
`vsp_exec_uword_extension_required()`明确使用该bit判断format-0x7是否拥有
扩展word。

实际产物例子：

```text
EXEC_WIDE_RI op=nslice arf=0 shift=8 vd=3
actual:   7c006100 00000008   # base[9] = 0
required: 7c006300 00000008   # base[9] = 1
```

当前产物会被framer视为一字NSLICE，后续`00000008`会成为新的非法
指令；若强制把extension交给expander，则会得到`EXTENSION`错误。

**要求**:

- `encode_wide_narrow(..., immediate_form=True)`必须置base bit 9。
- 修正注释/文档中把bit 9称为reserved的错误。
- 在`sim/vsp_uword_asm_tb.py`加入format-0x7精确golden、RR/RI长度、shift
  边界和非法字段拒绝测试。
- 增加“汇编产物 → predecoder/framer → expander”跨层测试，不得只分别
  测汇编器和RTL。

### Blocker B：Q8.8部分积示例不符合byte-lane语义

`math_mul16_hw_complete.uasm`和`math_q88_mul_hw.uasm`将一个VRF行里的
相邻字节当成16位数，但：

- `EXEC_ALU_RI op=shr_u mode=byte imm=8`的有效shift只取低3位，实际为
  shift 0，无法提取奇数lane的高字节。
- `and mode=byte imm=0xff`对每个8位lane是恒等操作，不会只保留偶数lane。
- 有符号Q8.8需要有符号高字节、无符号低字节的混合部分积和进位
  处理；当前全部使用`MUL_U/MAC_U`。
- 结果的高低字节没有被打包到同一可存储VRF布局，`VSTORE vrf=6`也不会
  同时存储VRF 7。

因此当前示例不能标记为`FUNCTIONAL`、“Q8.8精确”或已实测提速。

**要求**:

- 先固化一种与8位lane匹配的SoA高/低字节内存布局，或提供可执行的
  gather/scatter拆包与打包步骤。
- 给出有符号Q8.8部分积公式、进位、舍入/截断和溢出策略。
- 先用边界集`0, ±1 LSB, ±0.5, ±1.0, -128, max, 溢出组合`在真实
  RTL上验证Q8.8乘法，再将它作为FFT复乘依赖。

### Blocker C：bit-reverse示例的数据宽度不足

`fft_bit_reverse_gather.uasm`执行4个pass，总共只重排64字节。它可作为
64个8位标量的示例，但不是64点Q8.8复数FFT的bit-reverse：

- 64个Q8.8实数就需128字节；实部/虚部分离时各需8个16-lane pass。
- 64个交织Q8.8复数需256字节，需16个pass，byte index范围为0..255。
- 现有`fft64_bitreverse.hex`每行是16位文本值；RTL D-memory TB还需要定义它如何
  打包为byte索引表。

**要求**:

- 选定并只保留一种FFT复数内存布局（实/虚分离或交织）。
- 提供与该布局一致的byte-index内存镜像、完整pass数和期望输出。
- 先增加独立端到端bit-reverse RTL测试，逐字节对比64点输出，再接入
  蝶形。

### Blocker D：VCS许可证环境

2026-09-03 21:51重新运行`make -B test-vcs-fft64`时，VCS O-2018.09报错：

```text
Cannot connect to the license server.
Failed to obtain license...
```

当前`LM_LICENSE_FILE=/opt/synopsys/Synopsys.dat`，VCS命令可运行，但license server不可达。
同一环境在01:14曾成功运行行为级FFT demo的132项检查，因此本次是许可证
服务状态，不是FFT TB语法失败。

**要求**:

- 保证VCS compile/elaborate/runtime期间license server可达且具有可用feature。
- 若许可证仅短时忙，人工重跑可使用`-licwait`或`+vcs+lic+wait`；CI不应无限
  等待，需设定明确超时。
- 保留`-LDFLAGS -Wl,--no-as-needed`，这是VCS O-2018.09与当前GNU ld的必需
  兼容参数。

## Blocker修复回报复验与归并（2026-09-03 22:38）

根目录生成的`BLOCKER_FIX_REPORT_2026-09-03.md`已复验；结论归并到
本issue后删除该重复临时回报，避免出现两份状态源。

### A：编码修复接受，跨层Gate尚未完成

- 已确认`encode_wide_narrow(..., immediate_form=True)`置位base word bit 9。
- 重新组装`test_nslice_nclip.uasm`后，RI产物为
  `7c004300/0`、`7c006300/8`、`7c208300/0x10`、
  `7800a300/4`、`7a20c300/8`、`70006300/0`和
  `72208300/2`，所有RI base bit 9均为1；RR `7c40e100` bit 9为0。
- `sim/vsp_uword_asm_tb.py`已增加上述format-0x7精确golden、RI/RR长度、
  shift 0..31边界、寄存器边界、禁用目的字段和非法export拒绝测试。
  汇编器也已与RTL一致地拒绝`write=0`但目的寄存器非零及
  WIDEN的narrow export。
- `make test-vsp-uword-asm`通过；`make test-vsp-exec-uword-expander`仍通过1969项。
- 两者仍是独立回归；“汇编产物→predecoder/framer→expander”的单一跨层
  自动测试还未提供，因此Gate A只是部分通过。

### B/C：仍为功能Blocker

- `math_mul16_hw_complete.uasm`和`math_q88_mul_hw.uasm`只将状态改为
  `BLOCKED`并删除不实的FUNCTIONAL/精确/提速声明；没有新的Q8.8算法或RTL结果。
- `fft_bit_reverse_gather.uasm`只明确标注为64-byte scalar demo；仍未扩展为
  256-byte Q8.8 complex bit-reverse，也没有独立RTL TB。
- 因此Blocker B、C和Gate B状态不变。

### D：许可证暂态故障已恢复

- 22:38通过`lmutil lmstat`确认license server和`snpslmd`均为UP。
- `make -B test-vcs-fft64`已用VCS O-2018.09-SP2重新编译、elaborate和运行，
  `-LDFLAGS -Wl,--no-as-needed`生效。
- 行为级demo在6000 ps输出bin 8=`(0,-6561)`、bin 56=`(0,6561)`，
  **132项检查全部通过**。Blocker D从当前阻塞项降为环境监控项。
- 该结果仍是行为级FFT，未实例化VSP RTL，不改变Gate C未通过的结论。

## 分阶段重跑门槛

1. **Gate A：汇编与结构闭环**
   - 修复Blocker A；新wide golden/非法测试通过。
   - 完整汇编产物通过predecoder/framer/expander，无`EXTENSION`/非法指令。
2. **Gate B：算术与重排前置**
   - 真实RTL Q8.8乘法边界集通过。
   - 真实RTL 64点Q8.8复数bit-reverse逐字节通过。
3. **Gate C：FFT RTL/VCS**
   - 交付不含概念占位的完整64点微码、稳定hex/listing、输入/旋转因子/
     golden内存镜像。
   - VCS TB实例化program/memory wrapper，通过`backing_init_*`预装完整镜像，
     不依赖运行时host/provider供指或真实L2。
   - 保留正常PC→I-cache→framer/decode执行链，检查全频点误差、完成状态、
     协议错误、I-cache miss/refill、action/D-memory请求数和总周期。
   - VCS许可证预检通过后才执行商业仿真；许可证失败与设计失败分类报告。

## 原生lane静态BFP8闭环实现（2026-09-04）

### 数值规格决策

原Q8.8方案要求在byte-lane上实现signed 16x16乘法、拆包、进位和回包，
Blocker B/C不能靠修改注释消除。本轮新增一个与现有RTL原生能力匹配的可执行profile：

- 64点radix-2 DIT，SoA real/imag各64个signed byte；
- data为静态BFP8：signed-int8 mantissa，`x=m*2^(E-7)`；本fixture的
  `Ein=-2`，mantissa峰值96对应物理幅度0.1875，twiddle为Q2.6；
- host生成6-bit bit-reversed输入和每batch的A/B/twiddle byte index；
- 每级32个蝶形拆成两个16-lane batch，6级共12个batch；
- `MUL_S/MAC_S`形成`Tr/Ti/-Tr/-Ti`，format-0x8 `WADD_S`对齐旧A，
  `NCLIP_S shift=7`完成逐级1/2缩放、RTL同款舍入与饱和；
- 每级mantissa缩小1/2、共享指数加1；最终存储mantissa为`FFT(input)/64`，
  `Eout=4`与mantissa组合后表示未缩放FFT。

该选择是新的、明确标注的数值契约，不把旧Q8.8 fixture冒充为已闭环实现。
旧`dsp_fft_radix2.uasm`、`math_q88_mul_hw.uasm`和
`fft_bit_reverse_gather.uasm`继续保留为历史/受阻参考。

### 交付物

- `tools/generate_fft64_vsp.py`：确定性生成算法、调度表、SRAM镜像、逐级golden、
  最终golden和manifest；
- `tools/vsp_uword_asm.py`：新增RTL已有format-0x8的`EXEC_WADD`编码；
- `sim/integration/fft64_vsp_memory_system_tb.cpp`：Verilator端到端自检与VCD；
- `sim/fft64_vsp_vcs_tb.sv`：同一RTL/镜像的VCS自检与VPD；
- `make generate-fft64-vsp`、`make test-fft64-vsp`、
  `make test-vcs-fft64-vsp`；
- `docs/workloads/fft64-q7.md`：权威数值、地址、命令和边界说明。

生成结果位于ignored的`build/fft64_vsp/`：93-word微码、224-word data镜像、
完整listing/symbol、6级golden、最终golden及`fe,ff,00,01,02,03,04`指数计划。程序位于
`0x0020..0x0193`；data位于cacheable physical页`0x1000..0x137f`。
程序从`0x1100..0x111f`读入独立零向量，从`0x1360`读入16份`Ein=-2`，
在EXEC中生成16份`Eout=4`，并通过
VSTORE/D-cache/shared SRAM写回`0x1370`。

### RTL实测结果

2026-09-04执行：

```text
make test-fft64-vsp
PASS fft64_vsp_memory_system_tb: 1646 checks, 449 actions, 46125 cycles,
45 I-cache misses, 72 D-cache read misses, 1708 shared-RAM beats;
waveform=build/fft64_vsp/fft64_vsp.vcd
```

测试逐word经`backing_init_*`安装程序和数据，确认初始化不产生lower transaction；
启动后保留真实PC→I-cache→framer/decode→EXEC/MEMORY→D-cache→shared fabric→
backing SRAM路径。64个复数频点逐字节匹配生成器golden；bin 8为
`(0,-48)`，bin 56为`(0,48)`，输出指数为4，重构物理值为±6。449个action全部退休，无
architectural、memory、fetch、cluster、I/D path或maintenance protocol error。
生成的VCD可在`build/fft64_vsp/`中用
`verdi -ssf fft64_vsp.vcd -nologo`查看，使GUI日志也留在ignored的
build目录。

这也使Gate A中实际使用的RI extension和新format-0x8编码经过完整
fetch/framer/expander/execute链，不再只是汇编器与expander的两组独立测试。

### VCS复验与Verdi波形

许可证恢复后，`make test-vcs-fft64-vsp`已用VCS O-2018.09-SP2完成解析、
编译、elaborate、链接和运行。为兼容该版本，复验同时完成两处不改变设计意图的
编译兼容修复：

- sibling `VSP_MMU/rtl/core/vsp_mmu.sv`把
  `ptw_pte_fault_paddr_valid`声明移到首次procedural使用之前，并同步
  `rtl/integration/memory_ip.lock`哈希；
- `rtl/control/vsp_uword_multi_framer.sv`为时序块使用独立循环变量，消除VCS报告的
  combinational/sequential loop-index多驱动。

最终VCS输出：

```text
FFT64 static-BFP8 spectrum: Ein=-2, Eout=4, value_scale=1/8
PASS fft64_vsp_vcs_tb: 411 checks, 449 actions, 46440 cycles,
45 I-cache misses, 72 D-cache read misses, 1708 RAM beats
```

完整输出检查中bin 8/56的mantissa仍分别为`(0,-48)`和`(0,48)`。

VCS输出镜像与Python golden、Verilator RTL输出逐word一致。VPD位于
`build/vcs_fft64_vsp/fft64_vsp.vpd`；当前Verdi 2018使用VCS KDB和转换后的
FSDB，预置脚本自动加入关键信号：

```bash
make prepare-verdi-fft64-vsp
make view-verdi-fft64-vsp
```

本次已实际打开Verdi。`fft_stage`、`fft_batch`、`bfp_exponent`、
`completed_actions`、`fetch_pc_o`及cache/RAM计数器可用于定位执行阶段。

频谱结果同时自动写为64行CSV，再由Graphviz `neato -n2`生成确定坐标的
DOT/SVG/PNG；不依赖Matplotlib或NumPy。VCS testbench在program完成且memory
system静默后逐周期扫描连续real/imag输出区，向Verdi暴露`plot_bin`、M/E、
四个`real`值和对应Q16.16值，无需用户在计算结束后手工poke testbench。预置
脚本会把nWave定位到该64-bin扫描窗口。Verilator与VCS输出的CSV逐字节一致。

覆盖边界：当前端到端回归只使用bin-8单音，program、data与golden由
同一生成器产生。因此这是执行与memory-system闭环smoke，不能声称已完成
一般FFT的独立数学验证；后续还需独立DFT oracle和多类输入向量。

### Gate更新

- **Gate A（汇编与结构）**：对新静态BFP8程序已通过。
- **Gate B（算术与重排）**：新静态BFP8原生byte profile已通过真实RTL全频点检查；
  原Q8.8/16-bit profile仍未实现，不能借此宣称Q8.8已解决。
- **Gate C（FFT RTL/VCS）**：对静态BFP8 profile已由Verilator与VCS共同通过，
  VPD/VCD及Verdi查看路径已验证。
- issue继续保持Open只针对原始Q8.8/16-bit验收要求；动态BFP/BF16另由
  `动态块浮点与BF16执行缺口-Codex-2026-09-04.md`跟踪。

## q/127三音独立DFT扩展（2026-09-04）

前述“仅bin-8单音且golden同源”的static-BFP8覆盖缺口已通过独立扩展收口：

- 新增5/13/23号频点、幅度`0.40/0.28/0.16`的64点三余弦输入；输入严格采用
  `+127=+1`、`-127=-1`的q/127对称格式，码值范围`[-94,94]`；
- 新增不导入生成器的标准库`O(N^2)`直接DFT，最强六bin集合
  `5/13/23/41/51/59`与RTL一致；最大复误差`0.5101312`、RMS误差
  `0.175368301`、Parseval相对误差`1.695114%`，均通过明确门限；
- Verilator通过1646项检查，VCS通过411项检查；两者各执行449个action，cache/RAM
  覆盖计数一致，输出HEX和频谱CSV逐字节一致；
- Graphviz已输出复分量、单边幅度和相对dB的DOT/SVG/PNG；VCS VPD已转换为FSDB，
  Verdi中的64-bin `real`扫描由TB自动完成。

详细证据见`issues/resolved/FFT64三音定点频谱闭环-Codex-2026-09-04.md`和
`docs/workloads/fft64-mixed-s8.md`。本扩展不解决本issue原始Q8.8/16-bit
Blocker B/C，因此本issue状态仍为Open。
