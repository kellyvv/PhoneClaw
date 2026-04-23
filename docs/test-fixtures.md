# Test Fixtures

## 时间锚点确定性

为了让 golden corpus 和多轮 baseline 可复现，测试捕获时必须固定时间锚点：

```bash
PHONECLAW_FIXED_CURRENT_TIME_ANCHOR="2026-04-21 星期二 13:00"
```

当前约定：

- `golden_prompts.json` 捕获时使用这组固定值
- `perf-baseline-multiturn-*.json` 导出时使用这组固定值
- 生产环境 **不设置** 这个变量，时间锚点按小时整点动态生成

如果重新生成 fixture 或 baseline，没有设置这个环境变量，会因为时间锚点不同产生大面积 diff。
