# 映序局域网接口 v1

## 启动和配对

在 MFlux Studio 的「连接映序」打开「开启连接」开关。应用保存开关和选定网卡，之后每次打开 MFlux Studio 都会自动恢复。服务绑定该网卡的局域网 IPv4 地址和 TCP 42817，接收同 IPv4 子网的请求。服务默认关闭。手机启动时可用已保存的凭证重连 Mac。

Mac 用 Bonjour 发布 `_mflux-studio._tcp`，TXT 含 `v=1`、`ipv4` 和 `serverId`。Android 使用 NSD 找到设备，让用户选择 Mac 后输入配对码。发现失败时支持手动填入 Mac 显示的 HTTPS 地址。Bonjour 和手填地址都只提供连接地址，身份要在 TLS 中核验。

### 一次性配对码

从 MFlux Studio 1.17 开始使用配对码。Mac 界面显示 12 位字符，形如 `XXXX-XXXX-XXXX`。输入可忽略连字符、空格和大小写，规范化后必须是 12 个来自 `0123456789ABCDEFGHJKMNPQRSTVWXYZ` 的字符。五分钟内可使用一次。重新生成、停止服务或成功配对会让当前码失效。配对码留在手机本地用于计算证明。

1. 生成 32 字节的客户端随机数，编码为 64 位小写十六进制字符串 `nonce`。在独立、临时的 TLS 1.2+ 连接中记录实际叶证书的 DER SHA-256 指纹。配对前的自签名只用于这条受限连接。发送 `POST /v1/pair/challenge` 和 `{"nonce":"…"}`，获得 `{"version":1,"serverId":"…","proof":"…"}`。这一步只发送随机数。
2. 用下面的算法计算 `server` 证明并与响应做常量时间比较。指纹必须来自 TLS 握手。校验通过后，把该证书指纹固定给此 Mac。在发送最终配对请求前，后续 TLS 握手继续校验该指纹。
3. 用同一个 nonce 和 `client` 角色计算另一个证明，发送 `POST /v1/pair` 和 `{"nonce":"…","proof":"…","deviceName":"我的手机"}`。返回 201 和 `{"version":1,"serverId":"…","deviceId":"…","token":"…"}`。校验两次返回的 serverId 一致。保存配对证书指纹、serverId、deviceId 和 endpoint，并加密保存 token。403 `pairing_invalid` 表示证明无效、码已使用或已过期。

证明为 `hexLower(HMAC-SHA256(key=UTF8(规范化后的配对码), message=UTF8(下列四行)))`。行与行之间使用 LF，末尾不加换行。serverId 用小写 UUID，指纹和 nonce 都用小写十六进制。

```text
mflux-studio-pair-v1:<server 或 client>
<serverId>
<实际 TLS 叶证书 DER 的 SHA-256>
<nonce>
```

已配对的请求发送 `Authorization: Bearer <token>`，并在发送前核验保存的证书指纹。地址变化时可重新发现或手动更新地址，确认同一证书和 serverId 后继续使用原凭证与任务 ID。被撤销的设备收到 401。配对凭证与方舟连接各自管理。

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
