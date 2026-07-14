# Canva 导入与持续更新说明

本目录提供同一份产品内容的三种输出：

- `self-study-studio-product-deck.pptx`：16:9，20 页，适合产品演示、路演与评审。
- `self-study-studio-product-guide-a4.pptx`：A4 纵向，28 页，适合在 Canva 中继续编辑手册。
- `self-study-studio-product-guide-a4.pdf`：A4 纵向，适合直接阅读、发送与归档。

## 导入 Canva

1. 打开 Canva，选择「创建设计」→「导入文件」。
2. 演示时导入 `self-study-studio-product-deck.pptx`；编辑手册时导入 `self-study-studio-product-guide-a4.pptx`。
3. 导入后优先检查中文字体、长标题、流程图清晰度和手机截图裁切。源文件使用苹方；Canva 没有同名字体时，可统一替换为思源黑体或 Noto Sans SC。
4. PDF 是固定版式交付件，不建议作为后续编辑源。

## 内容来源

- 产品事实：`../PRODUCT_GUIDE.md`
- 共享结构化内容：`content.json`
- 流程图：`../assets/product-guide/product-*.mmd` 及对应 PNG/SVG
- 真实演示截图：`../assets/product-guide/demo-*.png`
- 截图范围与限制：`../assets/product-guide/SCREENSHOTS.md`

当前版本使用 10 张流程图和 9 张真实 iPhone Simulator 截图。Export 完成提示框没有稳定截取，因此使用可验证的导出流程图说明，不用虚构界面补位。

## 重新生成

在项目根目录运行：

```sh
scripts/generate-product-guide.sh
```

生成过程会校验全部必需流程图、输出两个 PPTX、导出 A4 PDF，并把逐页 PNG 预览写到系统临时目录，不污染仓库。

## 更新顺序

1. 功能或产品规则变化时，先更新 `docs/PRODUCT_GUIDE.md` 与 `content.json`。
2. 导航、判断条件或数据边界变化时，更新对应 Mermaid 源文件并重新渲染 PNG/SVG。
3. 界面变化时，使用匿名演示数据重新采集真实 Simulator 截图，并同步更新 `SCREENSHOTS.md`。
4. 运行生成脚本，逐页检查溢出、遮挡、图片拉伸、断开的流程连接和功能状态。
5. 更新文档版本、核对日期与测试基线后提交。
