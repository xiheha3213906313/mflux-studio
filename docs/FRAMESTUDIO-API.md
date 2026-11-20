# 映序局域网接口 v1

## 启动和配对

在 MFlux Studio 的「连接映序」中手动开启服务。服务绑定选定的局域网 IPv4 地址和 TCP 42817，只接受同 IPv4 子网的请求。Mac 应用保持运行。手机与 Mac 无需互联网连接即可使用已安装的模型。

每次生成的配对文本形如 `mflux-studio://pair?v=1&endpoint=…&fingerprint=…&serverId=…&code=…`。用 URI 解析器读取参数，并检查版本、HTTPS 地址、Mac 的 UUID 和 64 位十六进制指纹。指纹是 Mac 自签名叶证书 DER 字节的 SHA-256。TLS 1.2 或以上。首次发送任何信息前，用从 Mac 界面复制的指纹核验 TLS 叶证书。此身份校验仅用于与该 Mac 配对的原生网络连接。地址变化时可修改端点，继续验证同一证书指纹和 serverId。

`POST /v1/pair` 接受 JSON 请求 `{"code":"…","deviceName":"我的手机"}`。返回 HTTP 201 和 `{"version":1,"serverId":"…","deviceId":"…","token":"…"}`。配对码有效期为五分钟，用后失效。确认返回的 serverId 和配对文本一致，保存 serverId、deviceId 和 endpoint，并加密保存 token。之后的请求发送 `Authorization: Bearer <token>`。被撤销的设备收到 401。配对地址和已配对设备的凭证与方舟连接各自管理。

HTTP 使用 1.1、固定 `Content-Length`、无重定向。含 JSON 的 POST 用 `Content-Type: application/json`，取消请求为空体。每次请求后服务端关闭连接。错误返回 `{"error":{"code":"…","message":"…"}}`，业务判断用 HTTP 状态与 code。

## 模型目录

`GET /v1/models` 返回 `version`、`serverId`、`models` 和 `limits`。每项模型有 `id`（UUID）、`name`、`familyId`、`variant`、`ready` 和 `operations`。操作的 `id` 为 `txt2img`、`img2img`、`inpaint` 或 `upscale`。按模型、操作和 ready 构建选择器。ID 对应 Mac 本地库条目。只包含完整或已组装的条目，按可用的 mflux 命令列出操作。

- 各操作提供 `minInputs/maxInputs`、`seed.min/max`、`lowRAM`。
- 生图、参考图编辑和局部编辑还提供 `size`（`step/maxEdge/presets/followInput/custom`）、`steps.min/max/default`、`negativePrompt`、`samplerDefaultLabel`、`samplers`（`id/label`）、`loras`（`id/name/defaultStrength`）。`guidance` 存在时提供 `min/default`，`fixedGuidance` 用于显示只读值。`imageStrength.min/max/default` 仅出现于支持重绘强度的操作。
- 放大提供 `scales/defaultScale/maxOutputEdge` 和 `softness.min/max/default`。自定义短边按底图比例受最长边上限约束。
- `limits` 包含 `maxBodyBytes`（64 MiB）、`maxInputBytes`（每张 24 MiB）、`maxInputPixels`（每张 5,000 万像素）、`maxInputEdge`（12,000 像素）和 `retentionDays`（7）。提交前按实际字节计算 Base64 膨胀后的请求大小。参考图全局最多 14 张，模型可以有更低的上限。

## 提交任务

`POST /v1/jobs` 的 JSON 形状如下。一次任务出一张 PNG。

```json
{
  "id": "7BD33DD4-6CB1-4332-88AA-DF6C49253CA3",
  "operation": "img2img",
  "modelId": "请使用模型目录返回的UUID",
  "prompt": "把 @image 1 的外套换成深蓝色",
  "options": {
    "width": 768,
    "height": 768,
    "steps": 4,
    "seed": 12345,
    "lowRAM": false
  },
  "inputs": ["此处为不带 data URL 前缀的原始图片 Base64"]
}
```

- `txt2img` 输入为空数组。其余操作按目录要求提交 PNG、JPEG 或 WebP，按参考图顺序发送，Base64 使用标准字母表。`@image N` 始终使用从 1 开始的阿拉伯数字，Mac 在调用模型之前解析引用并校验索引。
- 生图类 `options` 中宽高一起提供或一起省略。省略时按操作自动选择尺寸，文生图默认为方图，参考图编辑和局部编辑优先跟随第一张图。局部编辑仅接受 `Sources/StudioModels.swift` 中 `GenerationSize(ratio: .original, preferSourceSize: true)` 根据定向后底图计算的尺寸集合，复用同一尺寸算法，或省略宽高让 Mac 选择。其他生图操作支持 4096 以内、符合模型步长的宽高。
- `options` 可提交 `steps`、`seed`（无符号 32 位，安卓用 long 存储）、`lowRAM`，以及目录中可写的 `guidance`、`sampler`、`negativePrompt`、`imageStrength` 和 `loras`。LoRA 形状为 `[{"id":"目录里的LoRA UUID","strength":0.8}]`，不同 ID 最多 16 个，强度范围 0–2。留空种子由 Mac 在第一次受理时生成并保存。
- `inpaint` 的 `inputs` 只有当前底图，`strokes` 在 JSON 顶层。笔迹按涂抹顺序发送，例 `[{"diameter":0.08,"erases":false,"points":[{"x":0.25,"y":0.55},{"x":0.35,"y":0.55}]}]`。坐标以定向后的完整底图左上角为原点，x、y 范围 0–1。diameter 是底图短边的比例，范围 0.001–1。最多 512 条笔迹，总点数至多 50,000。遮罩外按同尺寸底图合成。
- `upscale` 提交一张原图，省略提示词和笔迹。options 可传 `scale`（例如 `"2x"`）或 `shortEdge`（目标短边像素），再按需提交 `softness`、`seed`、`lowRAM`。两种分辨率参数二选一，均省略时默认两倍。
- 初次受理返回 202，Mac 已持久化任务。相同 deviceId 和任务 ID 重试必须发送完全相同的请求体字节，返回原任务和 HTTP 200。同一 ID 的不同请求体返回 409 `id_conflict`。安卓应在首次发送前保存任务 UUID、输入文件快照和稳定的序列化顺序。连接中断后先 GET 查询，同一台 Mac 确认 404 时可按原请求体重试。用户明确重新生成时创建新 UUID。
- 422 对应模型、操作、尺寸、引用、图片、LoRA 或其他参数校验失败。429 `queue_full` 可稍后按原请求重试。507 表示 Mac 存储错误。Android 可在用户重试前刷新模型目录。

## 查询、取消和接收原图

- `GET /v1/jobs/{id}` 返回任务对象。`state` 为 `queued`、`running`、`succeeded`、`failed` 或 `cancelled`。响应包含 `id/operation/modelId/modelName/familyId/createdAt/options`。options 含 Mac 采用的尺寸、步数和实际种子等。失败时返回 `error.code/message`。任务在 Mac 运行期间被应用中断，重开服务后报告 `interrupted`。
- `POST /v1/jobs/{id}/cancel` 为空体。排队任务确认取消时返回 200。运行中返回 202 和 `cancelRequested:true`，以随后查询到的终态为准。已处于终态时返回原状态。
- 成功响应中的 `output` 提供 `width/height/elapsedSeconds/path/mimeType`。`GET /v1/jobs/{id}/output` 返回原始 PNG 字节，建议直接流式写入应用临时文件，校验完成后再入库。仅接受同一个 HTTPS 端点上的已知相对路径。已完成任务的中转图保留约 7 天，过期或原图缺失时返回 404 `output_unavailable`。本地任务记录仍可查询。
- 同一设备凭证只能访问自己的任务。更换 Mac 的 IPv4 地址时保留原来的配对凭证和证书指纹，更新 endpoint 后按原任务 ID 查询。
