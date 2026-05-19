#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import json
import re
from dataclasses import asdict, dataclass
from pathlib import Path

BLOCKING_SIZE_BYTES = 6 * 1024 * 1024
WARN_SIZE_BYTES = 4 * 1024 * 1024
SRCDOC_WARN_BYTES = 100 * 1024
CSS_WARN_BYTES = 300 * 1024    # 单文件 CSS 超过 300KB 发出警告
CSS_BLOCK_BYTES = 1024 * 1024  # 超过 1MB 则阻断

REPLACEMENT_CHAR = "�"
SRCDOC_PLACEHOLDER = 'srcdoc="__SINGLEFILE_SRCDOC__"'

# SVG/XML 命名空间 URI 是合法的标识符，不是可加载的外部资源
_SVG_NS = {"http://www.w3.org/2000/svg", "http://www.w3.org/1999/xlink"}

# 实际资源加载模式（src=、CSS url()、@import、<script src>、<link rel=stylesheet href>）
# 不包括 <a href>（导航链接，允许有外部 URL）
RESOURCE_LOAD_RE = re.compile(
    r"""(?:
        <(?:script|img|video|audio|source|embed|object|track)\s[^>]*src=["']?(https?://[^\s"'<>)\\]+)
      | <(?:link)\s[^>]*(?:rel=["']?(?:stylesheet|preload|prefetch|icon)["\']?)[^>]*href=["']?(https?://[^\s"'<>)\\]+)
      | <(?:link)\s[^>]*href=["']?(https?://[^\s"'<>)\\]+)[^>]*(?:rel=["']?(?:stylesheet|preload|prefetch|icon)["\']?)
      | url\(["']?(https?://[^\s"'<>)\\]+)["']?\)
      | @import\s+["']?(https?://[^\s"'<>)\\]+)["']?
    )""",
    flags=re.IGNORECASE | re.VERBOSE,
)

# CDN 简写（非 http/https 开头，如 //cdn.xxx）
CDN_RE = re.compile(
    r"//cdn\.|fonts\.googleapis\.com|unpkg\.com|cdnjs\.cloudflare\.com",
    flags=re.IGNORECASE,
)

ESCAPED_CSS_SYNTAX_RE = re.compile(
    r"content:\s*&quot;|format\(&quot;|url\(&quot;|style=&quot;|class=&quot;",
    flags=re.IGNORECASE,
)
BROKEN_CONTENT_RE = re.compile(
    r"content:\s*(?:&quot;|\"?)\s*" + REPLACEMENT_CHAR,
    flags=re.IGNORECASE,
)
BROKEN_FORMAT_RE = re.compile(r"format\(&quot;\s+\w+&quot;\s*\)", flags=re.IGNORECASE)
BROKEN_URL_RE = re.compile(r"url\(&quot;[^)]+&quot;\)", flags=re.IGNORECASE)
SRCDOC_DOC_RE = re.compile(r"<iframe[^>]+srcdoc=\"(?:<!DOCTYPE html>|<html)", flags=re.IGNORECASE)
DOCTYPE_RE = re.compile(r"<!DOCTYPE html>", flags=re.IGNORECASE)
HTML_TAG_RE = re.compile(r"<html(?:\s|>)", flags=re.IGNORECASE)
IFRAME_SRCDOC_RE = re.compile(r'srcdoc="(.*?)"></iframe>', flags=re.IGNORECASE | re.DOTALL)
STYLE_TAG_RE = re.compile(r"<style[^>]*>(.*?)</style>", flags=re.IGNORECASE | re.DOTALL)

# 仍然依赖 assets/ 相对路径（未完全内联）
ASSETS_REF_RE = re.compile(r'(?:href|src)=["\']assets/[^"\']+["\']', flags=re.IGNORECASE)
CSS_ASSETS_URL_RE = re.compile(r"url\(['\"]?assets/[^'\"\)]+['\"]?\)", flags=re.IGNORECASE)


@dataclass
class Finding:
    id: str
    level: str
    message: str
    count: int = 1


def add_if_match(findings: list[Finding], pattern: re.Pattern[str], text: str,
                 finding_id: str, level: str, message: str) -> None:
    count = len(pattern.findall(text))
    if count:
        findings.append(Finding(finding_id, level, message, count))


def extract_scannable_segments(text: str) -> tuple[str, list[str]]:
    srcdocs: list[str] = []

    def replace_srcdoc(match: re.Match[str]) -> str:
        srcdocs.append(html.unescape(match.group(1)))
        return f"{SRCDOC_PLACEHOLDER}></iframe>"

    masked = IFRAME_SRCDOC_RE.sub(replace_srcdoc, text)
    return masked, srcdocs


def count_matches(pattern: re.Pattern[str], segments: list[str]) -> int:
    return sum(len(pattern.findall(segment)) for segment in segments)


def _is_svg_namespace(url: str) -> bool:
    """去掉末尾反斜杠/空白后判断是否是 SVG/XML 命名空间 URI。"""
    return url.rstrip("\\/ \t") in _SVG_NS


def count_external_resources(segments: list[str]) -> int:
    count = 0
    for segment in segments:
        for match in RESOURCE_LOAD_RE.finditer(segment):
            # 取第一个非空捕获组
            url = next((g for g in match.groups() if g), "").rstrip("\\")
            if not url or _is_svg_namespace(url):
                continue
            count += 1
        # CDN 简写（非 http/https 开头，如 //cdn.xxx）
        count += len(CDN_RE.findall(segment))
    return count


def check_css_bloat(text: str, findings: list[Finding]) -> int:
    """检查全文所有 <style> 块的总 CSS 大小。"""
    blocks = STYLE_TAG_RE.findall(text)
    total = sum(len(b.encode("utf-8")) for b in blocks)
    if total > CSS_BLOCK_BYTES:
        findings.append(Finding(
            "css-bloat", "blocking",
            f"Inline CSS too large: {total // 1024}KB (>{CSS_BLOCK_BYTES // 1024}KB limit). "
            "Run sf-forge build with CSS purge enabled.",
            total // 1024,
        ))
    elif total > CSS_WARN_BYTES:
        findings.append(Finding(
            "css-bloat", "warning",
            f"Inline CSS large: {total // 1024}KB (>{CSS_WARN_BYTES // 1024}KB). "
            "Consider CSS purge.",
            total // 1024,
        ))
    return total


def check_unresolved_assets(text: str, findings: list[Finding]) -> None:
    """检查是否仍有 assets/ 相对路径引用（未完全内联）。"""
    href_srcs = len(ASSETS_REF_RE.findall(text))
    css_urls = len(CSS_ASSETS_URL_RE.findall(text))
    total = href_srcs + css_urls
    if total:
        findings.append(Finding(
            "unresolved-assets", "blocking",
            f"Found {total} unresolved assets/ references — file not self-contained. "
            "Run sf-forge build to inline all assets.",
            total,
        ))


def add_findings(findings: list[Finding], text: str, size: int) -> dict:
    replacement_count = text.count(REPLACEMENT_CHAR)
    if replacement_count:
        findings.append(Finding("replacement-char", "blocking",
                                "Found replacement characters", replacement_count))

    masked_text, srcdoc_segments = extract_scannable_segments(text)
    scannable_segments = [masked_text, *srcdoc_segments]

    escaped_css_syntax_count = count_matches(ESCAPED_CSS_SYNTAX_RE, scannable_segments)
    if escaped_css_syntax_count:
        findings.append(Finding(
            "escaped-css-syntax", "blocking",
            "Found HTML-escaped quotes inside CSS or HTML attribute syntax",
            escaped_css_syntax_count,
        ))

    broken_content_count = count_matches(BROKEN_CONTENT_RE, scannable_segments)
    if broken_content_count:
        findings.append(Finding(
            "broken-css-content", "blocking",
            "Found likely broken CSS content declarations",
            broken_content_count,
        ))

    broken_format_count = count_matches(BROKEN_FORMAT_RE, scannable_segments)
    if broken_format_count:
        findings.append(Finding(
            "broken-css-format", "blocking",
            "Found likely broken font format declarations",
            broken_format_count,
        ))

    broken_url_count = count_matches(BROKEN_URL_RE, scannable_segments)
    if broken_url_count:
        findings.append(Finding("broken-css-url", "blocking",
                                "Found likely broken CSS url declarations", broken_url_count))

    external_resource_count = count_external_resources(scannable_segments)
    if external_resource_count:
        findings.append(Finding(
            "external-resource", "blocking",
            "Found external resource references",
            external_resource_count,
        ))

    check_unresolved_assets(text, findings)

    css_total = check_css_bloat(text, findings)

    srcdoc_docs = len(SRCDOC_DOC_RE.findall(text))
    if srcdoc_docs:
        findings.append(Finding("srcdoc-inline-doc", "warning",
                                "Found inline srcdoc documents that require review", srcdoc_docs))

    doctype_count = len(DOCTYPE_RE.findall(text))
    html_tag_count = len(HTML_TAG_RE.findall(text))
    if doctype_count > 1 or html_tag_count > 1:
        findings.append(Finding(
            "nested-full-document", "warning",
            "Found multiple full HTML document markers inside the same file",
            max(doctype_count, html_tag_count),
        ))

    srcdoc_lengths = [len(item.encode("utf-8")) for item in IFRAME_SRCDOC_RE.findall(text)]
    oversized_srcdoc = [length for length in srcdoc_lengths if length > SRCDOC_WARN_BYTES]
    if oversized_srcdoc:
        findings.append(Finding(
            "oversized-srcdoc", "warning",
            "Found oversized srcdoc payloads that reduce reviewability",
            len(oversized_srcdoc),
        ))

    if size > BLOCKING_SIZE_BYTES:
        findings.append(Finding("file-size", "blocking", f"File too large: {size} bytes"))
    elif size > WARN_SIZE_BYTES:
        findings.append(Finding("file-size", "warning",
                                f"File larger than warning threshold: {size} bytes"))

    return {
        "replacement_char_count": replacement_count,
        "srcdoc_count": len(srcdoc_lengths),
        "max_srcdoc_bytes": max(srcdoc_lengths) if srcdoc_lengths else 0,
        "line_count": text.count("\n") + 1,
        "css_total_bytes": css_total,
    }


def summarize(path: Path, findings: list[Finding], metrics: dict) -> dict:
    blocking = sum(1 for item in findings if item.level == "blocking")
    warnings = sum(1 for item in findings if item.level == "warning")
    return {
        "status": "FAIL" if blocking else "WARN" if warnings else "PASS",
        "summary": {"blocking": blocking, "warnings": warnings},
        "checks": [asdict(item) for item in findings],
        "input": str(path),
        "size_bytes": path.stat().st_size,
        "metrics": metrics,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    path = Path(args.input).resolve()
    text = path.read_text(encoding="utf-8", errors="replace")
    findings: list[Finding] = []
    metrics = add_findings(findings, text, path.stat().st_size)
    payload = summarize(path, findings, metrics)

    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"SINGLEFILE_CHECK:{payload['status']}")
        for check in payload["checks"]:
            print(f"[{check['level'].upper()}] {check['id']}: {check['message']}")

    return 1 if payload["status"] == "FAIL" else 0


if __name__ == "__main__":
    raise SystemExit(main())
