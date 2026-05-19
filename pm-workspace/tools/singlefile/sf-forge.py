#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys, os, re, json, shutil, base64, hashlib, mimetypes, argparse, subprocess
from pathlib import Path

if sys.stdout.encoding and sys.stdout.encoding.lower() not in ('utf-8', 'utf8'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

"""
sf-forge.py (SingleFile Forge)
==============================
B端高保真原型处理工具链。专为处理 SingleFile 生成的臃肿单文件 HTML 而设计。

支持两个核心指令：
1. extract: 去肥瘦身
   将 base64 资产、内联大段 CSS/JS 抽离，输出干净可读的 HTML，方便 AI 修改 DOM 结构。
   用法: python sf-forge.py extract input.html [out_dir]

2. build: 离线重装与防灾
   将本地修改后的 HTML 重新打包。
   - 自动把 assets/images 和 assets/fonts 重新压回 base64，避免跨域裂图。
   - 自动扫描所有 iframe 标签，强行注入 sandbox="... allow-scripts allow-same-origin"，解锁 JS 交互。
   - 自动清除未使用的 CSS（--purge-css，build 步骤默认开启）。
   用法: python sf-forge.py build input.html [output.html]
"""

# ==========================================
# 共享映射表
# ==========================================
MIME_TO_EXT = {
    "image/png": ".png", "image/jpeg": ".jpg", "image/jpg": ".jpg",
    "image/gif": ".gif", "image/webp": ".webp", "image/svg+xml": ".svg",
    "image/x-icon": ".ico", "image/vnd.microsoft.icon": ".ico",
    "image/bmp": ".bmp", "image/avif": ".avif",
    "font/woff": ".woff", "font/woff2": ".woff2",
    "font/ttf": ".ttf", "font/otf": ".otf", "font/eot": ".eot",
    "application/font-woff": ".woff", "application/font-woff2": ".woff2",
    "application/x-font-ttf": ".ttf",
    "application/vnd.ms-fontobject": ".eot",
    "text/css": ".css", "text/javascript": ".js",
    "application/javascript": ".js",
}

MIME_TO_SUBDIR = {
    "image": "images", "font": "fonts",
    "text": "css",     "application": "misc",
}

# ==========================================
# CSS 清洗（purge unused CSS rules）
# ==========================================

def _collect_dom_tokens(html: str) -> dict:
    """从 HTML 全文（含 srcdoc 解码内容）收集 class、id、element、animation name。"""
    import html as htmlmod

    full = html
    # 解码所有 srcdoc 属性，把内层内容也纳入分析范围
    for srcdoc_raw in re.findall(r'srcdoc="(.*?)"></iframe>', html, re.DOTALL | re.IGNORECASE):
        full += htmlmod.unescape(srcdoc_raw)

    classes: set[str] = set()
    for group in re.findall(r'class=["\']([^"\']+)["\']', full, re.IGNORECASE):
        classes.update(group.split())

    ids: set[str] = set(re.findall(r'id=["\']([^"\']+)["\']', full, re.IGNORECASE))

    elements: set[str] = {t.lower() for t in re.findall(r'<([a-zA-Z][a-zA-Z0-9-]*)', full)}

    # animation-name 值，用于决定 @keyframes 是否保留
    animations: set[str] = set(re.findall(
        r'animation(?:-name)?\s*:\s*([a-zA-Z][a-zA-Z0-9_-]+)', full, re.IGNORECASE
    ))

    return {"classes": classes, "ids": ids, "elements": elements, "animations": animations}


def _split_css_chunks(css: str) -> list[tuple[str, str]]:
    """
    将 CSS 文本分割为 (head, body_with_braces) 对。
    head = 选择器 或 @at-rule 声明行
    body = { ... }（含大括号，支持嵌套）
    未配对的文本以 (text, '') 形式返回。
    """
    chunks: list[tuple[str, str]] = []
    i = 0
    n = len(css)

    while i < n:
        # 跳过空白
        while i < n and css[i] in ' \t\n\r':
            i += 1
        if i >= n:
            break

        # 跳过注释
        if css[i:i+2] == '/*':
            end = css.find('*/', i + 2)
            i = (end + 2) if end != -1 else n
            continue

        # 找 head（直到第一个 {）
        j = i
        while j < n and css[j] != '{':
            # 跳过注释
            if css[j:j+2] == '/*':
                end = css.find('*/', j + 2)
                j = (end + 2) if end != -1 else n
            else:
                j += 1

        if j >= n:
            # 没有 { —— 悬空文本，忽略
            break

        head = css[i:j].strip()
        # 找匹配的 }，支持嵌套
        depth = 0
        k = j
        while k < n:
            if css[k] == '{':
                depth += 1
            elif css[k] == '}':
                depth -= 1
                if depth == 0:
                    break
            k += 1

        body = css[j:k + 1]  # 含首尾 {}
        chunks.append((head, body))
        i = k + 1

    return chunks


# 总是保留的 at-rule 类型（不管 DOM 里有没有）
_ALWAYS_KEEP_AT = re.compile(
    r'^@(?:font-face|charset|import|namespace|layer|counter-style|property|scroll-timeline)\b',
    re.IGNORECASE
)

# 包含嵌套规则的 at-rule（需要递归处理）
_NESTED_AT = re.compile(
    r'^@(?:media|supports|document|layer|container|scope)\b',
    re.IGNORECASE
)

# 关键帧 at-rule
_KEYFRAMES_AT = re.compile(r'^@keyframes\s+(\S+)', re.IGNORECASE)

# UI 框架类名前缀白名单（el-*, ant-*, van-* 等由 JS 动态注入，静态分析不可靠）
_UI_FRAMEWORK_RE = re.compile(
    r'^(?:el|ant|van|arco|ivu|vxe|n)-|^is-',
    re.IGNORECASE
)


def _selector_matches(selector: str, tokens: dict) -> bool:
    """判断 CSS 选择器是否命中 DOM 中存在的 token。"""
    sel = selector.strip()
    if not sel:
        return False

    # 选择器中的每段（逗号分隔），任一匹配则保留
    for part in re.split(r',', sel):
        part = part.strip()
        if not part:
            continue

        # 通配 / root / html / body / :root 等基础选择器
        if re.match(r'^[*]$|^:root|^html\b|^body\b', part, re.IGNORECASE):
            return True

        # 类名：.foo
        sel_classes = re.findall(r'\.([a-zA-Z_-][a-zA-Z0-9_-]*)', part)
        if sel_classes and any(c in tokens["classes"] for c in sel_classes):
            return True

        # ID：#foo
        sel_ids = re.findall(r'#([a-zA-Z_-][a-zA-Z0-9_-]*)', part)
        if sel_ids and any(i in tokens["ids"] for i in sel_ids):
            return True

        # UI 框架前缀（el-*, ant-*, van-*, is-* 等由 JS 动态注入，始终保留）
        if sel_classes and any(_UI_FRAMEWORK_RE.match(c) for c in sel_classes):
            return True

        # 纯元素名（如 input, table, th）
        sel_elements = re.findall(
            r'(?:^|[\s>+~,])([a-zA-Z][a-zA-Z0-9-]*)(?=[.#:\[\s>+~,{]|$)', part
        )
        if sel_elements and any(e.lower() in tokens["elements"] for e in sel_elements):
            return True

    return False


def _purge_css_chunk(css_body_inner: str, tokens: dict, kept_keyframes: set[str]) -> str:
    """递归清洗 CSS 块内部内容（不含外层大括号）。"""
    chunks = _split_css_chunks(css_body_inner)
    kept_parts: list[str] = []

    for head, body in chunks:
        # @font-face / @charset 等：直接保留
        if _ALWAYS_KEEP_AT.match(head):
            kept_parts.append(f"{head} {body}")
            continue

        # @keyframes：只保留 DOM 中有 animation-name 引用的
        km = _KEYFRAMES_AT.match(head)
        if km:
            name = km.group(1)
            if name in tokens["animations"] or name in kept_keyframes:
                kept_parts.append(f"{head} {body}")
            continue

        # @media / @supports 等嵌套 at-rule：递归清洗内部
        if _NESTED_AT.match(head):
            inner = body[1:-1] if body.startswith('{') and body.endswith('}') else body
            inner_purged = _purge_css_chunk(inner, tokens, kept_keyframes)
            if inner_purged.strip():
                kept_parts.append(f"{head} {{{inner_purged}}}")
            continue

        # 普通规则：按选择器过滤
        if _selector_matches(head, tokens):
            # 跳过 body 中含替换字符的规则（图标字体编码损坏，保留无意义）
            if "�" not in body:
                kept_parts.append(f"{head} {body}")

    return "\n".join(kept_parts)


def purge_css(html: str) -> tuple[str, dict]:
    """
    清洗 HTML 中所有 <style> 块里的未使用 CSS 规则。
    返回 (新 HTML, 统计信息)。
    """
    tokens = _collect_dom_tokens(html)
    # 从内联 style 属性收集 animation name（_collect_dom_tokens 已处理，但再加一遍确保）
    kept_keyframes: set[str] = set(tokens["animations"])

    stats = {"before_bytes": 0, "after_bytes": 0, "blocks": 0}

    def replace_style(m: re.Match) -> str:
        open_tag = m.group(1)
        css = m.group(2)
        close_tag = m.group(3)
        before = len(css.encode("utf-8"))
        stats["before_bytes"] += before
        stats["blocks"] += 1
        purged = _purge_css_chunk(css, tokens, kept_keyframes)
        after = len(purged.encode("utf-8"))
        stats["after_bytes"] += after
        return f"{open_tag}\n{purged}\n{close_tag}"

    STYLE_TAG_RE = re.compile(r"(<style(?:[^>]*)>)(.*?)(</style>)", re.DOTALL | re.IGNORECASE)
    new_html = STYLE_TAG_RE.sub(replace_style, html)
    return new_html, stats


# ==========================================
# srcdoc iframe 扁平化
# ==========================================

def flatten_srcdoc_iframes(html: str) -> tuple[str, int]:
    """
    将 srcdoc 中内嵌完整 HTML 文档的 iframe 替换为 div。
    解决 file:// 协议下 null-origin 跨域限制导致的内容白屏问题。
    """
    import html as htmlmod

    hoisted: list[str] = []
    count = 0

    IFRAME_SRCDOC_RE = re.compile(
        r'<iframe\b([^>]*?)srcdoc="(.*?)"></iframe>',
        re.DOTALL | re.IGNORECASE
    )

    def _replace(m: re.Match) -> str:
        nonlocal count
        iframe_attrs = m.group(1)
        inner = htmlmod.unescape(m.group(2))

        # 只处理完整 HTML 文档（跳过片段型 srcdoc）
        if not re.search(r'<!DOCTYPE\s+html>|<html[\s>]', inner, re.IGNORECASE):
            return m.group(0)

        # 提取内层 <head> 中的 <style> 和 <script>，提升到外层文档
        head_m = re.search(r'<head[^>]*>(.*?)</head>', inner, re.DOTALL | re.IGNORECASE)
        if head_m:
            for tag in re.finditer(
                r'<(?:style|script)\b[^>]*>.*?</(?:style|script)>',
                head_m.group(1), re.DOTALL | re.IGNORECASE
            ):
                hoisted.append(tag.group(0))
        else:
            body_start_m = re.search(r'<body\b[^>]*>', inner, re.DOTALL | re.IGNORECASE)
            pre_body = inner[:body_start_m.start()] if body_start_m else inner
            for tag in re.finditer(
                r'<(?:style|script)\b[^>]*>.*?</(?:style|script)>',
                pre_body, re.DOTALL | re.IGNORECASE
            ):
                hoisted.append(tag.group(0))

        # 提取 <body> 内容作为 div 的内容。部分 SingleFile 子文档会省略
        # </body>，这时也应从 <body> 起点截到 </html> 或文档末尾。
        body_m = re.search(
            r'<body[^>]*>(.*?)(?:</body>|</html>\s*$|$)',
            inner,
            re.DOTALL | re.IGNORECASE,
        )
        if body_m:
            content = body_m.group(1)
        else:
            content = re.sub(r'<!DOCTYPE\s+html>', '', inner, flags=re.IGNORECASE)
            content = re.sub(r'</?html\b[^>]*>', '', content, flags=re.IGNORECASE)
            content = re.sub(r'<head\b[^>]*>.*?</head>', '', content, flags=re.DOTALL | re.IGNORECASE)
            content = re.sub(r'<meta\b[^>]*>', '', content, flags=re.IGNORECASE)

        # 保留 iframe 的 id / class / style 属性
        id_m    = re.search(r'\bid="([^"]+)"',    iframe_attrs)
        class_m = re.search(r'\bclass="([^"]+)"', iframe_attrs)
        style_m = re.search(r'\bstyle="([^"]+)"', iframe_attrs)

        div_attrs = ''
        if id_m:    div_attrs += f' id="{id_m.group(1)}"'
        if class_m: div_attrs += f' class="{class_m.group(1)}"'
        if style_m: div_attrs += f' style="{style_m.group(1)}"'

        count += 1
        return f'<div{div_attrs}>{content}</div>'

    new_html = IFRAME_SRCDOC_RE.sub(_replace, html)

    # 将提升的 style/script 注入到外层 </head> 之前
    if hoisted:
        hoisted_text = '\n'.join(hoisted) + '\n'
        if re.search(r'</head>', new_html, re.IGNORECASE):
            new_html = re.sub(
                r'</head>',
                hoisted_text + '</head>',
                new_html, count=1, flags=re.IGNORECASE
            )
        elif re.search(r'<body\b[^>]*>', new_html, re.IGNORECASE):
            new_html = re.sub(
                r'<body\b[^>]*>',
                lambda m: hoisted_text + m.group(0),
                new_html, count=1, flags=re.IGNORECASE
            )
        else:
            new_html = hoisted_text + new_html

    return new_html, count


# ==========================================
# extract 核心逻辑
# ==========================================
def normalize_srcdoc_attributes(html: str) -> tuple[str, int]:
    """
    Re-escape iframe srcdoc payloads after build-time inlining.

    The build step can insert CSS containing raw double quotes, such as
    url("data:..."), into an existing double-quoted srcdoc attribute. Browsers
    then terminate the attribute early and parse the rest as outer DOM/CSS.
    Decode once first so existing &quot; entities are not double-escaped.
    """
    import html as htmlmod

    count = 0

    def _replace(m: re.Match[str]) -> str:
        nonlocal count
        count += 1
        inner = htmlmod.unescape(m.group(1))
        if "sf-forge-frame-cleanup" not in inner:
            frame_cleanup = (
                "<style id=\"sf-forge-frame-cleanup\">"
                "[class^=\"el-icon-\"]:before,[class*=\" el-icon-\"]:before{content:\"\"!important}"
                "</style>"
            )
            inner = re.sub(
                r"<body\b",
                frame_cleanup + "<body",
                inner,
                count=1,
                flags=re.IGNORECASE,
            )
        return f'srcdoc="{htmlmod.escape(inner, quote=True)}"'

    return re.sub(
        r'srcdoc="(.*?)"(?=[^>]*></iframe>)',
        _replace,
        html,
        flags=re.DOTALL | re.IGNORECASE,
    ), count


def sanitize_captured_overlays(html: str) -> tuple[str, dict]:
    """Remove capture-time overlays that are not part of the prototype flow."""
    stats = {
        "watermark_templates_removed": 0,
        "monica_body_attrs_removed": 0,
        "overlay_css_injected": 0,
    }

    html, stats["watermark_templates_removed"] = re.subn(
        r"<div>\s*<template\s+shadowrootmode=open>\s*<style[^>]*>\s*ul\.waterm-list\b.*?</template>\s*</div>",
        "",
        html,
        flags=re.DOTALL | re.IGNORECASE,
    )
    html, stats["monica_body_attrs_removed"] = re.subn(
        r"\smonica-(?:id|version)=(?:\"[^\"]*\"|'[^']*'|[^\s>]+)",
        "",
        html,
        flags=re.IGNORECASE,
    )

    cleanup_css = (
        "<style id=\"sf-forge-capture-cleanup\">"
        "#monica-content-root,.monica-widget,"
        "[class*=\"_monica\"],[class*=\"monica-\"],"
        ".index__ai-service--small,.index__helper--list,.index__ai-service--drawer{"
        "display:none!important;visibility:hidden!important}"
        "[class^=\"el-icon-\"]:before,[class*=\" el-icon-\"]:before{content:\"\"!important}"
        "</style>"
    )
    if "sf-forge-capture-cleanup" not in html:
        html, stats["overlay_css_injected"] = re.subn(
            r"<body\b",
            cleanup_css + "<body",
            html,
            count=1,
            flags=re.IGNORECASE,
        )

    return html, stats


def short_hash(data: bytes) -> str:
    return hashlib.sha1(data).hexdigest()[:8]

def str_hash(s: str) -> str:
    return hashlib.sha1(s.encode("utf-8")).hexdigest()[:8]

def parse_data_uri(uri: str):
    m = re.match(r"data:([^;,]+)?(;charset=[^;,]+)?(;base64)?,(.+)", uri, re.DOTALL)
    if not m: return None
    mime_type = (m.group(1) or "text/plain").strip().lower()
    is_base64 = m.group(3) is not None
    raw = m.group(4)
    try:
        if is_base64:
            data = base64.b64decode(raw + "==")
        else:
            from urllib.parse import unquote
            data = unquote(raw).encode("utf-8")
        return mime_type, data
    except Exception:
        return None

def get_subdir(mime: str) -> str:
    return MIME_TO_SUBDIR.get(mime.split("/")[0], "misc")

def get_ext(mime: str) -> str:
    if mime in MIME_TO_EXT: return MIME_TO_EXT[mime]
    return mimetypes.guess_extension(mime, strict=False) or ".bin"

def save_asset(data_bytes: bytes, mime: str, assets_root: Path) -> str:
    subdir = get_subdir(mime)
    ext = get_ext(mime)
    h = short_hash(data_bytes)
    target_dir = assets_root / subdir
    target_dir.mkdir(parents=True, exist_ok=True)
    path = target_dir / f"{h}{ext}"
    if not path.exists():
        path.write_bytes(data_bytes)
    return f"assets/{subdir}/{h}{ext}"

def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

def run_singlefile_check(checker_path: Path, html_path: Path) -> tuple[int, str]:
    proc = subprocess.run(
        [sys.executable, str(checker_path), str(html_path), "--json"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return proc.returncode, proc.stdout

ATTR_DATA_URI_RE = re.compile(r'(?P<attr>(?:src|href|action|data|poster|srcset)=")(?P<uri>data:[^"]{10,})"', re.IGNORECASE)
CSS_URL_DATA_URI_RE = re.compile(r"""url\((?P<q>['"]?)(?P<uri>data:[^'")]{10,})(?P=q)\)""", re.IGNORECASE | re.DOTALL)
STYLE_TAG_RE = re.compile(r"(<style(?:[^>]*)>)(.*?)(</style>)", re.DOTALL | re.IGNORECASE)
SCRIPT_TAG_RE = re.compile(r"(<script(?P<attrs>[^>]*)>)(.*?)(</script>)", re.DOTALL | re.IGNORECASE)
SINGLEFILE_META_RE = re.compile(r"<!--\s*(?:Page saved with SingleFile|/Page saved).*?-->", re.DOTALL | re.IGNORECASE)

def cmd_extract(args):
    input_path = Path(args.input).resolve()
    if not input_path.exists():
        print(f"[ERROR] {input_path} not found")
        sys.exit(1)

    out_dir = Path(args.output).resolve() if args.output else input_path.parent / f"{input_path.stem}_pipeline"
    out_dir.mkdir(parents=True, exist_ok=True)
    source_dir = out_dir / "source"
    reviewable_dir = out_dir / "reviewable"
    meta_dir = out_dir / "meta"
    assets_root = reviewable_dir / "assets"
    source_dir.mkdir(parents=True, exist_ok=True)
    reviewable_dir.mkdir(parents=True, exist_ok=True)
    meta_dir.mkdir(parents=True, exist_ok=True)
    source_copy = source_dir / "source.html"
    if input_path != source_copy:
        shutil.copy2(input_path, source_copy)

    html = input_path.read_text(encoding="utf-8", errors="replace")
    orig_size = len(html.encode("utf-8"))

    print(f"[EXTRACT] Input: {input_path}")
    print(f"[EXTRACT] Size : {orig_size / 1024:.1f} KB")

    html = SINGLEFILE_META_RE.sub("", html)

    # 提取 data URI
    n_uris = [0]
    def _attr(m):
        res = parse_data_uri(m.group("uri"))
        if not res: return m.group(0)
        mime, data = res
        rel = save_asset(data, mime, assets_root)
        n_uris[0] += 1
        return f'{m.group("attr")}{rel}"'
    def _css(m):
        res = parse_data_uri(m.group("uri"))
        if not res: return m.group(0)
        mime, data = res
        rel = save_asset(data, mime, assets_root)
        n_uris[0] += 1
        return f"url('{rel}')"

    html = ATTR_DATA_URI_RE.sub(_attr, html)
    html = CSS_URL_DATA_URI_RE.sub(_css, html)

    # 提取 style
    n_css = [0]
    css_thresh = int(args.css_threshold * 1024)
    def _style(m):
        content = m.group(2)
        if len(content.encode("utf-8")) < css_thresh: return m.group(0)
        h = str_hash(content)
        css_dir = assets_root / "css"
        css_dir.mkdir(parents=True, exist_ok=True)
        (css_dir / f"chunk_{h}.css").write_text(content, encoding="utf-8")
        n_css[0] += 1
        return f'<link rel="stylesheet" href="assets/css/chunk_{h}.css">'
    html = STYLE_TAG_RE.sub(_style, html)

    # 提取 script
    n_js = [0]
    js_thresh = int(args.js_threshold * 1024)
    def _script(m):
        attrs, content = (m.group("attrs") or ""), m.group(3)
        if "src=" in attrs.lower() or len(content.strip().encode("utf-8")) < js_thresh: return m.group(0)
        if "Page saved with SingleFile" in content or "singlefile" in content.lower()[:200]: return m.group(0)
        h = str_hash(content)
        js_dir = assets_root / "js"
        js_dir.mkdir(parents=True, exist_ok=True)
        (js_dir / f"chunk_{h}.js").write_text(content, encoding="utf-8")
        n_js[0] += 1
        type_m = re.search(r'type=["\']([^"\']+)["\']', attrs, re.IGNORECASE)
        type_attr = f' type="{type_m.group(1)}"' if type_m else ""
        return f'<script{type_attr} src="assets/js/chunk_{h}.js"></script>'
    html = SCRIPT_TAG_RE.sub(_script, html)

    out_html = reviewable_dir / "index.html"
    out_html.write_text(html, encoding="utf-8")
    write_json(
        meta_dir / "extract-report.json",
        {
            "input": str(input_path),
            "source_copy": str(source_copy.resolve()),
            "reviewable_html": str(out_html.resolve()),
            "images_fonts_extracted": n_uris[0],
            "css_chunks": n_css[0],
            "js_chunks": n_js[0],
            "new_html_size_bytes": out_html.stat().st_size,
        },
    )

    print(f"[DONE] Extracted to: {out_html}")
    print(f"       Images/Fonts : {n_uris[0]}")
    print(f"       CSS chunks   : {n_css[0]}")
    print(f"       JS chunks    : {n_js[0]}")
    print(f"       New HTML size: {out_html.stat().st_size / 1024:.1f} KB")

# ==========================================
# build 核心逻辑
# ==========================================
def cmd_build(args):
    input_path = Path(args.input).resolve()
    if not input_path.exists():
        print(f"[ERROR] {input_path} not found")
        sys.exit(1)

    if args.output:
        out_path = Path(args.output).resolve()
    elif input_path.parent.name == "reviewable":
        out_path = input_path.parent.parent / "demo_final.html"
    else:
        out_path = input_path.parent / "demo_final.html"

    meta_dir = input_path.parent.parent / "meta" if input_path.parent.name == "reviewable" else input_path.parent / "meta"
    meta_dir.mkdir(parents=True, exist_ok=True)
    default_checker = Path(__file__).with_name("check-singlefile-prototype.py")
    checker = Path(args.checker).resolve() if args.checker else (default_checker.resolve() if default_checker.exists() else None)
    finalcheck_payload = None

    html = input_path.read_text(encoding="utf-8", errors="replace")
    print(f"[BUILD] Input: {input_path}  ({len(html.encode()) // 1024} KB)")

    # 1. 内联 CSS <link> 标签（把 assets/css/*.css 重新 <style> 内联）
    css_link_fixed = [0]
    def inline_css_link(m):
        rel = m.group(1)
        f = input_path.parent / rel
        if f.exists():
            content = f.read_text(encoding="utf-8", errors="replace")
            css_link_fixed[0] += 1
            return f"<style>\n{content}\n</style>"
        return m.group(0)
    html = re.sub(r'<link\s[^>]*rel=["\']stylesheet["\'][^>]*href=["\']([^"\']+)["\'][^>]*>', inline_css_link, html, flags=re.IGNORECASE)
    # 也处理 href 在 rel 前的情况
    html = re.sub(r'<link\s[^>]*href=["\']([^"\']+)["\'][^>]*rel=["\']stylesheet["\'][^>]*>', inline_css_link, html, flags=re.IGNORECASE)

    print(f"  [CSS links] Inlined {css_link_fixed[0]} external stylesheets.")

    # 2. 自动补全 Sandbox 权限
    def fix_sandbox(m):
        sandbox_val = m.group(1)
        needed = ["allow-scripts", "allow-same-origin"]
        adds = [p for p in needed if p not in sandbox_val]
        if adds:
            new_val = sandbox_val + " " + " ".join(adds)
            return f'sandbox="{new_val}"'
        return m.group(0)

    html, n_subs = re.subn(r'sandbox="([^"]+)"', fix_sandbox, html)
    print(f"  [Sandbox]   Injected missing permissions in {n_subs} iframes.")

    # 3. 内联 Images（src="assets/..."）
    img_fixed = [0]
    def inline_img(m):
        rel_path = m.group(1)
        f = input_path.parent / rel_path
        if f.exists():
            data = base64.b64encode(f.read_bytes()).decode()
            mime = {'png':'image/png', 'jpg':'image/jpeg', 'jpeg':'image/jpeg',
                    'gif':'image/gif', 'svg':'image/svg+xml', 'ico':'image/x-icon',
                    'webp':'image/webp'}.get(f.suffix.lower().lstrip('.'), 'image/png')
            img_fixed[0] += 1
            return f'src="data:{mime};base64,{data}"'
        return m.group(0)
    html = re.sub(r'src="(assets/images/[^"]+)"', inline_img, html)

    # 4. 内联 CSS 变量中的 image 引用：url('assets/images/...')
    css_img_fixed = [0]
    def inline_css_img(m):
        rel_path = m.group(1)
        f = input_path.parent / rel_path
        if f.exists():
            data = base64.b64encode(f.read_bytes()).decode()
            ext = f.suffix.lower().lstrip('.')
            mime = {'png':'image/png', 'jpg':'image/jpeg', 'jpeg':'image/jpeg',
                    'gif':'image/gif', 'svg':'image/svg+xml', 'ico':'image/x-icon',
                    'webp':'image/webp'}.get(ext, 'image/png')
            css_img_fixed[0] += 1
            return f"url('data:{mime};base64,{data}')"
        return m.group(0)
    html = re.sub(r"url\('(assets/images/[^']+)'\)", inline_css_img, html)
    html = re.sub(r'url\("(assets/images/[^"]+)"\)', inline_css_img, html)

    # 5. 内联 Favicon link href
    favicon_fixed = [0]
    def inline_favicon(m):
        rel_path = m.group(2)
        f = input_path.parent / rel_path
        if f.exists():
            data = base64.b64encode(f.read_bytes()).decode()
            mime = {'ico':'image/x-icon', 'png':'image/png',
                    'gif':'image/gif', 'svg':'image/svg+xml'}.get(
                f.suffix.lower().lstrip('.'), 'image/x-icon')
            favicon_fixed[0] += 1
            return f'{m.group(1)}data:{mime};base64,{data}"'
        return m.group(0)
    html = re.sub(r'(<link\s[^>]*href=")([^"]+\.(ico|png|gif|svg))"', inline_favicon, html, flags=re.IGNORECASE)

    # 6. 内联 Fonts
    font_fixed = [0]
    def inline_font(m):
        rel_path = m.group(1)
        f = input_path.parent / rel_path
        if f.exists():
            data = base64.b64encode(f.read_bytes()).decode()
            mime = {'woff':'font/woff', 'woff2':'font/woff2', 'ttf':'font/ttf',
                    'eot':'application/vnd.ms-fontobject',
                    'bin':'font/woff2'}.get(f.suffix.lower().lstrip('.'), 'font/woff')
            font_fixed[0] += 1
            return f'url("data:{mime};base64,{data}")'
        return m.group(0)
    html = re.sub(r"url\('(assets/fonts/[^']+)'\)", inline_font, html)
    html = re.sub(r'url\("(assets/fonts/[^"]+)"\)', inline_font, html)
    # misc 目录（通常是字体的 .bin 文件）
    html = re.sub(r"url\('(assets/misc/[^']+)'\)", inline_font, html)
    html = re.sub(r'url\("(assets/misc/[^"]+)"\)', inline_font, html)

    print(f"  [Assets]    Inlined {img_fixed[0]} img srcs, {css_img_fixed[0]} CSS img urls, "
          f"{favicon_fixed[0]} favicons, {font_fixed[0]} fonts.")

    # 6b. 清除仍然悬空的 assets/ 引用（文件不存在，无法内联）
    stripped = [0]

    # 删除 <link href="assets/..."> 标签（如 favicon 找不到文件）
    def strip_link_asset(_):
        stripped[0] += 1
        return ""
    html = re.sub(
        r'<link\s[^>]*href=["\']assets/[^"\']+["\'][^>]*>',
        strip_link_asset, html, flags=re.IGNORECASE
    )

    # 将 CSS url('assets/...') 替换为 none（保留属性，去掉悬空引用）
    def strip_css_asset_url(_):
        stripped[0] += 1
        return "none"
    html = re.sub(r"url\(['\"]?assets/[^'\"\)]+['\"]?\)", strip_css_asset_url, html, flags=re.IGNORECASE)

    # 删除 src="assets/..." 属性值（保留属性名，值置空）
    def strip_src_asset(_):
        stripped[0] += 1
        return 'src=""'
    html = re.sub(r'src=["\']assets/[^"\']+["\']', strip_src_asset, html, flags=re.IGNORECASE)

    if stripped[0]:
        print(f"  [Cleanup]   Stripped {stripped[0]} unresolvable assets/ references.")

    # 7. srcdoc iframe 扁平化（消除 file:// null-origin 白屏）
    flatten_count = 0
    if not args.no_flatten:
        html, flatten_count = flatten_srcdoc_iframes(html)
        if flatten_count:
            print(f"  [Flatten]   Replaced {flatten_count} srcdoc iframe(s) with divs.")
        else:
            print(f"  [Flatten]   No full-document srcdoc iframes found.")

    # 8. CSS 清洗（去除未使用的 CSS 规则）
    if args.purge_css:
        html, css_stats = purge_css(html)
        saved = css_stats["before_bytes"] - css_stats["after_bytes"]
        print(f"  [CSS purge] {css_stats['blocks']} blocks: "
              f"{css_stats['before_bytes']//1024}KB → {css_stats['after_bytes']//1024}KB "
              f"(saved {saved//1024}KB)")

    html, capture_cleanup = sanitize_captured_overlays(html)
    cleaned = sum(capture_cleanup.values())
    if cleaned:
        print(f"  [Cleanup]   Removed/hidden capture overlays: {capture_cleanup}.")

    # Re-escape srcdoc payloads after all inlining/purging. This must be last
    # so any inserted quotes inside iframe documents remain valid HTML.
    html, srcdoc_normalized = normalize_srcdoc_attributes(html)
    if srcdoc_normalized:
        print(f"  [Srcdoc]    Normalized {srcdoc_normalized} iframe srcdoc attribute(s).")

    height_fix_css = (
        "<style id=\"sf-forge-layout-fix\">"
        ".main-container .app-init-container,"
        ".main-container .page-wrapper,"
        ".main-container .page-wrapper>div,"
        ".main-container .view-item,"
        ".main-container .view-item iframe{"
        "width:100%!important;height:100%!important;min-height:1px}"
        "</style>"
    )
    layout_fix_injected = 0
    if "sf-forge-layout-fix" not in html:
        html, layout_fix_injected = re.subn(
            r"<body\b",
            height_fix_css + "<body",
            html,
            count=1,
            flags=re.IGNORECASE,
        )
        if layout_fix_injected:
            print("  [Layout]    Injected iframe height preservation CSS.")

    candidate_path = out_path.with_name(out_path.name + ".tmp")
    candidate_path.write_text(html, encoding="utf-8")

    if checker and not args.skip_check:
        code, stdout = run_singlefile_check(checker, candidate_path)
        finalcheck_payload = {"exit_code": code, "raw": stdout}
        if code != 0:
            print("[ERROR] build blocked by singlefile quality checker")
            print(stdout)
            write_json(
                meta_dir / "build-report.json",
                {
                    "input": str(input_path),
                    "output": str(out_path),
                    "blocked": True,
                    "checker": str(checker) if checker else None,
                    "finalcheck": finalcheck_payload,
                    "candidate": str(candidate_path),
                },
            )
            try:
                candidate_path.unlink()
            except OSError:
                pass
            sys.exit(1)

    candidate_path.replace(out_path)
    final_kb = out_path.stat().st_size // 1024
    write_json(
        meta_dir / "build-report.json",
        {
            "input": str(input_path),
            "output": str(out_path),
            "blocked": False,
            "checker": str(checker) if checker else None,
            "size_bytes": out_path.stat().st_size,
            "finalcheck": finalcheck_payload,
            "sandbox_updates": n_subs,
            "inlined_css_links": css_link_fixed[0],
            "inlined_images": img_fixed[0],
            "inlined_fonts": font_fixed[0],
            "flatten_count": flatten_count,
            "srcdoc_normalized": srcdoc_normalized,
            "layout_fix_injected": layout_fix_injected,
            "capture_cleanup": capture_cleanup,
            "css_purge": css_stats if args.purge_css else None,
        },
    )
    print(f"[DONE] Built to: {out_path} ({final_kb} KB)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="SingleFile Forge: B 端后台原型构建工具链")
    subparsers = parser.add_subparsers(dest="command", required=True)

    p_ext = subparsers.add_parser("extract", help="将 SingleFile 提取去肥瘦身")
    p_ext.add_argument("input", help="Source HTML file path")
    p_ext.add_argument("output", nargs="?", help="Output directory path")
    p_ext.add_argument("--css-threshold", type=float, default=2.0, help="Min KB for CSS extraction")
    p_ext.add_argument("--js-threshold", type=float, default=10.0, help="Min KB for JS extraction")

    p_bld = subparsers.add_parser("build", help="将修改后的 HTML 重装压回并注入防灾策略")
    p_bld.add_argument("input", help="Modified HTML file path")
    p_bld.add_argument("output", nargs="?", help="Final built HTML file path")
    p_bld.add_argument("--checker", help="Optional singlefile checker path")
    p_bld.add_argument("--skip-check", action="store_true", help="跳过预检（用于已清洗的中间文件）")
    p_bld.add_argument("--no-flatten", action="store_true", help="禁用 srcdoc iframe 扁平化（默认启用）")
    p_bld.add_argument("--purge-css", action="store_true", help="启用 CSS 清洗（默认关闭，B端后台有动态类名时慎用）")

    args = parser.parse_args()
    if args.command == "extract": cmd_extract(args)
    elif args.command == "build": cmd_build(args)
