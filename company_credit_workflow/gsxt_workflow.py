#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
import time
import uuid
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable

import pandas as pd
from pypdf import PdfReader


ROOT = Path(__file__).resolve().parent
DEFAULT_OUTPUT = ROOT / "output"
GSXT_URLS = [
    "https://www.gsxt.gov.cn/",
    "https://bt.gsxt.gov.cn/",
]


@dataclass
class CompanyInput:
    company_name: str
    credit_code: str = ""


@dataclass
class CompanyResult:
    input_company_name: str
    input_credit_code: str
    company_full_name: str = ""
    address: str = ""
    unified_social_credit_code: str = ""
    legal_representative: str = ""
    phones: str = ""
    phone_source: str = ""
    pdf_path: str = ""
    detail_url: str = ""
    status: str = "pending"
    failure_reason: str = ""
    queried_at: str = ""


def safe_filename(value: str, max_len: int = 90) -> str:
    value = re.sub(r"[\\/:*?\"<>|\r\n\t]+", "_", value).strip(" .")
    return (value[:max_len] or "未命名企业")


def clean_cell(value: object) -> str:
    if value is None or pd.isna(value):
        return ""
    return str(value).strip()


def read_company_inputs(path: Path) -> list[CompanyInput]:
    if not path.exists():
        raise FileNotFoundError(f"找不到名单文件: {path}")

    if path.suffix.lower() in {".xlsx", ".xlsm", ".xls"}:
        df = pd.read_excel(path, dtype=str).fillna("")
    elif path.suffix.lower() == ".csv":
        df = pd.read_csv(path, dtype=str).fillna("")
    else:
        raise ValueError("名单文件只支持 .xlsx/.xls/.csv")

    normalized = {str(col).strip(): col for col in df.columns}
    name_col = None
    code_col = None
    for candidate in ["公司名称", "企业名称", "名称", "company_name", "name"]:
        if candidate in normalized:
            name_col = normalized[candidate]
            break
    for candidate in ["统一社会信用代码", "信用代码", "统一信用代码", "credit_code", "code"]:
        if candidate in normalized:
            code_col = normalized[candidate]
            break
    if name_col is None:
        raise ValueError("名单中需要有一列叫“公司名称”或“企业名称”。")

    inputs: list[CompanyInput] = []
    for _, row in df.iterrows():
        name = clean_cell(row.get(name_col))
        if not name:
            continue
        code = clean_cell(row.get(code_col)) if code_col else ""
        inputs.append(CompanyInput(name, code))
    return inputs


def compact_text(text: str) -> str:
    text = text.replace("\u3000", " ")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def extract_value(text: str, labels: Iterable[str], stop_labels: Iterable[str]) -> str:
    stop = "|".join(re.escape(label) for label in stop_labels)
    for label in labels:
        pattern = rf"{re.escape(label)}\s*[:：]?\s*(.+?)(?=\s*(?:{stop})\s*[:：]?|\n|$)"
        match = re.search(pattern, text, flags=re.S)
        if match:
            value = re.sub(r"\s+", " ", match.group(1)).strip(" ：:")
            if value and value not in {"-", "暂无", "无"}:
                return value
    return ""


def extract_fields_from_text(raw_text: str) -> dict[str, str]:
    text = compact_text(raw_text)
    stop_labels = [
        "统一社会信用代码",
        "注册号",
        "名称",
        "企业名称",
        "类型",
        "法定代表人",
        "负责人",
        "经营者",
        "住所",
        "主要经营场所",
        "经营场所",
        "注册资本",
        "成立日期",
        "营业期限",
        "经营范围",
        "登记机关",
        "核准日期",
        "联系电话",
        "企业联系电话",
        "通信地址",
        "邮政编码",
    ]

    credit_code = ""
    code_match = re.search(r"\b[0-9A-Z]{18}\b", text)
    if code_match:
        credit_code = code_match.group(0)

    phones = extract_phones(text)
    return {
        "company_full_name": extract_value(text, ["名称", "企业名称", "公司名称"], stop_labels),
        "address": extract_value(text, ["住所", "主要经营场所", "经营场所", "通信地址"], stop_labels),
        "unified_social_credit_code": credit_code
        or extract_value(text, ["统一社会信用代码", "统一社会信用代码/注册号"], stop_labels),
        "legal_representative": extract_value(text, ["法定代表人", "负责人", "经营者"], stop_labels),
        "phones": "; ".join(phones),
        "phone_source": "页面/PDF公开文本" if phones else "",
    }


def extract_phones(text: str) -> list[str]:
    normalized = text.replace("（", "(").replace("）", ")")
    labeled_chunks = []
    for label in ["联系电话", "企业联系电话", "电话", "手机", "联系方式"]:
        for match in re.finditer(rf"{label}\s*[:：]?\s*([0-9+\-()（）\s]{{6,30}})", normalized):
            labeled_chunks.append(match.group(1))

    candidates = []
    source_text = "\n".join(labeled_chunks) if labeled_chunks else normalized
    phone_pattern = re.compile(
        r"(?<!\d)(?:1[3-9]\d{9}|0\d{2,3}[ -]?\d{7,8}(?:-\d{1,6})?|\d{3,4}[ -]\d{7,8})(?!\d)"
    )
    for match in phone_pattern.finditer(source_text):
        phone = re.sub(r"\s+", "", match.group(0))
        if phone not in candidates:
            candidates.append(phone)
    return candidates


def read_pdf_text(path: Path) -> str:
    try:
        reader = PdfReader(str(path))
        return "\n".join(page.extract_text() or "" for page in reader.pages)
    except Exception:
        return ""


def merge_extracted(result: CompanyResult, extracted: dict[str, str]) -> None:
    for field_name, value in extracted.items():
        if value and not getattr(result, field_name):
            setattr(result, field_name, value)


def append_jsonl(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False) + "\n")


def mark_running(checkpoint_file: str | None, message: str) -> None:
    write_checkpoint(checkpoint_file, {
        "state": "running",
        "message": message,
        "updated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    })


def save_results(results: list[CompanyResult], output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    xlsx_path = output_dir / "results.xlsx"
    csv_path = output_dir / "results.csv"
    rows = [asdict(item) for item in results]
    df = pd.DataFrame(rows)
    df.to_excel(xlsx_path, index=False)
    df.to_csv(csv_path, index=False, encoding="utf-8-sig")


def write_checkpoint(path: str | None, payload: dict[str, str]) -> None:
    if not path:
        return
    checkpoint_path = Path(path)
    checkpoint_path.parent.mkdir(parents=True, exist_ok=True)
    checkpoint_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")


def read_checkpoint_state(path: str | None) -> str:
    if not path:
        return ""
    try:
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
        return payload.get("state", "")
    except Exception:
        return ""


def user_checkpoint(message: str, auto_continue: bool, checkpoint_file: str | None = None) -> None:
    if auto_continue:
        return
    if checkpoint_file:
        token = uuid.uuid4().hex
        write_checkpoint(checkpoint_file, {
            "state": "waiting",
            "message": message,
            "token": token,
            "updated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        })
        print(f"\n{message}")
        print("等待网页端点击继续...")
        while read_checkpoint_state(checkpoint_file) != "continue":
            time.sleep(1)
        write_checkpoint(checkpoint_file, {
            "state": "running",
            "message": "继续查询中",
            "token": token,
            "updated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        })
        return
    print("\n" + message)
    input("处理完成后按回车继续...")


async def import_playwright():
    try:
        from playwright.async_api import async_playwright, TimeoutError as PlaywrightTimeoutError
    except ModuleNotFoundError:
        print("缺少 Playwright。请先运行: ./company_credit_workflow/setup.sh", file=sys.stderr)
        raise
    return async_playwright, PlaywrightTimeoutError


async def click_first_visible(page, selectors: list[str], timeout: int = 1500) -> bool:
    for selector in selectors:
        try:
            locator = page.locator(selector).first
            await locator.wait_for(state="visible", timeout=timeout)
            await locator.click(timeout=timeout)
            return True
        except Exception:
            continue
    return False


async def fill_search_box(page, query: str) -> bool:
    try:
        title = await page.title()
        if "Environment Checking" in title:
            return False
    except Exception:
        pass
    selectors = [
        "input[placeholder*='企业名称']",
        "input[placeholder*='统一社会信用代码']",
        "input[type='text']",
        "textarea",
    ]
    for selector in selectors:
        try:
            locator = page.locator(selector).first
            await locator.wait_for(state="visible", timeout=3000)
            await locator.fill(query)
            return True
        except Exception:
            continue
    return False


async def click_search(page) -> bool:
    return await click_first_visible(
        page,
        [
            "button:has-text('查询')",
            "input[value='查询']",
            "text=查询",
            ".search-btn",
            "#search",
        ],
        timeout=2500,
    )


async def open_gsxt_home(page) -> None:
    last_error = None
    for url in GSXT_URLS:
        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=45000)
            await page.wait_for_timeout(2500)
            return
        except Exception as exc:
            last_error = exc
    raise RuntimeError(f"无法打开公示系统首页: {last_error}")


async def page_handoff_hint(page) -> str:
    try:
        title = await page.title()
        current_url = page.url
        if "Environment Checking" in title:
            return "公示系统停在环境检测页，自动化浏览器可能被网站拦截。请先尝试刷新；如果仍空白，需要改用普通浏览器人工查询或提供已下载的PDF。"
        if current_url.startswith("chrome://"):
            return "自动化浏览器仍停在空白新标签页，没有成功打开公示系统。"
    except Exception:
        pass
    return "没有找到搜索框。请在浏览器中手动输入并查询。"


async def maybe_wait_for_human(page, auto_continue: bool, checkpoint_file: str | None = None) -> None:
    text = ""
    try:
        text = await page.locator("body").inner_text(timeout=3000)
    except Exception:
        pass
    keywords = ["验证码", "拖动", "滑块", "登录", "实名", "安全验证", "请完成验证"]
    if any(keyword in text for keyword in keywords):
        user_checkpoint(
            "页面看起来需要登录、实名认证或人机验证。请在浏览器中完成当前步骤。",
            auto_continue,
            checkpoint_file,
        )


async def choose_company_result(page, item: CompanyInput, auto_continue: bool, checkpoint_file: str | None = None) -> None:
    await page.wait_for_timeout(3000)
    await maybe_wait_for_human(page, auto_continue, checkpoint_file)
    target_texts = [item.credit_code, item.company_name] if item.credit_code else [item.company_name]

    for text in target_texts:
        if not text:
            continue
        try:
            locator = page.get_by_text(text, exact=False).first
            await locator.wait_for(state="visible", timeout=5000)
            await locator.click(timeout=5000)
            await page.wait_for_load_state("domcontentloaded", timeout=15000)
            await page.wait_for_timeout(2500)
            return
        except Exception:
            continue

    user_checkpoint(
        f"没有自动确认“{item.company_name}”的结果。请在浏览器里点进正确企业详情页。",
        auto_continue,
        checkpoint_file,
    )


async def save_pdf(page, pdf_path: Path) -> str:
    pdf_path.parent.mkdir(parents=True, exist_ok=True)
    before_pages = page.context.pages

    clicked = await click_first_visible(
        page,
        [
            "text=下载报告",
            "text=发送报告",
            "text=信息打印",
            "text=打印",
            "text=报告",
            "button:has-text('打印')",
            "button:has-text('下载')",
        ],
        timeout=1200,
    )
    if clicked:
        await page.wait_for_timeout(2500)
        for candidate in page.context.pages:
            if candidate not in before_pages:
                try:
                    await candidate.pdf(path=str(pdf_path), format="A4", print_background=True)
                    await candidate.close()
                    return "browser_print_after_report_click"
                except Exception:
                    pass

    await page.pdf(path=str(pdf_path), format="A4", print_background=True)
    return "browser_print_current_page"


async def process_one(page, item: CompanyInput, output_dir: Path, auto_continue: bool, checkpoint_file: str | None = None) -> CompanyResult:
    result = CompanyResult(
        input_company_name=item.company_name,
        input_credit_code=item.credit_code,
        queried_at=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    )
    query = item.credit_code or item.company_name
    pdf_path = output_dir / "pdf" / f"{safe_filename(item.company_name)}.pdf"

    try:
        await open_gsxt_home(page)
        if not await fill_search_box(page, query):
            user_checkpoint(await page_handoff_hint(page), auto_continue, checkpoint_file)
        elif not await click_search(page):
            await page.keyboard.press("Enter")

        await choose_company_result(page, item, auto_continue, checkpoint_file)
        result.detail_url = page.url

        body_text = await page.locator("body").inner_text(timeout=10000)
        merge_extracted(result, extract_fields_from_text(body_text))

        pdf_mode = await save_pdf(page, pdf_path)
        result.pdf_path = str(pdf_path)
        pdf_text = read_pdf_text(pdf_path)
        if pdf_text:
            merge_extracted(result, extract_fields_from_text(pdf_text))

        if not result.company_full_name:
            result.company_full_name = item.company_name
        if not result.unified_social_credit_code and item.credit_code:
            result.unified_social_credit_code = item.credit_code

        result.status = "success"
        if pdf_mode == "browser_print_current_page":
            result.failure_reason = "未找到官网报告下载按钮，已保存当前详情页PDF。"
        return result
    except Exception as exc:
        result.status = "failed"
        result.failure_reason = str(exc)
        return result


async def run_workflow(args: argparse.Namespace) -> None:
    async_playwright, _ = await import_playwright()
    input_path = Path(args.input).expanduser().resolve()
    output_dir = Path(args.output).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    log_path = output_dir / "logs" / f"run-{datetime.now().strftime('%Y%m%d-%H%M%S')}.jsonl"

    companies = read_company_inputs(input_path)
    if not companies:
        raise ValueError("名单里没有可查询的公司。")

    results: list[CompanyResult] = []
    print(f"共读取 {len(companies)} 家公司。浏览器即将打开。")

    async with async_playwright() as p:
        browser_data = output_dir / "browser_profile"
        browser = await p.chromium.launch_persistent_context(
            str(browser_data),
            headless=False,
            accept_downloads=True,
            locale="zh-CN",
            viewport={"width": 1360, "height": 900},
        )
        page = browser.pages[0] if browser.pages else await browser.new_page()

        if not args.auto_continue:
            print("如果这是第一次使用，请先在打开的浏览器里登录/完成实名。")

        for index, item in enumerate(companies, start=1):
            print(f"\n[{index}/{len(companies)}] 查询: {item.company_name}")
            mark_running(args.checkpoint_file, f"[{index}/{len(companies)}] 正在查询：{item.company_name}")
            result = await process_one(page, item, output_dir, args.auto_continue, args.checkpoint_file)
            results.append(result)
            append_jsonl(log_path, asdict(result))
            save_results(results, output_dir)
            print(f"状态: {result.status}；PDF: {result.pdf_path or '未保存'}")
            mark_running(args.checkpoint_file, f"[{index}/{len(companies)}] {item.company_name}：{result.status}")
            if args.delay > 0:
                time.sleep(args.delay)

        await browser.close()

    save_results(results, output_dir)
    write_checkpoint(args.checkpoint_file, {
        "state": "done",
        "message": "查询完成",
        "updated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    })
    print(f"\n完成。汇总表: {output_dir / 'results.xlsx'}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="批量查询国家企业信用信息公示系统并保存PDF。")
    parser.add_argument("input", help="公司名单 .xlsx/.csv")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="输出目录")
    parser.add_argument("--delay", type=float, default=2.0, help="每家公司之间的等待秒数")
    parser.add_argument("--checkpoint-file", default="", help="网页端人工确认状态文件")
    parser.add_argument(
        "--auto-continue",
        action="store_true",
        help="不等待人工确认。仅适合确认账号状态稳定、无需验证码时使用。",
    )
    return parser.parse_args()


def main() -> None:
    import asyncio

    args = parse_args()
    asyncio.run(run_workflow(args))


if __name__ == "__main__":
    main()
