const form = document.getElementById("upload-form");
const fileInput = document.getElementById("company-file");
const startButton = document.getElementById("start-button");
const manualButton = document.getElementById("manual-button");
const statusDot = document.getElementById("status-dot");
const statusTitle = document.getElementById("status-title");
const statusMessage = document.getElementById("status-message");
const jobMeta = document.getElementById("job-meta");
const jobIdText = document.getElementById("job-id");
const jobUpdatedText = document.getElementById("job-updated");
const actions = document.getElementById("actions");
const continueButton = document.getElementById("continue-button");
const downloads = document.getElementById("downloads");
const downloadXlsx = document.getElementById("download-xlsx");
const downloadCsv = document.getElementById("download-csv");
const logPanel = document.getElementById("log-panel");
const jobLog = document.getElementById("job-log");
const manualPanel = document.getElementById("manual-panel");
const bookmarkletLink = document.getElementById("bookmarklet-link");
const copyBookmarklet = document.getElementById("copy-bookmarklet");
const manualCount = document.getElementById("manual-count");

let currentJobId = "";
let pollTimer = null;
let lastWaitingToken = "";
const defaultTitle = document.title;
const initialJobId = new URLSearchParams(window.location.search).get("job") || "";

function setState(kind, title, message) {
  statusDot.className = `dot ${kind}`;
  statusTitle.textContent = title;
  statusMessage.textContent = message;
}

function stopPolling() {
  if (pollTimer) {
    window.clearInterval(pollTimer);
    pollTimer = null;
  }
}

function renderJob(job) {
  const waiting = job.checkpoint_state === "waiting";
  actions.hidden = !waiting;
  downloads.hidden = !(job.results_xlsx_url || job.results_csv_url);
  jobMeta.hidden = false;
  jobIdText.textContent = job.job_id || "-";
  jobUpdatedText.textContent = job.updated_at ? new Date(job.updated_at).toLocaleString("zh-CN") : "-";

  const logText = [job.stdout_tail, job.stderr_tail].filter(Boolean).join("\n");
  logPanel.hidden = !logText;
  jobLog.textContent = logText || "";
  manualPanel.hidden = job.mode !== "manual";
  if (job.mode === "manual") {
    bookmarkletLink.href = job.bookmarklet || "#";
    manualCount.textContent = `已采集 ${job.results_count || 0}/${job.total_count || 0} 家。`;
    setState("running", "等待普通 Chrome 采集", job.message || "请在普通 Chrome 详情页点击采集书签。");
    return;
  }

  if (job.results_xlsx_url) downloadXlsx.href = job.results_xlsx_url;
  if (job.results_csv_url) downloadCsv.href = job.results_csv_url;

  if (waiting) {
    setState("running", "需要你处理一下", job.message || "请在浏览器里完成当前步骤。");
    document.title = "需要人工接管 - 企业信用信息查询";
    const token = job.checkpoint_token || `${job.job_id}-${job.checkpoint_updated_at || job.message}`;
    if (token && token !== lastWaitingToken) {
      lastWaitingToken = token;
      window.setTimeout(() => {
        window.alert(`需要人工接管：\n${job.message || "请在浏览器里完成当前步骤。"}`);
      }, 50);
    }
    return;
  }
  document.title = defaultTitle;

  if (job.status === "success") {
    setState("success", "查询完成", "结果已经生成，可以下载。");
    stopPolling();
    startButton.disabled = false;
    return;
  }

  if (job.status === "failed") {
    setState("failed", "查询失败", job.error || job.message || "任务没有完成。");
    stopPolling();
    startButton.disabled = false;
    return;
  }

  setState("running", "正在查询", job.message || "浏览器正在查询企业信息。");
}

async function fetchJob() {
  if (!currentJobId) return;
  const response = await fetch(`/api/company-workflow/jobs/${currentJobId}`);
  const payload = await response.json();
  if (!response.ok) {
    throw new Error(payload.error || "读取任务状态失败");
  }
  renderJob(payload);
}

function startPolling() {
  stopPolling();
  fetchJob().catch((error) => {
    setState("failed", "状态读取失败", error.message);
  });
  pollTimer = window.setInterval(() => {
    fetchJob().catch((error) => {
      setState("failed", "状态读取失败", error.message);
      stopPolling();
    });
  }, 2000);
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const file = fileInput.files[0];
  if (!file) {
    setState("failed", "没有选择文件", "请先选择 Excel 或 CSV 文件。");
    return;
  }

  const formData = new FormData();
  formData.append("company_file", file);

  startButton.disabled = true;
  lastWaitingToken = "";
  actions.hidden = true;
  downloads.hidden = true;
  setState("running", "正在上传", "文件上传后会自动打开浏览器开始查询。");

  try {
    const response = await fetch("/api/company-workflow", {
      method: "POST",
      body: formData,
    });
    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload.error || "上传失败");
    }
    currentJobId = payload.job_id;
    window.history.replaceState({}, "", `/company.html?job=${encodeURIComponent(currentJobId)}`);
    renderJob(payload);
    startPolling();
  } catch (error) {
    setState("failed", "上传失败", error.message || "请稍后再试。");
    startButton.disabled = false;
  }
});

async function startManualMode() {
  const file = fileInput.files[0];
  if (!file) {
    setState("failed", "没有选择文件", "请先选择 Excel 或 CSV 文件。");
    return;
  }

  const formData = new FormData();
  formData.append("company_file", file);

  startButton.disabled = true;
  manualButton.disabled = true;
  lastWaitingToken = "";
  actions.hidden = true;
  downloads.hidden = true;
  setState("running", "正在创建采集任务", "创建完成后会显示书签脚本。");

  try {
    const response = await fetch("/api/company-workflow/manual", {
      method: "POST",
      body: formData,
    });
    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload.error || "创建失败");
    }
    currentJobId = payload.job_id;
    window.history.replaceState({}, "", `/company.html?job=${encodeURIComponent(currentJobId)}`);
    renderJob(payload);
    startPolling();
  } catch (error) {
    setState("failed", "创建失败", error.message || "请稍后再试。");
  } finally {
    startButton.disabled = false;
    manualButton.disabled = false;
  }
}

manualButton.addEventListener("click", startManualMode);

copyBookmarklet.addEventListener("click", async () => {
  const code = bookmarkletLink.href;
  try {
    await navigator.clipboard.writeText(code);
    setState("success", "已复制书签脚本", "在普通 Chrome 新建书签，把网址粘贴为刚复制的脚本。");
  } catch {
    setState("failed", "复制失败", "可以右键复制“采集当前企业页”的链接地址。");
  }
});

continueButton.addEventListener("click", async () => {
  if (!currentJobId) return;
  continueButton.disabled = true;
  setState("running", "继续查询中", "正在恢复后台任务。");
  try {
    const response = await fetch(`/api/company-workflow/jobs/${currentJobId}/continue`, {
      method: "POST",
    });
    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload.error || "继续失败");
    }
    renderJob(payload);
  } catch (error) {
    setState("failed", "继续失败", error.message || "请稍后再试。");
  } finally {
    continueButton.disabled = false;
  }
});

if (initialJobId) {
  currentJobId = initialJobId;
  startButton.disabled = true;
  setState("running", "正在恢复任务", "正在读取已经上传的查询任务。");
  startPolling();
}
