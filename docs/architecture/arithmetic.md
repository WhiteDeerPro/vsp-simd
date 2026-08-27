# 乘法语义与多 byte 映射选项

## 当前实现 `[RTL事实]`

现有 lane RTL 的乘法语义是每个 byte lane 做 8×8 `a * b`；当前没有 HALF/WORD
乘法语义。RTL 保持行为描述，让综合工具按照目标技术选择 DSP、组合逻辑或其他
具体实现，因此不能仅凭源码断言物理上一定存在独立的 8×8 cell。

- FPGA 上，工具可把乘法映射到 DSP block 或逻辑资源；
- ASIC 上，综合工具通常会从算术库/标准单元构造实现；
- 当前没有工艺库、频率、面积和功耗约束，暂不手写 8×8 阵列内部结构。

## 多 byte 映射 `[候选]`

一个已验证的候选把多 byte 乘法按 base-256 digit convolution 分解。若目标只取
WORD 乘积低 32 bit，只需计算十个会影响低位结果的 8×8 部分积。当前用十步
shifted `PMAC8` 记号保留串行参考模型，不部署 RTL 操作码；是否采用该映射、加入
原语或四路对角线 CSA/Wallace reduction，留给吞吐与 PPA 比较。
详见[32-bit byte卷积乘法参考模型](../explorations/mul32-byte-convolution.md)。

## 什么时候重新比较实现 `[决策触发器]`

满足以下条件之一时，再建立多个乘法实现并进行综合比较：

- 8×8 乘法数量很大，推断结果成为明确 PPA 瓶颈；
- 需要在同一个 8×8 物理乘法器内共享有符号/无符号路径；
- 需要融合预加、乘法、累加、舍入或饱和；
- 目标 FPGA 的 DSP 宽度适合打包多个低位宽乘法；
- ASIC 目标允许 Booth、Wallace/Dadda、Baugh–Wooley 或近似乘法带来可测收益；
- 算法证明某些乘数是常量、低比特或允许有界误差。

在这些条件出现之前，自定义 8×8 multiplier 内部结构会过早绑定技术相关细节。
byte-pair selector、shifted PMAC 和可选部分积压缩属于其外部数据通路，
可以独立论证。

参考：[AMD Vivado Synthesis UG901 的乘法推断说明](https://docs.amd.com/r/2024.1-English/ug901-vivado-synthesis/Multipliers-Implementation)。
