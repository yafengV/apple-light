# 原生消息排版验收

这是本地展示样例，**不是模型实时回复**。检查 *强调*、`inlineCode()`、~~过期说明~~ 和中文换行。

## 代码块

```swift
struct Greeting {
    let message = "你好，ShipiOS"

    func printMessage() {
        print(message)
    }
}
// 长行检查：abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789
```

## 列表与引用

3. 保留列表的起始编号。
   - 嵌套子项中的 **粗体**。
4. 第二项。

- [x] 已完成项
- [ ] 待办项

> 引用中的第一段。
>
> 第二段包含 `code`。

## 表格

| 功能 | 状态 | 数量 |
| :--- | :---: | ---: |
| 代码复制 | 通过后记录 | 1 |
| 中文与 a\|b | 待检查 | 2 |

## 链接与原样内容

[公开网页](https://example.com) · [项目文件](HelloShipiOSApp.swift) · [不支持的协议](javascript:alert(1))

<script>这段 HTML 只显示，不执行。</script>

---

结束。复制整条回复应保留原始 Markdown；复制代码块应只包含代码。
