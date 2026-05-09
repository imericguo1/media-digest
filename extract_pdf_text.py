import json
import sys

from pypdf import PdfReader


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: extract_pdf_text.py <pdf-path>")

    reader = PdfReader(sys.argv[1])
    pages = []
    for index, page in enumerate(reader.pages, start=1):
        text = page.extract_text() or ""
        text = " ".join(text.split())
        if text:
            pages.append(f"[Page {index}]\n{text}")

    metadata = reader.metadata or {}
    title = getattr(metadata, "title", "") or ""
    payload = {
        "page_count": len(reader.pages),
        "title": title,
        "text": "\n\n".join(pages),
    }
    print(json.dumps(payload, ensure_ascii=False))


if __name__ == "__main__":
    main()
