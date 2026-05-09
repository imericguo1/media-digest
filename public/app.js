const form = document.getElementById("digest-form");
const apiKeyInput = document.getElementById("api-key");
const rememberKeyInput = document.getElementById("remember-key");
const modelSelect = document.getElementById("model-select");
const hoursSelect = document.getElementById("hours-select");
const autoRefreshInput = document.getElementById("auto-refresh");
const sourceList = document.getElementById("source-list");
const selectAllButton = document.getElementById("select-all-button");
const serviceState = document.getElementById("service-state");
const statusBox = document.getElementById("status");
const sidebarSummary = document.getElementById("sidebar-summary");
const sourceCountLabel = document.getElementById("source-count-label");
const feedList = document.getElementById("feed-list");
const feedCount = document.getElementById("feed-count");
const refreshButton = document.getElementById("refresh-button");
const exportButton = document.getElementById("export-button");
const sourceTemplate = document.getElementById("source-template");
const feedTemplate = document.getElementById("feed-template");

let sources = [];
let latestDigest = null;
let autoRefreshTimer = null;
let digestPollTimer = null;
const expandedFeedIds = new Set();

const storedKey = window.localStorage.getItem("media-digest-deepseek-api-key");
if (storedKey) {
  apiKeyInput.value = storedKey;
  rememberKeyInput.checked = true;
}

function setStatus(message, kind = "info") {
  statusBox.textContent = message;
  statusBox.dataset.kind = kind;
}

function selectedSourceIds() {
  return Array.from(sourceList.querySelectorAll("input[type='checkbox']:checked")).map((input) => input.value);
}

function updateSourceCountLabel() {
  const selected = selectedSourceIds().length;
  sourceCountLabel.textContent = `${selected}/${sources.length || 0}`;
}

function renderSources(nextSources) {
  sources = nextSources;
  sourceList.innerHTML = "";

  sources.forEach((source) => {
    const node = sourceTemplate.content.cloneNode(true);
    const input = node.querySelector("input");
    input.value = source.id;
    input.checked = true;
    input.addEventListener("change", updateSourceCountLabel);
    node.querySelector(".source-name").textContent = source.name;
    node.querySelector(".source-region").textContent = source.region;
    sourceList.appendChild(node);
  });
  updateSourceCountLabel();
}

function renderSummary(digest) {
  const summary = digest.ai_summary;
  const local = digest.summary || {};
  const errors = digest.errors || [];
  const warnings = digest.warnings || [];
  const translation = digest.translation || {};

  sidebarSummary.classList.remove("empty-sidebar");
  sidebarSummary.innerHTML = "";

  const header = document.createElement("div");
  header.className = "sidebar-brief-header";
  const title = document.createElement("h2");
  title.textContent = local.headline || "今日简报";
  const generated = document.createElement("span");
  generated.className = "meta";
  generated.textContent = new Date(digest.generated_at).toLocaleString("zh-CN");
  header.append(title, generated);
  sidebarSummary.appendChild(header);

  if (summary?.editor_brief) {
    const brief = document.createElement("p");
    brief.className = "editor-brief";
    brief.textContent = summary.editor_brief;
    sidebarSummary.appendChild(brief);
  }

  const translationNote = document.createElement("p");
  translationNote.className = "translation-note";
  translationNote.textContent = translation.enabled
    ? `已自动翻译 ${translation.translated_count || 0}/${translation.candidate_count || 0} 条非中文内容。`
    : "未填写 DeepSeek API Key，非中文内容将保留原文。";
  sidebarSummary.appendChild(translationNote);

  const grid = document.createElement("div");
  grid.className = "sidebar-brief-grid";
  grid.appendChild(createPanel("关键进展", summary?.key_developments || local.bullets || [], "", 5));
  grid.appendChild(createPanel("后续关注", summary?.watchlist || local.keywords || [], "", 8));
  grid.appendChild(createPanel("来源分布", Object.entries(local.source_counts || {}).map(([name, count]) => `${name}：${count} 条`), "", 12));
  if (summary?.source_notes?.length) {
    grid.appendChild(createPanel("覆盖观察", summary.source_notes, "", 4));
  }
  if (errors.length) {
    grid.appendChild(createPanel("抓取异常", errors.map((item) => `${item.source_name}：${item.error}`), "warning", 4));
  }
  if (warnings.length) {
    grid.appendChild(createPanel("处理提示", warnings, "warning", 4));
  }
  sidebarSummary.appendChild(grid);
}

function createPanel(title, items, tone = "", limit = 8) {
  const section = document.createElement("section");
  section.className = tone ? `mini-panel ${tone}` : "mini-panel";
  const heading = document.createElement("h3");
  heading.textContent = title;
  const list = document.createElement("ul");

  if (!items.length) {
    const empty = document.createElement("li");
    empty.textContent = "暂无数据";
    list.appendChild(empty);
  } else {
    items.slice(0, limit).forEach((item) => {
      const li = document.createElement("li");
      li.textContent = item;
      list.appendChild(li);
    });
    if (items.length > limit) {
      const more = document.createElement("li");
      more.className = "more-item";
      more.textContent = `还有 ${items.length - limit} 项`;
      list.appendChild(more);
    }
  }

  section.append(heading, list);
  return section;
}

function generatedImageUrl(item) {
  const params = new URLSearchParams({
    title: item.title || "",
    source: item.source_name || "",
    region: item.source_region || ""
  });
  return `/api/generated-image?${params.toString()}`;
}

async function openTranslatedArticle(item, readerWindow) {
  const apiKey = apiKeyInput.value.trim();
  if (!apiKey) {
    readerWindow.close();
    setStatus("请先填写 DeepSeek API Key，再打开中文阅读页。", "error");
    return;
  }

  try {
    readerWindow.document.write("<p style=\"font:16px -apple-system;padding:24px;\">正在创建中文阅读页...</p>");
    const response = await fetch("/api/article/translate", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-deepseek-api-key": apiKey,
        "x-deepseek-model": modelSelect.value
      },
      body: JSON.stringify({
        url: item.url,
        title: item.title
      })
    });
    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload.error || "中文阅读页创建失败");
    }
    readerWindow.location.href = payload.url;
  } catch (error) {
    readerWindow.document.body.innerHTML = `<p style="font:16px -apple-system;padding:24px;color:#c2252d;">${error.message || "中文阅读页创建失败"}</p>`;
  }
}

function renderFeed(items) {
  feedList.innerHTML = "";
  feedCount.textContent = `${items.length} 条`;

  if (!items.length) {
    feedList.innerHTML = '<div class="empty-list">当前时间范围内没有抓取到报道。</div>';
    return;
  }

  items.forEach((item) => {
    const node = feedTemplate.content.cloneNode(true);
    const imageLink = node.querySelector(".feed-image-link");
    const image = node.querySelector(".feed-image");
    const badge = node.querySelector(".image-badge");
    imageLink.href = item.url || "#";
    const fallbackImage = generatedImageUrl(item);
    image.src = item.image_url || fallbackImage;
    image.alt = `${item.source_name} 新闻配图`;
    badge.textContent = item.image_generated ? "生成图" : "原图";
    image.addEventListener("error", () => {
      if (image.src.endsWith(fallbackImage)) return;
      image.src = fallbackImage;
      badge.textContent = "生成图";
    }, { once: true });

    node.querySelector(".feed-meta").textContent = `${item.source_name} · ${item.published_label || "时间未知"}${item.translated ? " · 已翻译" : ""}`;
    const link = node.querySelector(".feed-body h3 a");
    link.href = item.url || "#";
    link.textContent = item.title;
    link.addEventListener("click", (event) => {
      if (!card.classList.contains("expanded")) {
        return;
      }
      event.preventDefault();
      const readerWindow = window.open("about:blank", "_blank");
      if (!readerWindow) {
        setStatus("浏览器阻止了新窗口，请允许弹窗后重试。", "error");
        return;
      }
      openTranslatedArticle(item, readerWindow);
    });
    if (item.translated && item.title_original) {
      link.title = `原文标题：${item.title_original}`;
    }
    node.querySelector("p").textContent = item.description || "该 RSS 条目没有提供摘要。";
    if (item.translated && item.description_original) {
      node.querySelector("p").title = `原文摘要：${item.description_original}`;
    }
    const card = node.querySelector(".feed-card");
    const toggle = node.querySelector(".expand-toggle");
    if (expandedFeedIds.has(item.id)) {
      card.classList.add("expanded");
      toggle.textContent = "收起";
      toggle.setAttribute("aria-expanded", "true");
    } else {
      toggle.setAttribute("aria-expanded", "false");
    }
    toggle.addEventListener("click", () => {
      const expanded = card.classList.toggle("expanded");
      if (expanded) {
        expandedFeedIds.add(item.id);
      } else {
        expandedFeedIds.delete(item.id);
      }
      toggle.textContent = expanded ? "收起" : "展开";
      toggle.setAttribute("aria-expanded", String(expanded));
    });
    feedList.appendChild(node);
  });
}

function stopDigestPolling() {
  if (digestPollTimer) {
    window.clearTimeout(digestPollTimer);
    digestPollTimer = null;
  }
}

async function pollDigestJob(jobId) {
  try {
    const response = await fetch(`/api/digest/jobs/${encodeURIComponent(jobId)}`);
    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload.error || "后台处理状态读取失败");
    }

    latestDigest = payload;
    renderSummary(payload);
    renderFeed(payload.items || []);
    exportButton.disabled = false;

    const translated = payload.translation?.translated_count || 0;
    const total = payload.translation?.candidate_count || 0;
    if (payload.job_status === "complete") {
      setStatus(payload.ai_summary ? "汉化完成，已生成编辑摘要。" : "汉化完成，已生成基础汇总。", "success");
      stopDigestPolling();
      scheduleAutoRefresh();
      return;
    }
    if (payload.job_status === "failed") {
      setStatus("后台汉化没有完成，已保留当前结果。", "error");
      stopDigestPolling();
      scheduleAutoRefresh();
      return;
    }

    const action = payload.job_status === "summarizing" ? "正在生成中文简报" : "正在逐条汉化";
    setStatus(`${action}：${translated}/${total}`, "loading");
    digestPollTimer = window.setTimeout(() => pollDigestJob(jobId), 1800);
  } catch (error) {
    setStatus(error.message || "后台处理状态读取失败。", "error");
    stopDigestPolling();
    scheduleAutoRefresh();
  }
}

function buildMarkdown(digest) {
  const lines = ["# Media Digest 每日简报", ""];
  lines.push(`生成时间：${new Date(digest.generated_at).toLocaleString("zh-CN")}`);
  lines.push(`时间范围：最近 ${digest.window_hours} 小时`, "");

  if (digest.ai_summary?.editor_brief) {
    lines.push("## 编辑摘要", digest.ai_summary.editor_brief, "");
  }

  const developments = digest.ai_summary?.key_developments || digest.summary?.bullets || [];
  lines.push("## 关键进展");
  developments.forEach((item) => lines.push(`- ${item}`));
  lines.push("");

  lines.push("## 报道列表");
  (digest.items || []).forEach((item) => {
    lines.push(`- [${item.source_name}] ${item.title}`);
    if (item.url) lines.push(`  ${item.url}`);
  });

  return lines.join("\n");
}

function exportMarkdown() {
  if (!latestDigest) return;

  const blob = new Blob([buildMarkdown(latestDigest)], { type: "text/markdown;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = `media-digest-${new Date().toISOString().slice(0, 10)}.md`;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  URL.revokeObjectURL(url);
}

async function checkService() {
  try {
    const response = await fetch("/health");
    const payload = await response.json();
    serviceState.textContent = payload.ok ? "本地服务已连接" : "本地服务异常";
    serviceState.dataset.kind = payload.ok ? "success" : "error";
  } catch {
    serviceState.textContent = "本地服务未连接";
    serviceState.dataset.kind = "error";
  }
}

async function loadSources() {
  const response = await fetch("/api/sources");
  const payload = await response.json();
  renderSources(payload.sources || []);
}

selectAllButton.addEventListener("click", () => {
  const inputs = Array.from(sourceList.querySelectorAll("input[type='checkbox']"));
  const shouldSelect = inputs.some((input) => !input.checked);
  inputs.forEach((input) => {
    input.checked = shouldSelect;
  });
  updateSourceCountLabel();
  selectAllButton.textContent = shouldSelect ? "取消全选" : "全选";
});

exportButton.addEventListener("click", exportMarkdown);

autoRefreshInput.addEventListener("change", () => {
  scheduleAutoRefresh();
});

async function runDigest() {
  stopDigestPolling();
  expandedFeedIds.clear();
  const sourceIds = selectedSourceIds();
  if (!sourceIds.length) {
    setStatus("请至少选择一个媒体源。", "error");
    return;
  }

  const apiKey = apiKeyInput.value.trim();
  if (apiKey && rememberKeyInput.checked) {
    window.localStorage.setItem("media-digest-deepseek-api-key", apiKey);
  } else {
    window.localStorage.removeItem("media-digest-deepseek-api-key");
  }

  refreshButton.disabled = true;
  exportButton.disabled = true;
  latestDigest = null;
  setStatus("正在抓取媒体信息流。", "loading");
  sidebarSummary.className = "sidebar-summary empty-sidebar";
  sidebarSummary.innerHTML = '<p class="sidebar-empty">正在读取 RSS 源并整理摘要。</p>';
  feedList.innerHTML = "";
  feedCount.textContent = "";

  try {
    const controller = new AbortController();
    const timeoutId = window.setTimeout(() => {
      controller.abort();
    }, 60000);

    const response = await fetch("/api/digest", {
      method: "POST",
      signal: controller.signal,
      headers: {
        "Content-Type": "application/json",
        ...(apiKey ? { "x-deepseek-api-key": apiKey } : {}),
        "x-deepseek-model": modelSelect.value
      },
      body: JSON.stringify({
        source_ids: sourceIds,
        hours: Number(hoursSelect.value)
      })
    });
    window.clearTimeout(timeoutId);

    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload.error || "抓取失败");
    }

    latestDigest = payload;
    renderSummary(payload);
    renderFeed(payload.items || []);
    exportButton.disabled = false;
    if (payload.job_id) {
      const total = payload.translation?.candidate_count || 0;
      setStatus(`已抓取，正在逐条汉化：0/${total}`, "loading");
      refreshButton.disabled = false;
      pollDigestJob(payload.job_id);
    } else {
      setStatus(payload.ai_summary ? "抓取完成，已生成编辑摘要。" : "抓取完成，已生成基础汇总。", "success");
      scheduleAutoRefresh();
    }
  } catch (error) {
    sidebarSummary.className = "sidebar-summary empty-sidebar";
    sidebarSummary.innerHTML = '<p class="sidebar-empty">抓取没有完成，请根据提示调整后重试。</p>';
    const message = error.name === "AbortError"
      ? "DeepSeek 处理时间过长，本次请求已停止。可以减少媒体源或先关闭 DeepSeek 汇总再试。"
      : (error.message || "抓取失败，请稍后再试。");
    setStatus(message, "error");
  } finally {
    refreshButton.disabled = false;
  }
}

function scheduleAutoRefresh() {
  if (autoRefreshTimer) {
    window.clearTimeout(autoRefreshTimer);
    autoRefreshTimer = null;
  }

  if (!autoRefreshInput.checked) {
    return;
  }

  autoRefreshTimer = window.setTimeout(() => {
    runDigest();
  }, 24 * 60 * 60 * 1000);
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  runDigest();
});

checkService();
loadSources()
  .then(() => {
    if (autoRefreshInput.checked) {
      runDigest();
    }
  })
  .catch(() => setStatus("媒体源加载失败。", "error"));
