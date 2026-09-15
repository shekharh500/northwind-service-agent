#!/usr/bin/env python3
"""Apply portal/home/home.html to the home page of the Northwind Support site.

Usage: update-portal-home.py <bundle-site-dir> [--html PATH] [--check]

<bundle-site-dir> is the site folder of a retrieved DigitalExperienceBundle, for
example .../digitalExperiences/site/Northwind_Support1. Only
sfdc_cms__view/home/content.json is read and written. The published markup must
use inline styles only, with no script, style, iframe, svg, event handlers,
external URLs or {! expressions, and exactly one <h1>. The script sets
richTextValue on the HTML Editor component and the page title and description on
the SEO component, and writes nothing if any other value in the view would
change. With --check it only reports, and exits 1 if the view is out of date.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
import tempfile
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_HTML = ROOT / "portal" / "home" / "home.html"
VIEW_REL = Path("sfdc_cms__view") / "home" / "content.json"

HTML_EDITOR_DEF = "community_builder:htmlEditor"
SEO_DEF = "community_builder:seoAssistant"

PAGE_TITLE = "Northwind Home Support"
PAGE_DESCRIPTION = (
    "Get help with Northwind Home warranties, returns and refunds, the Aura Smart "
    "Thermostat T200 and CarePlus plans. Chat with our virtual assistant 24/7."
)

BEGIN_MARKER = "<!-- BEGIN richTextValue -->"
END_MARKER = "<!-- END richTextValue -->"

BLOCK_TAGS = (
    "div|section|article|aside|header|footer|nav|main|h1|h2|h3|h4|h5|h6|p|ul|ol|li|"
    "dl|dt|dd|table|thead|tbody|tr|td|th|blockquote|figure|figcaption|hr|br"
)
VOID_TAGS = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}


def extract_fragment(html_text: str) -> str:
    try:
        start = html_text.index(BEGIN_MARKER) + len(BEGIN_MARKER)
        end = html_text.index(END_MARKER, start)
    except ValueError:
        sys.exit(f"error: markers {BEGIN_MARKER!r} / {END_MARKER!r} not found in the HTML source")
    return html_text[start:end]


def minify(fragment: str) -> str:
    """Strip comments and collapse whitespace.

    The container renders with white-space: normal, so a run of whitespace
    is equivalent to one space, and whitespace between block-level tags is
    not rendered at all."""
    out = re.sub(r"<!--.*?-->", "", fragment, flags=re.S)
    out = re.sub(r"\s+", " ", out)
    out = re.sub(rf"(</?(?:{BLOCK_TAGS})\b[^>]*>) (?=</?(?:{BLOCK_TAGS})\b)", r"\1", out, flags=re.I)
    return out.strip()


class _TagBalance(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[str] = []
        self.errors: list[str] = []
        self.h1 = 0

    def handle_starttag(self, tag, attrs):
        if tag == "h1":
            self.h1 += 1
        if tag not in VOID_TAGS:
            self.stack.append(tag)

    def handle_endtag(self, tag):
        if tag in VOID_TAGS:
            return
        if not self.stack or self.stack[-1] != tag:
            self.errors.append(f"unexpected </{tag}> (open: {'/'.join(self.stack[-3:]) or 'none'})")
            if tag in self.stack:
                while self.stack and self.stack.pop() != tag:
                    pass
        else:
            self.stack.pop()


def validate_fragment(fragment: str) -> None:
    problems = []
    rules = [
        (r"<\s*script\b", "contains <script> (JavaScript is not allowed)"),
        (r"<\s*style\b", "contains a <style> block (use inline style attributes)"),
        (r"<\s*(iframe|object|embed|form|input|button)\b", "contains an interactive or embedded element"),
        (r"<\s*svg\b", "contains <svg>"),
        (r"\son[a-z]+\s*=", "contains an inline event handler attribute"),
        (r"javascript:", "contains a javascript: URL"),
        (r"url\(\s*['\"]?\s*(https?:)?//", "references an external image (blocked by the site CSP)"),
        (r"<img\b[^>]*\ssrc\s*=\s*['\"]?\s*(https?:)?//", "references an external image (blocked by the site CSP)"),
        (r"\{!", "contains '{!' which the component treats as a data expression"),
    ]
    for pattern, message in rules:
        if re.search(pattern, fragment, flags=re.I):
            problems.append(message)
    parser = _TagBalance()
    parser.feed(fragment)
    parser.close()
    if parser.h1 != 1:
        problems.append(f"expected exactly one <h1>, found {parser.h1}")
    problems.extend(parser.errors)
    if parser.stack:
        problems.append(f"unclosed tags: {', '.join(parser.stack)}")
    if problems:
        sys.exit("error: the home.html fragment breaks the page rules:\n  - " + "\n  - ".join(problems))


def to_jackson(value, depth: int = 0) -> str:
    """Serialize in the layout the Metadata API returns (Jackson's default pretty printer)."""
    if isinstance(value, dict):
        if not value:
            return "{ }"
        pad = "  " * (depth + 1)
        body = ",\n".join(
            f"{pad}{json.dumps(k, ensure_ascii=False)} : {to_jackson(v, depth + 1)}" for k, v in value.items()
        )
        return "{\n" + body + "\n" + "  " * depth + "}"
    if isinstance(value, list):
        if not value:
            return "[ ]"
        return "[ " + ", ".join(to_jackson(v, depth) for v in value) + " ]"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return "null"
    return json.dumps(value, ensure_ascii=False)


def find_components(node, definition: str, path: str = "$"):
    """Yield (path, component) for every component with the given definition."""
    if isinstance(node, dict):
        if node.get("definition") == definition:
            yield path, node
        for key, child in node.items():
            yield from find_components(child, definition, f"{path}.{key}")
    elif isinstance(node, list):
        for i, child in enumerate(node):
            yield from find_components(child, definition, f"{path}[{i}]")


def collect_ids(node, acc=None) -> list[str]:
    """Every "id" value plus every UUID inside sectionConfig JSON strings."""
    acc = [] if acc is None else acc
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "id" and isinstance(value, str):
                acc.append(value)
            elif key == "sectionConfig" and isinstance(value, str) and value:
                acc.extend(re.findall(r'"UUID"\s*:\s*"([^"]+)"', value))
            else:
                collect_ids(value, acc)
    elif isinstance(node, list):
        for child in node:
            collect_ids(child, acc)
    return acc


def diff_paths(a, b, path: str = "$") -> list[str]:
    if type(a) is not type(b):
        return [path]
    if isinstance(a, dict):
        if list(a.keys()) != list(b.keys()):
            return [path]
        out = []
        for key in a:
            out.extend(diff_paths(a[key], b[key], f"{path}.{key}"))
        return out
    if isinstance(a, list):
        if len(a) != len(b):
            return [path]
        out = []
        for i, (x, y) in enumerate(zip(a, b)):
            out.extend(diff_paths(x, y, f"{path}[{i}]"))
        return out
    return [] if a == b else [path]


def exactly_one(tree, definition: str):
    found = list(find_components(tree, definition))
    if len(found) != 1:
        ids = ", ".join(f"{c.get('id')} at {p}" for p, c in found) or "none"
        sys.exit(f"error: expected exactly one {definition} on the home view, found {len(found)} ({ids})")
    return found[0]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("bundle_site_dir", help="path to digitalExperiences/site/Northwind_Support1")
    ap.add_argument("--html", default=str(DEFAULT_HTML), help=f"page source (default: {DEFAULT_HTML})")
    ap.add_argument("--check", action="store_true", help="report only; exit 1 if the view is out of date")
    args = ap.parse_args()

    bundle = Path(args.bundle_site_dir).expanduser().resolve()
    view_file = bundle / VIEW_REL
    if not view_file.is_file():
        sys.exit(f"error: {view_file} not found (pass the site bundle folder, e.g. .../digitalExperiences/site/Northwind_Support1)")
    html_path = Path(args.html).expanduser().resolve()
    if not html_path.is_file():
        sys.exit(f"error: {html_path} not found")

    fragment = minify(extract_fragment(html_path.read_text(encoding="utf-8")))
    validate_fragment(fragment)

    raw = view_file.read_text(encoding="utf-8")
    original = json.loads(raw)
    if original.get("type") != "sfdc_cms__view" or original.get("contentBody", {}).get("viewType") != "home":
        sys.exit(f"error: {view_file} is not the home sfdc_cms__view")

    trailing = raw[len(raw.rstrip("\r\n")):]

    updated = copy.deepcopy(original)
    editor_path, editor = exactly_one(updated, HTML_EDITOR_DEF)
    seo_path, seo = exactly_one(updated, SEO_DEF)
    editor_attrs = editor.setdefault("attributes", {})
    seo_attrs = seo.setdefault("attributes", {})
    allowed = {
        f"{editor_path}.attributes.richTextValue",
        f"{seo_path}.attributes.pageTitle",
        f"{seo_path}.attributes.description",
    }
    for attrs, key in ((editor_attrs, "richTextValue"), (seo_attrs, "pageTitle"), (seo_attrs, "description")):
        if key not in attrs:
            sys.exit(f"error: attribute {key!r} missing on its component; refusing to add new keys")
    editor_attrs["richTextValue"] = fragment
    seo_attrs["pageTitle"] = PAGE_TITLE
    seo_attrs["description"] = PAGE_DESCRIPTION

    if collect_ids(original) != collect_ids(updated):
        sys.exit("error: component/region ids changed; aborting")
    changed = diff_paths(original, updated)
    unexpected = [p for p in changed if p not in allowed]
    if unexpected:
        sys.exit("error: unexpected JSON changes: " + ", ".join(unexpected))

    output = to_jackson(updated) + trailing
    json.loads(output)

    if output == raw:
        print(f"Already up to date: {view_file}")
        return 0
    if args.check:
        print(f"Out of date ({', '.join(path.rsplit('.', 1)[1] for path in changed)}): {view_file}")
        return 1

    fd, tmp = tempfile.mkstemp(prefix=".content.", suffix=".json", dir=str(view_file.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
            fh.write(output)
        os.replace(tmp, view_file)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    print(f"Updated {', '.join(path.rsplit('.', 1)[1] for path in changed)} in {view_file}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
