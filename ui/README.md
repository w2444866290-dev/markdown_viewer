# UI 设计稿说明

本目录保存 Markdown Viewer 的设计资料。
开发实现、逐元素核验和 UI 验收只以终稿 `Markdown Viewer.dc.html` 为直接依据。
`Design System.dc.html` 用于维护视觉语言、设计 token、组件状态和扩展边界，但不覆盖终稿。

## 文件定位

| 文件 | 性质 | 作用 |
|---|---|---|
| `Markdown Viewer.dc.html` | 终稿 | 定义应用完整界面、布局、交互状态和精确样式，是实现与验收的唯一设计真相源。 |
| `Design System.dc.html` | 设计系统 | 为设计维护提供 token、组件状态、扩展规则和反模式边界，不作为实现验收依据。 |
| `Markdown Viewer Icon 1024.png` | 图标源资源 | 用于生成应用的 `AppIcon.icns`。 |
| `格式示例.md` | Debug 格式 fixture | 是 Debug 构建、测试和 E2E 使用的格式示例唯一实体真相源，构建时只把逐字节副本放入 Debug App。 |
| `support.js` | 设计预览运行时 | 只供 `.dc.html` 浏览器预览和独立视觉捕获工具使用，不进入生产应用。 |

## 优先级规则

1. 开发实现、视觉核验和 QA 验收只以 `Markdown Viewer.dc.html` 为设计依据。
2. `Design System.dc.html` 只服务设计维护，不能覆盖终稿中的具体布局或行为。
3. `AGENTS.md` 记录已经拍板的产品定位和业务交互，不能用实现细节反向改变终稿。
4. [`SPEC-ALIGNMENT.md`](../SPEC-ALIGNMENT.md) 记录当前实现、明确偏差和验证入口，并取代已经不存在的 `实现核验清单.md`。
5. 如果终稿与产品决策冲突，应先在设计与产品层明确决定；如果当前实现或实现矩阵与终稿冲突，应修正实现或如实记录偏差，绝不能为了让现有实现通过验收而修改终稿。
6. 任何需要长期保留的例外都必须写入终稿、`AGENTS.md` 或 `SPEC-ALIGNMENT.md`，不能只存在于临时讨论中。

简要规则是设计系统维护语言，终稿决定界面，`AGENTS.md` 决定产品交互，[`SPEC-ALIGNMENT.md`](../SPEC-ALIGNMENT.md) 记录实现与验证。

## 视觉验证入口

捕获终稿参考图：

```bash
./scripts/visual/capture-reference.sh
```

将真实应用 E2E 截图与终稿参考图进行完整帧对比：

```bash
./scripts/visual/compare-real-app.sh
```

严格比较自动验证机器捕获的状态断言和非文字几何，但 passive 的七个画面来自 Debug 状态预置，不代表对应用户交互已经通过。
不得修改权威 HTML、参考捕获状态或验收合同来降低当前实现的差异。

视觉工具的详细说明见 [`scripts/visual/README.md`](../scripts/visual/README.md)，当前实现矩阵见 [`SPEC-ALIGNMENT.md`](../SPEC-ALIGNMENT.md)。
