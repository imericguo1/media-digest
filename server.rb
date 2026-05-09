require "base64"
require "cgi"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "pathname"
require "rexml/document"
require "securerandom"
require "tempfile"
require "time"
require "webrick"

ROOT = Pathname.new(__dir__)
PUBLIC_DIR = ROOT.join("public")
PDF_EXTRACTOR = ROOT.join("extract_pdf_text.py")
PYTHON_BIN = ENV.fetch(
  "PAPER_DIGEST_PYTHON",
  "/Users/Eric/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
)
DEFAULT_MODEL = ENV.fetch("DEEPSEEK_MODEL", "deepseek-v4-flash")
MAX_TOTAL_UPLOAD_BYTES = 50 * 1024 * 1024
MAX_CHARS_PER_FILE = 90_000
DEEPSEEK_TIMEOUT_SECONDS = ENV.fetch("DEEPSEEK_TIMEOUT_SECONDS", "600").to_i
MEDIA_AI_TIMEOUT_SECONDS = ENV.fetch("MEDIA_AI_TIMEOUT_SECONDS", "90").to_i
MEDIA_TRANSLATION_BUDGET_SECONDS = ENV.fetch("MEDIA_TRANSLATION_BUDGET_SECONDS", "120").to_i
MEDIA_TRANSLATION_ITEM_LIMIT = ENV.fetch("MEDIA_TRANSLATION_ITEM_LIMIT", "120").to_i
FEED_TIMEOUT_SECONDS = ENV.fetch("MEDIA_FEED_TIMEOUT_SECONDS", "12").to_i
MAX_FEED_ITEMS_PER_SOURCE = ENV.fetch("MEDIA_MAX_ITEMS_PER_SOURCE", "12").to_i
BIND_ADDRESS = ENV.fetch("BIND_ADDRESS", "127.0.0.1")
APP_PASSWORD = ENV.fetch("APP_PASSWORD", "").to_s

DIGEST_JOBS = {}
DIGEST_JOBS_MUTEX = Mutex.new
ARTICLE_JOBS = {}
ARTICLE_JOBS_MUTEX = Mutex.new
COMPANY_WORKFLOW_DIR = ROOT.join("company_credit_workflow")
COMPANY_WORKFLOW_SCRIPT = COMPANY_WORKFLOW_DIR.join("gsxt_workflow.py")
COMPANY_JOBS_DIR = COMPANY_WORKFLOW_DIR.join("web_jobs")
COMPANY_JOBS = {}
COMPANY_JOBS_MUTEX = Mutex.new

DEFAULT_MEDIA_SOURCES = [
  {
    id: "nyt",
    name: "The New York Times",
    region: "美国",
    url: "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml"
  },
  {
    id: "bbc",
    name: "BBC News",
    region: "英国",
    url: "https://feeds.bbci.co.uk/news/world/rss.xml"
  },
  {
    id: "guardian",
    name: "The Guardian",
    region: "英国",
    url: "https://www.theguardian.com/world/rss"
  },
  {
    id: "npr",
    name: "NPR News",
    region: "美国",
    url: "https://feeds.npr.org/1001/rss.xml"
  },
  {
    id: "aljazeera",
    name: "Al Jazeera",
    region: "卡塔尔",
    url: "https://www.aljazeera.com/xml/rss/all.xml"
  },
  {
    id: "dw",
    name: "Deutsche Welle",
    region: "德国",
    url: "https://rss.dw.com/rdf/rss-en-all"
  },
  {
    id: "xinhua-china",
    name: "Xinhua China",
    region: "中国内地",
    url: "https://www.xinhuanet.com/english/rss/chinarss.xml"
  },
  {
    id: "china-daily",
    name: "China Daily",
    region: "中国内地",
    url: "https://www.chinadaily.com.cn/china",
    kind: "china_daily_page"
  },
  {
    id: "scmp",
    name: "South China Morning Post",
    region: "香港",
    url: "https://www.scmp.com/rss/91/feed"
  },
  {
    id: "rthk-local",
    name: "RTHK Local News",
    region: "香港",
    url: "https://rthk.hk/rthk/news/rss/e_expressnews_elocal.xml"
  },
  {
    id: "rthk-greater-china",
    name: "RTHK Greater China",
    region: "香港",
    url: "https://rthk.hk/rthk/news/rss/e_expressnews_egreaterchina.xml"
  },
  {
    id: "hkfp",
    name: "Hong Kong Free Press",
    region: "香港",
    url: "https://hongkongfp.com/feed/"
  },
  {
    id: "ming-pao",
    name: "明报要闻",
    region: "香港",
    url: "https://news.mingpao.com/rss/pns/s00001.xml"
  }
].freeze

STOPWORDS = %w[
  about after against amid also among around before being could first from have
  into more over said says than that their this through under were when with
  will would your news world live update latest video photos report reports
].freeze

ANALYSIS_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["documents", "comparison"],
  properties: {
    documents: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: [
          "filename",
          "document_title",
          "summary",
          "main_points",
          "argument_process",
          "core_quotes",
          "references"
        ],
        properties: {
          filename: { type: "string" },
          document_title: { type: "string" },
          summary: { type: "string" },
          main_points: {
            type: "array",
            items: { type: "string" }
          },
          argument_process: {
            type: "array",
            items: {
              type: "object",
              additionalProperties: false,
              required: ["step", "reasoning", "evidence"],
              properties: {
                step: { type: "string" },
                reasoning: { type: "string" },
                evidence: { type: "string" }
              }
            }
          },
          core_quotes: {
            type: "array",
            items: {
              type: "object",
              additionalProperties: false,
              required: ["quote", "why_it_matters", "location_hint"],
              properties: {
                quote: { type: "string" },
                why_it_matters: { type: "string" },
                location_hint: { type: "string" }
              }
            }
          },
          references: {
            type: "array",
            items: {
              type: "object",
              additionalProperties: false,
              required: [
                "raw_citation",
                "authors",
                "year",
                "title",
                "source",
                "details",
                "identifier",
                "completeness"
              ],
              properties: {
                raw_citation: { type: "string" },
                authors: { type: "string" },
                year: { type: "string" },
                title: { type: "string" },
                source: { type: "string" },
                details: { type: "string" },
                identifier: { type: "string" },
                completeness: {
                  type: "string",
                  enum: ["complete", "partial", "uncertain"]
                }
              }
            }
          }
        }
      }
    },
    comparison: {
      type: "object",
      additionalProperties: false,
      required: [
        "available",
        "shared_topics",
        "key_differences",
        "method_comparison",
        "reference_overlap",
        "synthesis"
      ],
      properties: {
        available: { type: "boolean" },
        shared_topics: {
          type: "array",
          items: { type: "string" }
        },
        key_differences: {
          type: "array",
          items: { type: "string" }
        },
        method_comparison: {
          type: "array",
          items: { type: "string" }
        },
        reference_overlap: {
          type: "array",
          items: { type: "string" }
        },
        synthesis: { type: "string" }
      }
    }
  }
}.freeze

def json_response(res, status, payload)
  res.status = status
  res["Content-Type"] = "application/json; charset=utf-8"
  res.body = JSON.generate(payload)
end

def protected_path?(path)
  return false if APP_PASSWORD.empty?
  return false if path == "/health"

  true
end

def authorized_request?(req)
  return true if APP_PASSWORD.empty?

  auth = req["authorization"].to_s
  scheme, encoded = auth.split(/\s+/, 2)
  return false unless scheme.to_s.downcase == "basic"

  decoded = Base64.decode64(encoded.to_s)
  _user, password = decoded.split(":", 2)
  password.to_s == APP_PASSWORD
rescue StandardError
  false
end

def require_authorization(req, res)
  return true unless protected_path?(req.path)
  return true if authorized_request?(req)

  res.status = 401
  res["WWW-Authenticate"] = 'Basic realm="Media Digest"'
  res["Content-Type"] = "text/plain; charset=utf-8"
  res.body = "需要访问密码"
  false
end

def normalize_utf8(text)
  text.to_s.dup.force_encoding("UTF-8").encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
end

def load_api_key(req)
  header_key = req["x-deepseek-api-key"].to_s.strip
  return header_key unless header_key.empty?

  ENV["DEEPSEEK_API_KEY"].to_s.strip
end

def load_model(req)
  model = req["x-deepseek-model"].to_s.strip
  model.empty? ? DEFAULT_MODEL : model
end

def friendly_error(message)
  text = message.to_s
  return "API Key 无效或没有权限。请检查页面中的 DeepSeek API Key。" if text.match?(/invalid.*api key|incorrect api key|unauthorized|authentication/i)
  return "当前 API 额度不足。请到 DeepSeek 开放平台检查账户余额后再试。" if text.match?(/quota|billing|credits|insufficient balance/i)
  return "请求太频繁了。请稍等一会儿再重新分析。" if text.match?(/rate limit|too many requests/i)
  return "DeepSeek 返回时间过长，连接超时。可以重试一次，或先换用 deepseek-v4-flash、减少单次上传 PDF 数量。" if text.match?(/readtimeout|execution expired|timed out/i)
  return "DeepSeek 返回的 JSON 格式不完整，本次已保留新闻抓取结果；可以重新生成中文简报。" if text.match?(/json|unexpected token|parse/i)
  return "PDF 文字提取失败。请确认不是扫描版图片 PDF，或先用 OCR 转成可复制文字的 PDF。" if text.match?(/pdf text extraction|no extractable text|pypdf|pdf/i)

  text.empty? ? "分析失败，请稍后再试。" : text
end

def safe_filename(value)
  name = normalize_utf8(value).gsub(/[\\\/:*?"<>|\r\n\t]/, "_").strip
  name.empty? ? "uploaded.xlsx" : name
end

def company_job_snapshot(job_id)
  COMPANY_JOBS_MUTEX.synchronize do
    job = COMPANY_JOBS[job_id]
    return job.dup if job
  end

  restore_company_job_from_disk(job_id)
end

def update_company_job!(job_id, attrs)
  COMPANY_JOBS_MUTEX.synchronize do
    COMPANY_JOBS[job_id] ||= {}
    COMPANY_JOBS[job_id].merge!(attrs)
  end
end

def process_running_for_company_job?(job_id)
  output = `ps -ef 2>/dev/null`
  output.include?("company_credit_workflow/web_jobs/#{job_id}/")
rescue StandardError
  false
end

def restore_company_job_from_disk(job_id)
  return nil unless job_id.to_s.match?(/\A[0-9a-f]{16}\z/)

  job_dir = COMPANY_JOBS_DIR.join(job_id)
  return nil unless job_dir.directory?

  upload = Dir[job_dir.join("upload", "*").to_s].find { |path| File.file?(path) }
  output_dir = job_dir.join("output")
  logs_dir = job_dir.join("logs")
  results_file = output_dir.join("results.xlsx")
  running = process_running_for_company_job?(job_id)
  job = {
    id: job_id,
    status: results_file.file? ? "success" : (running ? "running" : "unknown"),
    filename: upload ? File.basename(upload) : "",
    input_path: upload.to_s,
    output_dir: output_dir.to_s,
    checkpoint_file: job_dir.join("checkpoint.json").to_s,
    stdout_file: logs_dir.join("stdout.log").to_s,
    stderr_file: logs_dir.join("stderr.log").to_s,
    message: running ? "任务仍在后台运行" : "任务状态已从文件恢复",
    created_at: File.directory?(job_dir) ? File.mtime(job_dir).iso8601 : Time.now.iso8601,
    updated_at: Time.now.iso8601,
    exit_status: nil,
    error: ""
  }
  update_company_job!(job_id, job)
  job
end

def company_checkpoint(job)
  path = job[:checkpoint_file].to_s
  return {} if path.empty? || !File.file?(path)

  JSON.parse(File.read(path), symbolize_names: true)
rescue StandardError
  {}
end

def tail_text(path, bytes = 8000)
  value = path.to_s
  return "" if value.empty? || !File.file?(value)

  size = File.size(value)
  File.open(value, "rb") do |file|
    file.seek([size - bytes, 0].max)
    normalize_utf8(file.read.to_s)
  end
rescue StandardError
  ""
end

def public_company_job(job)
  checkpoint = company_checkpoint(job)
  output_dir = Pathname.new(job[:output_dir].to_s)
  results_xlsx = output_dir.join("results.xlsx")
  results_csv = output_dir.join("results.csv")
  {
    job_id: job[:id],
    status: job[:status],
    filename: job[:filename],
    message: checkpoint[:message].to_s.empty? ? job[:message].to_s : checkpoint[:message].to_s,
    checkpoint_state: checkpoint[:state].to_s,
    checkpoint_token: checkpoint[:token].to_s,
    checkpoint_updated_at: checkpoint[:updated_at].to_s,
    created_at: job[:created_at],
    updated_at: job[:updated_at],
    exit_status: job[:exit_status],
    error: job[:error].to_s,
    stdout_tail: tail_text(job[:stdout_file]),
    stderr_tail: tail_text(job[:stderr_file]),
    results_xlsx_url: results_xlsx.file? ? "/api/company-workflow/jobs/#{job[:id]}/download/results.xlsx" : nil,
    results_csv_url: results_csv.file? ? "/api/company-workflow/jobs/#{job[:id]}/download/results.csv" : nil
  }
end

def uploaded_company_file(req)
  uploaded = req.query["company_file"] || req.query["file"]
  if uploaded.respond_to?(:each_data)
    first = nil
    uploaded.each_data do |entry|
      first = entry
      break
    end
    uploaded = first
  end
  uploaded
end

def start_company_workflow_job!(filename:, data:)
  ext = File.extname(filename).downcase
  raise "仅支持 .xlsx、.xls、.xlsm 或 .csv 文件。" unless [".xlsx", ".xls", ".xlsm", ".csv"].include?(ext)

  job_id = SecureRandom.hex(8)
  job_dir = COMPANY_JOBS_DIR.join(job_id)
  upload_dir = job_dir.join("upload")
  output_dir = job_dir.join("output")
  logs_dir = job_dir.join("logs")
  [upload_dir, output_dir, logs_dir].each(&:mkpath)

  input_path = upload_dir.join(safe_filename(filename))
  input_path.binwrite(data)
  checkpoint_file = job_dir.join("checkpoint.json")
  stdout_file = logs_dir.join("stdout.log")
  stderr_file = logs_dir.join("stderr.log")

  job = {
    id: job_id,
    status: "queued",
    filename: filename,
    input_path: input_path.to_s,
    output_dir: output_dir.to_s,
    checkpoint_file: checkpoint_file.to_s,
    stdout_file: stdout_file.to_s,
    stderr_file: stderr_file.to_s,
    message: "任务已创建",
    created_at: Time.now.iso8601,
    updated_at: Time.now.iso8601,
    exit_status: nil,
    error: ""
  }
  update_company_job!(job_id, job)

  Thread.new do
    update_company_job!(job_id, status: "running", message: "正在打开浏览器并查询", updated_at: Time.now.iso8601)
    command = [
      PYTHON_BIN,
      COMPANY_WORKFLOW_SCRIPT.to_s,
      input_path.to_s,
      "--output",
      output_dir.to_s,
      "--checkpoint-file",
      checkpoint_file.to_s
    ]
    status = nil
    begin
      FileUtils.touch(stdout_file.to_s)
      FileUtils.touch(stderr_file.to_s)
      Open3.popen3({ "PYTHONUNBUFFERED" => "1" }, *command, chdir: ROOT.to_s) do |_stdin, out, err, wait_thr|
        out_reader = Thread.new do
          out.each_line do |line|
            File.open(stdout_file.to_s, "ab") { |file| file.write(line) }
            clean = normalize_utf8(line).strip
            update_company_job!(job_id, message: clean, updated_at: Time.now.iso8601) unless clean.empty?
          end
        end
        err_reader = Thread.new do
          err.each_line do |line|
            File.open(stderr_file.to_s, "ab") { |file| file.write(line) }
          end
        end
        status = wait_thr.value
        out_reader.join
        err_reader.join
      end
      if status&.success?
        update_company_job!(job_id, status: "success", message: "查询完成", exit_status: status.exitstatus, updated_at: Time.now.iso8601)
      else
        stdout = tail_text(stdout_file)
        stderr = tail_text(stderr_file)
        update_company_job!(
          job_id,
          status: "failed",
          message: "查询没有完成",
          exit_status: status&.exitstatus,
          error: stderr.empty? ? stdout.lines.last.to_s : stderr.lines.last.to_s,
          updated_at: Time.now.iso8601
        )
      end
    rescue StandardError => e
      update_company_job!(job_id, status: "failed", message: "查询启动失败", error: e.message, updated_at: Time.now.iso8601)
    end
  end

  job_id
end

def continue_company_workflow!(job_id)
  job = company_job_snapshot(job_id)
  raise "没有找到这个任务。" unless job

  checkpoint_path = Pathname.new(job[:checkpoint_file].to_s)
  checkpoint_path.dirname.mkpath
  checkpoint_path.write(JSON.generate({
    state: "continue",
    message: "继续查询",
    updated_at: Time.now.iso8601
  }))
end

def company_inputs_from_file(path)
  code = <<~PY
    import json, sys
    from pathlib import Path
    sys.path.insert(0, str(Path("company_credit_workflow").resolve()))
    from gsxt_workflow import read_company_inputs
    items = read_company_inputs(Path(sys.argv[1]))
    print(json.dumps([{"company_name": item.company_name, "credit_code": item.credit_code} for item in items], ensure_ascii=False))
  PY
  stdout, stderr, status = Open3.capture3(PYTHON_BIN, "-c", code, path.to_s, chdir: ROOT.to_s)
  raise(stderr.empty? ? stdout : stderr) unless status.success?

  JSON.parse(stdout)
end

def extract_company_fields_from_text(text)
  value = normalize_utf8(text).gsub("\u3000", " ")
  stop = %w[
    统一社会信用代码 注册号 名称 企业名称 公司名称 类型 法定代表人 负责人 经营者 住所
    主要经营场所 经营场所 注册资本 成立日期 营业期限 经营范围 登记机关 核准日期 联系电话
    企业联系电话 通信地址 邮政编码
  ]
  extract = lambda do |labels|
    labels.each do |label|
      pattern = /#{Regexp.escape(label)}\s*[:：]?\s*(.+?)(?=\s*(?:#{stop.map { |item| Regexp.escape(item) }.join("|")})\s*[:：]?|\n|$)/m
      match = value.match(pattern)
      next unless match

      found = match[1].to_s.gsub(/\s+/, " ").strip.gsub(/\A[：:]+|[：:]+\z/, "")
      return found unless found.empty? || ["-", "暂无", "无"].include?(found)
    end
    ""
  end
  phone_matches = value.scan(/(?<!\d)(?:1[3-9]\d{9}|0\d{2,3}[ -]?\d{7,8}(?:-\d{1,6})?|\d{3,4}[ -]\d{7,8})(?!\d)/).uniq
  {
    company_full_name: extract.call(%w[名称 企业名称 公司名称]),
    address: extract.call(%w[住所 主要经营场所 经营场所 通信地址]),
    unified_social_credit_code: value[/\b[0-9A-Z]{18}\b/].to_s,
    legal_representative: extract.call(%w[法定代表人 负责人 经营者]),
    phones: phone_matches.join("; "),
    phone_source: phone_matches.empty? ? "" : "普通Chrome页面公开文本"
  }
end

def save_manual_company_results!(job)
  output_dir = Pathname.new(job[:output_dir].to_s)
  output_dir.mkpath
  rows_path = output_dir.join("manual_results.json")
  rows_path.write(JSON.pretty_generate(job[:results] || []))
  code = <<~PY
    import json, sys
    from pathlib import Path
    import pandas as pd
    rows = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    out = Path(sys.argv[2])
    out.parent.mkdir(parents=True, exist_ok=True)
    df = pd.DataFrame(rows)
    df.to_excel(out / "results.xlsx", index=False)
    df.to_csv(out / "results.csv", index=False, encoding="utf-8-sig")
  PY
  _stdout, stderr, status = Open3.capture3(PYTHON_BIN, "-c", code, rows_path.to_s, output_dir.to_s, chdir: ROOT.to_s)
  raise(stderr) unless status.success?
end

def start_manual_company_job!(filename:, data:)
  ext = File.extname(filename).downcase
  raise "仅支持 .xlsx、.xls、.xlsm 或 .csv 文件。" unless [".xlsx", ".xls", ".xlsm", ".csv"].include?(ext)

  job_id = SecureRandom.hex(8)
  job_dir = COMPANY_JOBS_DIR.join(job_id)
  upload_dir = job_dir.join("upload")
  output_dir = job_dir.join("output")
  [upload_dir, output_dir].each(&:mkpath)
  input_path = upload_dir.join(safe_filename(filename))
  input_path.binwrite(data)
  companies = company_inputs_from_file(input_path)
  now = Time.now.iso8601
  job = {
    id: job_id,
    status: "manual",
    mode: "manual",
    filename: filename,
    input_path: input_path.to_s,
    output_dir: output_dir.to_s,
    checkpoint_file: job_dir.join("checkpoint.json").to_s,
    stdout_file: job_dir.join("logs", "stdout.log").to_s,
    stderr_file: job_dir.join("logs", "stderr.log").to_s,
    message: "请在普通 Chrome 中打开公示系统企业详情页，然后点击采集书签。",
    companies: companies,
    results: [],
    created_at: now,
    updated_at: now,
    exit_status: nil,
    error: ""
  }
  update_company_job!(job_id, job)
  save_manual_company_results!(job)
  job_id
end

def manual_company_job_payload(job)
  base = public_company_job(job)
  base.merge(
    mode: "manual",
    companies: job[:companies] || [],
    results_count: Array(job[:results]).length,
    total_count: Array(job[:companies]).length,
    bookmarklet: manual_bookmarklet(job[:id])
  )
end

def manual_bookmarklet(job_id)
  js = <<~JS.gsub(/\s+/, " ").strip
    (()=>{const f=document.createElement('form');f.method='POST';f.action='http://127.0.0.1:4568/api/company-workflow/manual/jobs/#{job_id}/capture';f.target='_blank';const add=(n,v)=>{const i=document.createElement('textarea');i.name=n;i.value=v||'';f.appendChild(i)};add('url',location.href);add('title',document.title);add('text',document.body?document.body.innerText:'');document.body.appendChild(f);f.submit();})()
  JS
  "javascript:#{js}"
end

def capture_manual_company_page!(job_id, params)
  job = company_job_snapshot(job_id)
  raise "没有找到这个任务。" unless job

  text = params["text"].to_s
  fields = extract_company_fields_from_text(text)
  companies = Array(job[:companies])
  results = Array(job[:results])
  matched = companies.find do |company|
    name = company["company_name"].to_s
    code = company["credit_code"].to_s
    (!code.empty? && text.include?(code)) || (!name.empty? && text.include?(name))
  end || companies[results.length] || {}
  row = {
    input_company_name: matched["company_name"].to_s,
    input_credit_code: matched["credit_code"].to_s,
    company_full_name: fields[:company_full_name],
    address: fields[:address],
    unified_social_credit_code: fields[:unified_social_credit_code],
    legal_representative: fields[:legal_representative],
    phones: fields[:phones],
    phone_source: fields[:phone_source],
    page_title: normalize_utf8(params["title"]),
    detail_url: normalize_utf8(params["url"]),
    captured_at: Time.now.iso8601,
    status: "captured"
  }
  results.reject! do |existing|
    existing[:detail_url].to_s == row[:detail_url].to_s ||
      (!row[:unified_social_credit_code].empty? && existing[:unified_social_credit_code].to_s == row[:unified_social_credit_code])
  end
  results << row
  update_company_job!(job_id, results: results, message: "已采集 #{results.length}/#{companies.length}", updated_at: Time.now.iso8601)
  save_manual_company_results!(company_job_snapshot(job_id))
  row
end

def plain_text(value)
  CGI.unescapeHTML(value.to_s.gsub(/<[^>]*>/, " ")).gsub(/\s+/, " ").strip
end

def node_text(node)
  return "" unless node

  if node.respond_to?(:children)
    node.children.map { |child| child.respond_to?(:value) ? child.value : child.to_s }.join
  else
    node.text.to_s
  end
end

def mostly_chinese?(text)
  value = text.to_s
  cjk_count = value.scan(/[\p{Han}]/).length
  letter_count = value.scan(/[A-Za-z\p{Han}]/).length
  return false if letter_count.zero?

  cjk_count.to_f / letter_count >= 0.35
end

def text_at(node, *paths)
  paths.each do |path|
    found = REXML::XPath.first(node, path)
    text = node_text(found).strip
    return text unless text.empty?
  end
  ""
end

def attr_at(node, path, attr)
  found = REXML::XPath.first(node, path)
  found&.attributes&.[](attr).to_s
end

def absolute_url(url, base_url = nil)
  value = url.to_s.strip
  return "" if value.empty?
  return "https:#{value}" if value.start_with?("//")
  return value if value.match?(/\Ahttps?:\/\//i)
  return value unless base_url

  URI.join(base_url, value).to_s
rescue StandardError
  value
end

def image_from_html(html, base_url = nil)
  match = html.to_s.match(%r{<img\b[^>]*\bsrc=["']([^"']+)["']}i)
  absolute_url(match[1], base_url) if match
end

def feed_image_url(node, source)
  enclosure = REXML::XPath.match(node, "*[local-name()='enclosure']").find do |entry|
    entry.attributes["url"].to_s.match?(/\.(png|jpe?g|webp|gif)(\?|$)/i) ||
      entry.attributes["type"].to_s.start_with?("image/")
  end
  return absolute_url(enclosure.attributes["url"], source[:url]) if enclosure

  media = REXML::XPath.first(node, "*[local-name()='thumbnail']") ||
    REXML::XPath.first(node, "*[local-name()='content'][@url]")
  return absolute_url(media.attributes["url"], source[:url]) if media&.attributes&.[]("url").to_s != ""

  html = [
    text_at(node, "description", "*[local-name()='summary']"),
    text_at(node, "content", "*[local-name()='content']")
  ].join(" ")
  image_from_html(html, source[:url]).to_s
end

def parse_feed_time(value)
  Time.parse(value.to_s)
rescue StandardError
  nil
end

def http_get(url, redirects = 0)
  raise "抓取失败：跳转次数过多" if redirects > 5

  uri = URI(url)
  raise "仅支持 HTTP/HTTPS RSS 地址" unless %w[http https].include?(uri.scheme)

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.open_timeout = FEED_TIMEOUT_SECONDS
  http.read_timeout = FEED_TIMEOUT_SECONDS
  http.write_timeout = FEED_TIMEOUT_SECONDS if http.respond_to?(:write_timeout=)

  req = Net::HTTP::Get.new(uri)
  req["User-Agent"] = "MediaDigest/1.0 (+local research dashboard)"
  req["Accept"] = "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.8"

  response = http.request(req)
  if response.is_a?(Net::HTTPRedirection)
    next_url = URI.join(uri, response["location"].to_s).to_s
    return http_get(next_url, redirects + 1)
  end

  raise "抓取失败：HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  response.body
end

def parse_feed(xml, source)
  doc = REXML::Document.new(xml)
  nodes = REXML::XPath.match(doc, "//item")
  nodes = REXML::XPath.match(doc, "//*[local-name()='entry']") if nodes.empty?

  nodes.first(MAX_FEED_ITEMS_PER_SOURCE).map.with_index do |node, index|
    title = plain_text(text_at(node, "title", "*[local-name()='title']"))
    link =
      text_at(node, "link", "*[local-name()='link']") ||
      attr_at(node, "*[local-name()='link']", "href")
    link = attr_at(node, "*[local-name()='link']", "href") if link.empty?
    description = plain_text(text_at(
      node,
      "description",
      "summary",
      "content",
      "*[local-name()='summary']",
      "*[local-name()='content']"
    ))
    published_raw = text_at(
      node,
      "pubDate",
      "pubdate",
      "published",
      "updated",
      "*[local-name()='date']",
      "*[local-name()='published']",
      "*[local-name()='updated']"
    )
    published_at = parse_feed_time(published_raw)

    {
      id: "#{source[:id]}-#{index}-#{title.hash.abs}",
      source_id: source[:id],
      source_name: source[:name],
      source_region: source[:region],
      title: title.empty? ? "未命名报道" : title,
      description: description,
      title_original: title.empty? ? "未命名报道" : title,
      description_original: description,
      translated: false,
      url: absolute_url(link, source[:url]),
      image_url: feed_image_url(node, source),
      image_generated: false,
      published_at: published_at&.iso8601,
      published_label: published_at ? published_at.strftime("%Y-%m-%d %H:%M") : ""
    }
  end
end

def parse_date_from_china_daily_url(url)
  match = url.to_s.match(%r{/a/(\d{4})(\d{2})/(\d{2})/})
  return nil unless match

  Time.new(match[1].to_i, match[2].to_i, match[3].to_i, 12, 0, 0, "+00:00")
rescue StandardError
  nil
end

def china_daily_image_for(html, href)
  index = html.index(href) || html.index(href.sub(/\Ahttps?:/, ""))
  return "" unless index

  start = [index - 520, 0].max
  image_from_html(html[start, 1200], "https://www.chinadaily.com.cn").to_s
end

def parse_china_daily_page(html, source)
  items = []
  seen = {}
  html.scan(%r{<a\b[^>]*href=["']([^"']*/a/\d{6}/\d{2}/[^"']+)["'][^>]*>(.*?)</a>}im) do |href, raw_title|
    title = plain_text(raw_title)
    next if title.empty? || title.length < 8
    next if title.match?(/\A(read more|more|video|photo)\z/i)

    url = absolute_url(href, source[:url])
    next if seen[url]

    seen[url] = true
    published_at = parse_date_from_china_daily_url(url)
    image_url = china_daily_image_for(html, href)
    items << {
      id: "#{source[:id]}-#{items.length}-#{title.hash.abs}",
      source_id: source[:id],
      source_name: source[:name],
      source_region: source[:region],
      title: title,
      description: "China Daily China 栏目报道",
      title_original: title,
      description_original: "China Daily China 栏目报道",
      translated: false,
      url: url,
      image_url: image_url,
      image_generated: false,
      published_at: published_at&.iso8601,
      published_label: published_at ? published_at.strftime("%Y-%m-%d") : ""
    }
    break if items.length >= MAX_FEED_ITEMS_PER_SOURCE
  end
  items
end

def configured_sources(custom_sources = nil)
  return DEFAULT_MEDIA_SOURCES if custom_sources.nil? || custom_sources.empty?

  custom_sources.filter_map.with_index do |source, index|
    url = source["url"].to_s.strip
    name = source["name"].to_s.strip
    next if url.empty? || name.empty?

    {
      id: source["id"].to_s.strip.empty? ? "custom-#{index}" : source["id"].to_s.strip,
      name: name,
      region: source["region"].to_s.strip.empty? ? "自定义" : source["region"].to_s.strip,
      url: url
    }
  end
end

def fetch_media_digest(source_ids:, hours:, custom_sources: nil)
  sources = configured_sources(custom_sources)
  selected =
    if source_ids.empty?
      sources
    else
      sources.select { |source| source_ids.include?(source[:id]) }
    end
  cutoff = Time.now - (hours.to_i.clamp(1, 168) * 3600)
  errors = []
  items = []

  selected.each do |source|
    begin
      content = http_get(source[:url])
      feed_items =
        if source[:kind] == "china_daily_page"
          parse_china_daily_page(content, source)
        else
          parse_feed(content, source)
        end
      items.concat(feed_items.select do |item|
        item[:published_at].nil? || Time.parse(item[:published_at]) >= cutoff
      end)
    rescue StandardError => e
      errors << { source_id: source[:id], source_name: source[:name], error: friendly_error(e.message) }
    end
  end

  items.sort_by! { |item| item[:published_at] || "" }
  items.reverse!
  items.each { |item| ensure_item_image!(item) }

  {
    generated_at: Time.now.iso8601,
    window_hours: hours.to_i.clamp(1, 168),
    sources: selected.map { |source| source.slice(:id, :name, :region, :url) },
    items: items,
    errors: errors,
    summary: build_local_media_summary(items)
  }
end

def generated_image_url(item)
  query = URI.encode_www_form(
    title: item[:title],
    source: item[:source_name],
    region: item[:source_region]
  )
  "/api/generated-image?#{query}"
end

def ensure_item_image!(item)
  if item[:image_url].to_s.strip.empty?
    item[:image_url] = generated_image_url(item)
    item[:image_generated] = true
  end
  item
end

def svg_escape(text)
  normalize_utf8(text).then { |value| CGI.escapeHTML(value) }
end

def svg_title_lines(title, max_chars = 18, max_lines = 3)
  chars = normalize_utf8(title).chars
  lines = []
  until chars.empty? || lines.length >= max_lines
    line = chars.shift(max_chars).join.strip
    lines << line unless line.empty?
  end
  if chars.any? && lines.any?
    lines[-1] = "#{lines[-1].chars.first(max_chars - 1).join}..."
  end
  lines
end

def generated_image_svg(title:, source:, region:)
  title = normalize_utf8(title)
  source = normalize_utf8(source)
  region = normalize_utf8(region)
  seed = "#{title} #{source}".bytes.sum
  palettes = [
    ["#0f766e", "#dbeafe", "#f8fafc"],
    ["#1f4e5f", "#f6d365", "#fffdf5"],
    ["#7c2d12", "#fed7aa", "#fffbeb"],
    ["#263238", "#9ad7c5", "#f7fee7"],
    ["#3730a3", "#c7d2fe", "#f8fafc"]
  ]
  primary, secondary, paper = palettes[seed % palettes.length]
  title_tspans = svg_title_lines(title).each_with_index.map do |line, index|
    %(<tspan x="126" dy="#{index.zero? ? 0 : 42}">#{svg_escape(line)}</tspan>)
  end.join
  safe_source = svg_escape(source)
  safe_region = svg_escape(region)

  svg = <<~SVG
    <svg xmlns="http://www.w3.org/2000/svg" width="960" height="540" viewBox="0 0 960 540">
      <defs>
        <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="#{paper}"/>
          <stop offset="1" stop-color="#{secondary}"/>
        </linearGradient>
        <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
          <feDropShadow dx="0" dy="18" stdDeviation="18" flood-color="#111827" flood-opacity="0.18"/>
        </filter>
      </defs>
      <rect width="960" height="540" fill="url(#bg)"/>
      <circle cx="812" cy="98" r="132" fill="#{primary}" opacity="0.12"/>
      <circle cx="118" cy="442" r="178" fill="#{primary}" opacity="0.10"/>
      <g filter="url(#shadow)">
        <rect x="86" y="86" width="788" height="368" rx="18" fill="#ffffff" opacity="0.86"/>
      </g>
      <rect x="126" y="126" width="96" height="12" rx="6" fill="#{primary}"/>
      <text x="126" y="188" font-family="-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif" font-size="34" font-weight="800" fill="#1d1f1f">#{safe_source}</text>
      <text x="126" y="230" font-family="-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif" font-size="20" font-weight="700" fill="#64748b">#{safe_region} · Generated visual</text>
      <text x="126" y="298" font-family="-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif" font-size="32" font-weight="800" fill="#111827">#{title_tspans}</text>
      <path d="M690 142h116M690 174h88M690 206h132" stroke="#{primary}" stroke-width="14" stroke-linecap="round" opacity="0.22"/>
    </svg>
  SVG
  normalize_utf8(svg)
end

def keyword_score(items)
  scores = Hash.new(0)
  items.each do |item|
    "#{item[:title]} #{item[:description]}".downcase.scan(/[a-z][a-z-]{3,}/).each do |word|
      normalized = word.delete_prefix("-").delete_suffix("-")
      next if STOPWORDS.include?(normalized)

      scores[normalized] += 1
    end
  end
  scores.sort_by { |_, score| -score }.first(10).map(&:first)
end

def build_local_media_summary(items)
  by_source = items.group_by { |item| item[:source_name] }.transform_values(&:length)
  top_items = items.first(8)
  keywords = keyword_score(items)

  {
    headline: items.empty? ? "暂未抓取到符合时间范围的报道" : "已抓取 #{items.length} 条报道，覆盖 #{by_source.length} 个媒体源",
    bullets: top_items.map { |item| "#{item[:source_name]}：#{item[:title]}" },
    keywords: keywords,
    source_counts: by_source
  }
end

def build_translation_prompt(items)
  payload = items.map do |item|
    {
      id: item[:id],
      title: item[:title],
      description: item[:description]
    }
  end

  <<~PROMPT
    请把下面新闻 RSS 条目的非中文标题和摘要翻译成自然、准确、简洁的简体中文。
    只返回 JSON，不要添加解释。

    输出结构必须是：
    {
      "items": [
        { "id": "原 id", "title_zh": "中文标题", "description_zh": "中文摘要" }
      ]
    }

    要求：
    - 保留人名、机构名、地名的常见中文译名；没有常见译名时保留原文。
    - 不要补充 RSS 中没有的信息。
    - 已经是中文的内容可以原样返回。

    条目：
    #{JSON.generate(payload)}
  PROMPT
end

def call_deepseek_translation(api_key, model, items)
  uri = URI("https://api.deepseek.com/chat/completions")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 15
  http.read_timeout = MEDIA_AI_TIMEOUT_SECONDS
  http.write_timeout = 30 if http.respond_to?(:write_timeout=)

  payload = {
    model: model,
    messages: [
      { role: "system", content: "You are a careful Chinese news translator. Return JSON only." },
      { role: "user", content: build_translation_prompt(items) }
    ],
    response_format: { type: "json_object" },
    temperature: 0.1,
    max_tokens: 2600
  }

  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Bearer #{api_key}"
  req["Content-Type"] = "application/json"
  req.body = JSON.generate(payload)

  response = http.request(req)
  body = JSON.parse(response.body)
  unless response.is_a?(Net::HTTPSuccess)
    raise(body.dig("error", "message") || body["message"] || "DeepSeek translation failed")
  end

  parse_json_content(body.dig("choices", 0, "message", "content"))
end

def apply_translation_batch!(batch, translated)
  by_id = Array(translated["items"]).each_with_object({}) do |item, map|
    map[item["id"].to_s] = item
  end

  batch.each do |item|
    translated_item = by_id[item[:id]]
    next unless translated_item

    item[:title] = translated_item["title_zh"].to_s.strip unless translated_item["title_zh"].to_s.strip.empty?
    item[:description] = translated_item["description_zh"].to_s.strip unless translated_item["description_zh"].to_s.strip.empty?
    item[:translated] = true
  end
end

def translate_digest_items!(digest, api_key, model)
  return if api_key.empty?

  digest[:warnings] ||= []
  candidates = digest[:items].select do |item|
    !mostly_chinese?("#{item[:title]} #{item[:description]}")
  end
  digest[:translation_candidates_count] = candidates.length
  return if candidates.empty?

  candidates = candidates.first(MEDIA_TRANSLATION_ITEM_LIMIT)

  deadline = Time.now + MEDIA_TRANSLATION_BUDGET_SECONDS
  candidates.each_slice(6) do |batch|
    if Time.now > deadline
      digest[:warnings] << "自动翻译用时较长，已停止继续翻译并保留剩余原文。"
      break
    end

    begin
      apply_translation_batch!(batch, call_deepseek_translation(api_key, model, batch))
    rescue StandardError => e
      digest[:warnings] << "部分非中文内容未能自动翻译：#{friendly_error(e.message)}"
    end
  end
end

def translation_candidates(digest)
  digest[:items].select do |item|
    !mostly_chinese?("#{item[:title]} #{item[:description]}")
  end.first(MEDIA_TRANSLATION_ITEM_LIMIT)
end

def update_digest_translation_state!(digest, enabled:)
  candidates = translation_candidates(digest)
  digest[:translation_total_count] ||= candidates.length
  digest[:translation] = {
    enabled: enabled,
    candidate_count: digest[:translation_total_count],
    translated_count: digest[:items].count { |item| item[:translated] }
  }
  digest[:summary] = build_local_media_summary(digest[:items])
  digest
end

def digest_job_snapshot(job_id)
  DIGEST_JOBS_MUTEX.synchronize do
    job = DIGEST_JOBS[job_id]
    return nil unless job

    Marshal.load(Marshal.dump(job[:digest]))
  end
end

def store_digest_job!(digest)
  job_id = SecureRandom.hex(10)
  digest[:job_id] = job_id
  digest[:job_status] = "queued"
  DIGEST_JOBS_MUTEX.synchronize do
    DIGEST_JOBS[job_id] = { digest: digest, updated_at: Time.now }
  end
  job_id
end

def mutate_digest_job!(job_id)
  DIGEST_JOBS_MUTEX.synchronize do
    job = DIGEST_JOBS[job_id]
    return unless job

    yield job[:digest]
    job[:updated_at] = Time.now
  end
end

def start_digest_job!(job_id, api_key, model)
  Thread.new do
    begin
      snapshot = digest_job_snapshot(job_id)
      candidates = translation_candidates(snapshot)
      mutate_digest_job!(job_id) do |digest|
        digest[:job_status] = candidates.empty? ? "summarizing" : "translating"
        digest[:warnings] ||= []
        update_digest_translation_state!(digest, enabled: true)
      end

      candidates.each do |item_snapshot|
        begin
          translated = call_deepseek_translation(api_key, model, [item_snapshot])
          mutate_digest_job!(job_id) do |digest|
            item = digest[:items].find { |candidate| candidate[:id] == item_snapshot[:id] }
            apply_translation_batch!([item], translated) if item
            update_digest_translation_state!(digest, enabled: true)
          end
        rescue StandardError => e
          mutate_digest_job!(job_id) do |digest|
            digest[:warnings] ||= []
            digest[:warnings] << "一条新闻未能自动翻译：#{friendly_error(e.message)}"
            update_digest_translation_state!(digest, enabled: true)
          end
        end
      end

      mutate_digest_job!(job_id) { |digest| digest[:job_status] = "summarizing" }
      begin
        summary = call_deepseek_media_summary(api_key, model, digest_job_snapshot(job_id))
        mutate_digest_job!(job_id) do |digest|
          digest[:ai_summary] = summary if summary
          digest[:job_status] = "complete"
        end
      rescue StandardError => e
        mutate_digest_job!(job_id) do |digest|
          digest[:warnings] ||= []
          digest[:warnings] << "中文简报未能生成：#{friendly_error(e.message)}"
          digest[:job_status] = "complete"
        end
      end
    rescue StandardError => e
      mutate_digest_job!(job_id) do |digest|
        digest[:warnings] ||= []
        digest[:warnings] << "后台处理失败：#{friendly_error(e.message)}"
        digest[:job_status] = "failed"
      end
    end
  end
end

def build_media_prompt(digest)
  items = digest[:items].first(80).map.with_index do |item, index|
    <<~TEXT
      #{index + 1}. [#{item[:source_name]}] #{item[:title]}
      时间：#{item[:published_label]}
      摘要：#{item[:description]}
      链接：#{item[:url]}
    TEXT
  end.join("\n")

  <<~PROMPT
    你是一个谨慎的新闻编辑。请只基于下面 RSS 抓取到的标题和摘要，生成中文 JSON，不要编造事实。

    输出结构：
    {
      "editor_brief": "150-220 字中文总览",
      "key_developments": ["3 到 6 条关键进展"],
      "watchlist": ["后续值得关注的 2 到 5 个问题"],
      "source_notes": ["关于媒体覆盖角度或信息缺口的观察"]
    }

    抓取窗口：最近 #{digest[:window_hours]} 小时
    报道列表：
    #{items}
  PROMPT
end

def call_deepseek_media_summary(api_key, model, digest)
  return nil if api_key.empty? || digest[:items].empty?

  uri = URI("https://api.deepseek.com/chat/completions")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 15
  http.read_timeout = MEDIA_AI_TIMEOUT_SECONDS
  http.write_timeout = 30 if http.respond_to?(:write_timeout=)

  payload = {
    model: model,
    messages: [
      { role: "system", content: "You summarize news feeds carefully. Return JSON only." },
      { role: "user", content: build_media_prompt(digest) }
    ],
    response_format: { type: "json_object" },
    temperature: 0.2,
    max_tokens: 2200
  }

  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Bearer #{api_key}"
  req["Content-Type"] = "application/json"
  req.body = JSON.generate(payload)

  response = http.request(req)
  body = JSON.parse(response.body)
  unless response.is_a?(Net::HTTPSuccess)
    raise(body.dig("error", "message") || body["message"] || "DeepSeek request failed")
  end

  parse_json_content(body.dig("choices", 0, "message", "content"))
end

def extract_article_content(url)
  html = normalize_utf8(http_get(url))
  title = plain_text(html[/<h1\b[^>]*>(.*?)<\/h1>/im, 1])
  title = plain_text(html[/<title\b[^>]*>(.*?)<\/title>/im, 1]) if title.empty?
  cleaned = html
    .gsub(%r{<script\b.*?</script>}im, " ")
    .gsub(%r{<style\b.*?</style>}im, " ")
    .gsub(%r{<noscript\b.*?</noscript>}im, " ")
  paragraphs = cleaned.scan(%r{<p\b[^>]*>(.*?)</p>}im).flatten.map { |part| plain_text(part) }
  paragraphs = paragraphs.select { |part| part.length >= 40 }.uniq.first(28)
  body = paragraphs.join("\n\n")
  body = plain_text(cleaned)[0, 6_000] if body.empty?

  {
    title: title.empty? ? url : title,
    paragraphs: paragraphs,
    body: body[0, 12_000],
    url: url
  }
end

def call_deepseek_article_translation(api_key, model, article)
  uri = URI("https://api.deepseek.com/chat/completions")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 15
  http.read_timeout = MEDIA_AI_TIMEOUT_SECONDS
  http.write_timeout = 30 if http.respond_to?(:write_timeout=)

  prompt = <<~PROMPT
    请把下面新闻网页内容翻译成简体中文，并整理成适合阅读的中文稿。
    只基于原文，不要补充未出现的信息。返回 JSON。

    输出结构：
    {
      "title_zh": "中文标题",
      "summary_zh": "80-140 字中文摘要",
      "body_zh": ["按段落翻译的中文正文"]
    }

    原文标题：#{article[:title]}
    原文链接：#{article[:url]}
    原文正文：
    #{article[:body]}
  PROMPT

  payload = {
    model: model,
    messages: [
      { role: "system", content: "You are a careful Chinese news translator. Return JSON only." },
      { role: "user", content: prompt }
    ],
    response_format: { type: "json_object" },
    temperature: 0.1,
    max_tokens: 5000
  }

  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Bearer #{api_key}"
  req["Content-Type"] = "application/json"
  req.body = JSON.generate(payload)

  response = http.request(req)
  body = JSON.parse(response.body)
  unless response.is_a?(Net::HTTPSuccess)
    raise(body.dig("error", "message") || body["message"] || "DeepSeek article translation failed")
  end

  parse_json_content(body.dig("choices", 0, "message", "content"))
end

def article_job_snapshot(job_id)
  ARTICLE_JOBS_MUTEX.synchronize do
    job = ARTICLE_JOBS[job_id]
    return nil unless job

    Marshal.load(Marshal.dump(job))
  end
end

def mutate_article_job!(job_id)
  ARTICLE_JOBS_MUTEX.synchronize do
    job = ARTICLE_JOBS[job_id]
    return unless job

    yield job
    job[:updated_at] = Time.now.iso8601
  end
end

def start_article_job!(url:, title:, api_key:, model:)
  job_id = SecureRandom.hex(10)
  ARTICLE_JOBS_MUTEX.synchronize do
    ARTICLE_JOBS[job_id] = {
      id: job_id,
      status: "queued",
      url: url,
      title: title,
      created_at: Time.now.iso8601,
      updated_at: Time.now.iso8601
    }
  end

  Thread.new do
    begin
      mutate_article_job!(job_id) { |job| job[:status] = "fetching" }
      article = extract_article_content(url)
      article[:title] = title unless title.to_s.strip.empty?
      mutate_article_job!(job_id) do |job|
        job[:status] = "translating"
        job[:source_title] = article[:title]
        job[:source_paragraphs] = article[:paragraphs]
        job[:source_excerpt] = article[:body].to_s[0, 420]
      end
      translated = call_deepseek_article_translation(api_key, model, article)
      mutate_article_job!(job_id) do |job|
        job[:status] = "complete"
        job[:title_zh] = translated["title_zh"].to_s
        job[:summary_zh] = translated["summary_zh"].to_s
        job[:body_zh] = Array(translated["body_zh"]).map(&:to_s)
        job[:source_paragraphs] = article[:paragraphs]
      end
    rescue StandardError => e
      mutate_article_job!(job_id) do |job|
        job[:status] = "failed"
        job[:error] = friendly_error(e.message)
      end
    end
  end

  job_id
end

def build_prompt(files)
  filenames = files.map { |file| file[:filename] }.join(", ")
  comparison_rules =
    if files.length > 1
      <<~TEXT
        Also generate a comparison object across the uploaded documents:
        - available: true
        - shared_topics: the overlapping research questions, themes, or concerns
        - key_differences: the main disagreements or different emphases
        - method_comparison: contrasts in theory, method, evidence, or dataset
        - reference_overlap: duplicated or closely related cited works across documents, if visible
        - synthesis: a concise Chinese synthesis of how these papers relate to each other
      TEXT
    else
      <<~TEXT
        Since only one document is provided, set:
        - available: false
        - shared_topics, key_differences, method_comparison, reference_overlap: empty arrays
        - synthesis: a short Chinese sentence stating that cross-paper comparison is unavailable with a single file
      TEXT
    end

  <<~PROMPT
    You are analyzing academic PDF documents. Return valid JSON only.

    Analyze these PDF files: #{filenames}

    For each document:
    1. Identify the paper title.
    2. Write a concise summary in Chinese of the paper's main thesis and contribution.
    3. Extract the main points as short bullet-like strings in Chinese.
    4. Reconstruct the argument process in Chinese. Each step should explain:
       - the claim or stage of the argument
       - how the author reasons from one stage to the next
       - what evidence, method, example, or data supports it
    5. Extract 3 to 8 core quotes from the paper. Keep them exact when possible, preferably short, and do not invent text. Explain in Chinese why each quote matters. Always include location_hint, and use an empty string if the location is unavailable.
    6. List every cited reference you can reliably identify from the bibliography / references section. Preserve the raw citation string, then normalize as much as possible into authors, year, title, source, details, and identifier.
    7. If some bibliography details are missing or unclear, keep the raw citation and mark completeness as partial or uncertain instead of guessing.

    #{comparison_rules}

    Important rules:
    - Output must follow this JSON shape exactly:
      {
        "documents": [
          {
            "filename": string,
            "document_title": string,
            "summary": string,
            "main_points": string[],
            "argument_process": [
              { "step": string, "reasoning": string, "evidence": string }
            ],
            "core_quotes": [
              { "quote": string, "why_it_matters": string, "location_hint": string }
            ],
            "references": [
              {
                "raw_citation": string,
                "authors": string,
                "year": string,
                "title": string,
                "source": string,
                "details": string,
                "identifier": string,
                "completeness": "complete" | "partial" | "uncertain"
              }
            ]
          }
        ],
        "comparison": {
          "available": boolean,
          "shared_topics": string[],
          "key_differences": string[],
          "method_comparison": string[],
          "reference_overlap": string[],
          "synthesis": string
        }
      }
    - The output language should be Chinese except for citation strings and quoted source text.
    - Do not fabricate references or quotes.
    - If multiple files are provided, return one object per file in the same order.
  PROMPT
end

def truncate_text(text)
  return text if text.length <= MAX_CHARS_PER_FILE

  head_length = (MAX_CHARS_PER_FILE * 0.58).to_i
  tail_length = MAX_CHARS_PER_FILE - head_length
  [
    text[0, head_length],
    "\n\n[中间部分因篇幅较长已省略；请重点结合开头理论框架与末尾参考文献分析。]\n\n",
    text[-tail_length, tail_length]
  ].join
end

def extract_pdf_text(file)
  Tempfile.create(["paper-digest", ".pdf"]) do |tmp|
    tmp.binmode
    tmp.write(file[:data])
    tmp.flush

    stdout, stderr, status = Open3.capture3(PYTHON_BIN, PDF_EXTRACTOR.to_s, tmp.path)
    unless status.success?
      raise "PDF text extraction failed: #{stderr}"
    end

    payload = JSON.parse(stdout)
    text = payload["text"].to_s.strip
    raise "PDF text extraction failed: no extractable text" if text.empty?

    file.merge(
      title_hint: normalize_utf8(payload["title"]),
      page_count: payload["page_count"].to_i,
      text: truncate_text(text)
    )
  end
end

def build_deepseek_user_content(files)
  parts = [build_prompt(files), ""]
  files.each_with_index do |file, index|
    parts << <<~TEXT
      ===== Document #{index + 1} =====
      Filename: #{file[:filename]}
      PDF metadata title: #{file[:title_hint]}
      Page count: #{file[:page_count]}

      Extracted text:
      #{file[:text]}
    TEXT
  end
  parts.join("\n")
end

def parse_json_content(content)
  text = content.to_s.strip
  text = text.sub(/\A```(?:json)?\s*/i, "").sub(/\s*```\z/, "").strip
  first_brace = text.index("{")
  last_brace = text.rindex("}")
  text = text[first_brace..last_brace] if first_brace && last_brace && last_brace > first_brace

  JSON.parse(text)
rescue JSON::ParserError
  repaired = text
    .gsub(/}\s*{/m, "},{")
    .gsub(/]\s*,\s*}/m, "]}")
    .gsub(/,\s*\]/m, "]")
  JSON.parse(repaired)
end

def call_deepseek(api_key, model, files)
  uri = URI("https://api.deepseek.com/chat/completions")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 30
  http.read_timeout = DEEPSEEK_TIMEOUT_SECONDS
  http.write_timeout = 60 if http.respond_to?(:write_timeout=)

  payload = {
    model: model,
    messages: [
      {
        role: "system",
        content: "You are a careful academic research assistant. Return JSON only. Do not invent citations or quotes."
      },
      {
        role: "user",
        content: build_deepseek_user_content(files)
      }
    ],
    response_format: { type: "json_object" },
    temperature: 0.2,
    max_tokens: 8192
  }

  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Bearer #{api_key}"
  req["Content-Type"] = "application/json"
  req.body = JSON.generate(payload)

  response = http.request(req)
  body = JSON.parse(response.body)

  unless response.is_a?(Net::HTTPSuccess)
    error_message =
      body.dig("error", "message") ||
      body["message"] ||
      "DeepSeek request failed with status #{response.code}"
    raise error_message
  end

  output_text = body.dig("choices", 0, "message", "content")
  raise "DeepSeek response did not include JSON output." if output_text.to_s.strip.empty?

  parse_json_content(output_text)
end

class AppServlet < WEBrick::HTTPServlet::AbstractServlet
  def do_GET(req, res)
    return unless require_authorization(req, res)

    if req.path == "/health"
      json_response(res, 200, { ok: true, model: DEFAULT_MODEL, app: "media-digest" })
      return
    end

    if req.path == "/api/sources"
      json_response(res, 200, { sources: DEFAULT_MEDIA_SOURCES })
      return
    end

    if req.path.start_with?("/api/digest/jobs/")
      job_id = req.path.split("/").last.to_s
      digest = digest_job_snapshot(job_id)
      unless digest
        json_response(res, 404, { error: "没有找到这个后台处理任务。" })
        return
      end

      json_response(res, 200, digest)
      return
    end

    if req.path.start_with?("/api/article/jobs/")
      job_id = req.path.split("/").last.to_s
      job = article_job_snapshot(job_id)
      unless job
        json_response(res, 404, { error: "没有找到这个中文阅读任务。" })
        return
      end

      json_response(res, 200, job)
      return
    end

    if req.path.match?(%r{\A/api/company-workflow/jobs/[^/]+\z})
      job_id = req.path.split("/").last.to_s
      job = company_job_snapshot(job_id)
      unless job
        json_response(res, 404, { error: "没有找到这个企业查询任务。" })
        return
      end

      payload = job[:mode].to_s == "manual" ? manual_company_job_payload(job) : public_company_job(job)
      json_response(res, 200, payload)
      return
    end

    if req.path.match?(%r{\A/api/company-workflow/jobs/[^/]+/download/(results\.(xlsx|csv))\z})
      parts = req.path.split("/")
      job_id = parts[4].to_s
      filename = parts.last.to_s
      job = company_job_snapshot(job_id)
      unless job
        res.status = 404
        res.body = "Not found"
        return
      end

      file_path = Pathname.new(job[:output_dir].to_s).join(filename).cleanpath
      unless file_path.file? && file_path.to_s.start_with?(Pathname.new(job[:output_dir].to_s).cleanpath.to_s)
        res.status = 404
        res.body = "Not found"
        return
      end

      res.status = 200
      res["Content-Type"] = filename.end_with?(".xlsx") ? "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" : "text/csv; charset=utf-8"
      res["Content-Disposition"] = "attachment; filename=\"#{filename}\""
      res.body = file_path.binread
      return
    end

    if req.path == "/api/generated-image"
      res.status = 200
      res["Content-Type"] = "image/svg+xml; charset=utf-8"
      res["Cache-Control"] = "public, max-age=86400"
      res.body = generated_image_svg(
        title: req.query["title"].to_s,
        source: req.query["source"].to_s,
        region: req.query["region"].to_s
      )
      return
    end

    if req.path == "/company-list-template.xlsx"
      template_path = COMPANY_WORKFLOW_DIR.join("company_list_template.xlsx")
      unless template_path.file?
        res.status = 404
        res.body = "Not found"
        return
      end

      res.status = 200
      res["Content-Type"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      res["Content-Disposition"] = 'attachment; filename="company_list_template.xlsx"'
      res.body = template_path.binread
      return
    end

    path = req.path == "/" ? "/index.html" : req.path
    full_path = PUBLIC_DIR.join(path.delete_prefix("/")).cleanpath

    unless full_path.file? && full_path.to_s.start_with?(PUBLIC_DIR.to_s)
      res.status = 404
      res.body = "Not found"
      return
    end

    res.status = 200
    res["Content-Type"] = WEBrick::HTTPUtils.mime_type(full_path.extname, WEBrick::HTTPUtils::DefaultMimeTypes)
    res.body = full_path.binread
  end

  def do_POST(req, res)
    return unless require_authorization(req, res)

    if req.path == "/api/article/translate"
      payload = req.body.to_s.strip.empty? ? {} : JSON.parse(req.body)
      url = payload["url"].to_s.strip
      if url.empty?
        json_response(res, 400, { error: "缺少原文链接。" })
        return
      end

      api_key = load_api_key(req)
      if api_key.empty?
        json_response(res, 400, { error: "需要填写 DeepSeek API Key 才能翻译网页全文。" })
        return
      end

      job_id = start_article_job!(
        url: url,
        title: payload["title"].to_s,
        api_key: api_key,
        model: load_model(req)
      )
      json_response(res, 200, { job_id: job_id, url: "/article.html?job=#{job_id}" })
      return
    end

    if req.path == "/api/digest"
      payload = req.body.to_s.strip.empty? ? {} : JSON.parse(req.body)
      digest = fetch_media_digest(
        source_ids: Array(payload["source_ids"]).map(&:to_s),
        hours: payload.fetch("hours", 24).to_i,
        custom_sources: payload["custom_sources"]
      )
      api_key = load_api_key(req)
      model = load_model(req)
      update_digest_translation_state!(digest, enabled: !api_key.empty?)

      unless api_key.empty?
        job_id = store_digest_job!(digest)
        start_digest_job!(job_id, api_key, model)
      end

      json_response(res, 200, digest)
      return
    end

    if req.path == "/api/company-workflow"
      uploaded = uploaded_company_file(req)
      unless uploaded&.respond_to?(:filename) && uploaded.filename.to_s.strip != ""
        json_response(res, 400, { error: "请上传一个 Excel 或 CSV 公司名单。" })
        return
      end

      filename = normalize_utf8(uploaded.filename)
      job_id = start_company_workflow_job!(filename: filename, data: uploaded.to_s)
      json_response(res, 200, public_company_job(company_job_snapshot(job_id)))
      return
    end

    if req.path == "/api/company-workflow/manual"
      uploaded = uploaded_company_file(req)
      unless uploaded&.respond_to?(:filename) && uploaded.filename.to_s.strip != ""
        json_response(res, 400, { error: "请上传一个 Excel 或 CSV 公司名单。" })
        return
      end

      filename = normalize_utf8(uploaded.filename)
      job_id = start_manual_company_job!(filename: filename, data: uploaded.to_s)
      json_response(res, 200, manual_company_job_payload(company_job_snapshot(job_id)))
      return
    end

    if req.path.match?(%r{\A/api/company-workflow/manual/jobs/[^/]+/capture\z})
      job_id = req.path.split("/")[-2].to_s
      row = capture_manual_company_page!(job_id, req.query)
      res.status = 200
      res["Content-Type"] = "text/html; charset=utf-8"
      res.body = <<~HTML
        <!doctype html>
        <meta charset="utf-8">
        <title>采集成功</title>
        <body style="font:16px -apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif;padding:28px;line-height:1.7;">
          <h1 style="font-size:22px;">采集成功</h1>
          <p>已采集：#{CGI.escapeHTML(row[:company_full_name].empty? ? row[:input_company_name] : row[:company_full_name])}</p>
          <p>可以关闭这个页面，继续在公示系统打开下一家公司详情页后再次点击采集书签。</p>
        </body>
      HTML
      return
    end

    if req.path.match?(%r{\A/api/company-workflow/jobs/[^/]+/continue\z})
      job_id = req.path.split("/")[-2].to_s
      continue_company_workflow!(job_id)
      json_response(res, 200, public_company_job(company_job_snapshot(job_id)))
      return
    end

    unless req.path == "/analyze"
      res.status = 404
      res.body = "Not found"
      return
    end

    api_key = load_api_key(req)
    model = load_model(req)
    if api_key.empty?
      json_response(res, 400, { error: "缺少 DeepSeek API Key。请先在环境变量中设置 DEEPSEEK_API_KEY，或在页面中填写。" })
      return
    end

    uploaded = req.query["papers"]
    uploaded_items =
      if uploaded.respond_to?(:each_data)
        items = []
        uploaded.each_data { |entry| items << entry }
        items
      elsif uploaded.nil?
        []
      else
        [uploaded]
      end

    files = uploaded_items.map do |item|
      next unless item.respond_to?(:filename)
      next if item.filename.to_s.strip.empty?

      {
        filename: normalize_utf8(item.filename),
        data: item.to_s
      }
    end.compact

    if files.empty?
      json_response(res, 400, { error: "请至少上传一个 PDF 文件。" })
      return
    end

    unless files.all? { |file| File.extname(file[:filename]).downcase == ".pdf" }
      json_response(res, 400, { error: "当前仅支持 PDF 文件。" })
      return
    end

    total_size = files.sum { |file| file[:data].bytesize }
    if total_size > MAX_TOTAL_UPLOAD_BYTES
      json_response(res, 400, { error: "单次上传总大小不能超过 50MB。请分批分析。" })
      return
    end

    extracted_files = files.map { |file| extract_pdf_text(file) }
    result = call_deepseek(api_key, model, extracted_files)
    json_response(res, 200, result)
  rescue StandardError => e
    json_response(res, 500, { error: friendly_error(e.message) })
  end
end

if $PROGRAM_NAME == __FILE__
  server = WEBrick::HTTPServer.new(
    Port: ENV.fetch("PORT", "4567").to_i,
    BindAddress: BIND_ADDRESS,
    AccessLog: [],
    Logger: WEBrick::Log.new($stderr, WEBrick::Log::INFO)
  )

  server.mount "/", AppServlet
  trap("INT") { server.shutdown }

  puts "Media digest running at http://#{server.config[:BindAddress]}:#{server.config[:Port]}"
  server.start
end
