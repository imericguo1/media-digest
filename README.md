# Media Digest

一个本地网页工具：自动抓取主要媒体 RSS 信息流，并生成每日新闻简报。

## 功能

- 选择国际、中国内地、香港媒体源和时间范围
- 自动抓取 RSS 标题、摘要、发布时间和原文链接
- 生成基础汇总、主题词、来源分布
- 可选填写 DeepSeek API Key，自动把非中文标题和摘要翻译成中文，并生成更像编辑简报的中文摘要
- 导出 Markdown 简报

## 运行方式

```bash
ruby server.rb
```

然后在浏览器访问：

```text
http://127.0.0.1:4567
```

## 发布部署

### 访问密码

如果要给朋友使用，建议设置一个访问密码：

```bash
APP_PASSWORD=你的访问密码 ruby server.rb
```

朋友打开网页时，用户名可以随便填，密码填写 `APP_PASSWORD` 的值。

### 公网运行

本地开发默认只监听 `127.0.0.1`。部署到服务器时需要监听公网地址：

```bash
BIND_ADDRESS=0.0.0.0 PORT=4567 APP_PASSWORD=你的访问密码 ruby server.rb
```

### Docker

构建镜像：

```bash
docker build -t media-digest .
```

运行：

```bash
docker run --rm -p 4567:4567 \
  -e BIND_ADDRESS=0.0.0.0 \
  -e APP_PASSWORD=你的访问密码 \
  -e DEEPSEEK_API_KEY=你的密钥 \
  media-digest
```

然后访问：

```text
http://服务器IP:4567
```

正式给朋友使用时，建议放到 Nginx / Caddy 后面并开启 HTTPS。

### Render

仓库里已包含 `render.yaml`。在 Render 中创建 Blueprint 或 Docker Web Service 后，设置这些环境变量：

- `APP_PASSWORD`：访问密码，建议必填
- `DEEPSEEK_API_KEY`：可选；不填则朋友需要在页面里填自己的 Key
- `BIND_ADDRESS=0.0.0.0`
- `PORT=4567`

### Fly.io

可以直接用 Dockerfile：

```bash
fly launch
fly secrets set APP_PASSWORD=你的访问密码
fly secrets set DEEPSEEK_API_KEY=你的密钥
fly deploy
```

如果不想承担 DeepSeek 调用费用，可以不设置 `DEEPSEEK_API_KEY`，让朋友在页面里填自己的 Key。

## 可选：启用 DeepSeek 汇总

页面里可以直接填写 DeepSeek API Key。也可以在启动前设置环境变量：

```bash
export DEEPSEEK_API_KEY=你的密钥
ruby server.rb
```

默认模型是 `deepseek-v4-flash`，也可以调整：

```bash
DEEPSEEK_MODEL=deepseek-v4-pro ruby server.rb
```

## 接口

- `GET /health`：检查本地服务状态
- `GET /api/sources`：获取默认媒体源
- `POST /api/digest`：抓取并汇总媒体信息流

`POST /api/digest` 示例：

```json
{
  "source_ids": ["nyt", "bbc", "guardian"],
  "hours": 24
}
```

## 说明

默认媒体源使用公开 RSS，包括 BBC、NYT、The Guardian、NPR、Al Jazeera、DW、新华社英文、中国日报、SCMP、RTHK、HKFP、明报等。不同媒体对 RSS 内容开放程度不同，有些条目只提供标题和短摘要；页面会保留原文链接，方便继续阅读和核验。
