# 拾刻 MCP 查询

| 工具 | 用途与参数 |
| --- | --- |
| `list_categories` | 无参数。检查连接，查看类别和字段。当前类别为 `food`、`weight`、`mood`、`knowledge`、`sport`，也可读历史 `daily`。 |
| `search_records` | 返回一页完整图文和 `next_cursor`。可选 `from`、`to`、`category`、`keyword`、`order`、`limit`、`cursor`、`photo_size`。 |
| `get_records` | 传 `ids`，每次 1–12 个，可选 `photo_size`。保留请求顺序并合并重复 ID，找不到的在 `missing_ids`。 |

`from`、`to` 为包含边界的 YYYY-MM-DD，可分别省略。按每条记录的当地 `date` 筛选。关键词匹配已保存的标题、正文、备注、标签和活动名。每页默认 6 条，可选 1–12 条，默认 `newest`，也可用 `oldest`。后续页把上一页的 `next_cursor` 传给 `cursor`，保持日期、类别、关键词和排序一致，直到 `next_cursor` 为 null。页大小和图片规格可以调整。

每条记录用 `id` 标识，含 `date`、`captured_at`、`timezone`、`category`、`source` 和原字段 `fields`。响应第 0 个 `content` 块是 JSON 文本。记录的 `photo.status` 为 `available` 时，`photo.content_index` 指向同一次响应中的 JPEG。每一页或重读响应的索引重新计算。默认 `standard`，需要看小字时按 ID 用 `detail` 复读。若客户端只传给模型文字，按实际看到的内容回答。

`none` 是无附件，`unavailable` 是有附件但 Mac 此次无法读取。两者都仍可使用已有文字。用 `sync_status` 判断当前 Mac 的覆盖范围。`data_as_of` 为最近一次成功应用的 iCloud 增量拉取时间，空值时仍可能有本机和手动导入记录。

拾刻端点只读，照片与文字通过同一授权入口读取。将查询范围限定在本次分析，分享或导出用用户指定的内容和目的地。
