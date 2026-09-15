"""Build the Northwind Home PDFs in docs/pdf from the Markdown sources in docs/source.

    python3 scripts/build_docs.py

Each source starts with a front matter block (document, version or firmware,
effective or published, notice). The body can use #, ## and ### headings,
paragraphs, numbered clauses ("2.1 ..."), lettered items ("(a) ..."), "- " and
"1. " lists, pipe tables and "> **Note:** ..." callouts. In a table's separator
row, the number of dashes in each column sets its relative width.
"""
import re
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.pagesizes import LETTER
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import inch
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas
from reportlab.platypus import BaseDocTemplate, Frame, KeepTogether, PageTemplate, Paragraph, Spacer, Table, TableStyle
from reportlab.platypus.doctemplate import Indenter

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "docs" / "source"
OUT = ROOT / "docs" / "pdf"

COMPANY = "Northwind Home"

PAGE_W, PAGE_H = LETTER
MARGIN_X = 0.9 * inch
MARGIN_TOP = 1.0 * inch
MARGIN_BOTTOM = 0.95 * inch
HEADER_Y = PAGE_H - 0.6 * inch
FOOTER_Y = 0.55 * inch

INK = colors.HexColor("#1f2328")
BRAND = colors.HexColor("#1b4d6b")
MUTED = colors.HexColor("#5f6770")
RULE = colors.HexColor("#c5ccd3")
SHADE = colors.HexColor("#e9eef2")
NOTE_FILL = colors.HexColor("#f1f5f8")
CAUTION = colors.HexColor("#b26a00")
CAUTION_FILL = colors.HexColor("#fbf4e8")

FONT_CANDIDATES = [
    ("/System/Library/Fonts/Supplemental", ("Arial.ttf", "Arial Bold.ttf", "Arial Italic.ttf", "Arial Bold Italic.ttf")),
    ("/usr/share/fonts/truetype/liberation", ("LiberationSans-Regular.ttf", "LiberationSans-Bold.ttf",
                                              "LiberationSans-Italic.ttf", "LiberationSans-BoldItalic.ttf")),
]


def register_fonts():
    for folder, files in FONT_CANDIDATES:
        paths = [Path(folder) / f for f in files]
        if all(p.exists() for p in paths):
            names = ("Sans", "Sans-Bold", "Sans-Italic", "Sans-BoldItalic")
            for name, path in zip(names, paths):
                pdfmetrics.registerFont(TTFont(name, str(path)))
            pdfmetrics.registerFontFamily("Sans", normal=names[0], bold=names[1], italic=names[2], boldItalic=names[3])
            return names[0], names[1]
    return "Helvetica", "Helvetica-Bold"


REGULAR, BOLD = register_fonts()

BODY = ParagraphStyle("Body", fontName=REGULAR, fontSize=9.8, leading=14, textColor=INK,
                      spaceAfter=7, allowWidows=0, allowOrphans=0)
TITLE = ParagraphStyle("Title", parent=BODY, fontName=BOLD, fontSize=20, leading=25, spaceAfter=12)
H2 = ParagraphStyle("H2", parent=BODY, fontName=BOLD, fontSize=12, leading=16, textColor=BRAND,
                    spaceBefore=12, spaceAfter=6, keepWithNext=1)
H3 = ParagraphStyle("H3", parent=BODY, fontName=BOLD, fontSize=10.2, leading=14,
                    spaceBefore=6, spaceAfter=5, keepWithNext=1)
CELL = ParagraphStyle("Cell", parent=BODY, fontSize=9, leading=12, spaceAfter=0)
CELL_HEAD = ParagraphStyle("CellHead", parent=CELL, fontName=BOLD)
META_LABEL = ParagraphStyle("MetaLabel", parent=CELL, fontSize=7.5, leading=10, textColor=MUTED)
META_VALUE = ParagraphStyle("MetaValue", parent=CELL, fontSize=9.5, leading=12)

CLAUSE_INDENT = 30
META_LABELS = {
    "document": "Document ID",
    "version": "Version",
    "effective": "Effective date",
    "firmware": "Firmware covered",
    "published": "Published",
}


class NumberedCanvas(canvas.Canvas):
    """Adds "Page X of Y" once the total page count is known."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._saved_pages = []

    def showPage(self):
        self._saved_pages.append(dict(self.__dict__))
        self._startPage()

    def save(self):
        total = len(self._saved_pages)
        for state in self._saved_pages:
            self.__dict__.update(state)
            self.setFont(REGULAR, 8)
            self.setFillColor(MUTED)
            self.drawRightString(PAGE_W - MARGIN_X, FOOTER_Y, f"Page {self._pageNumber} of {total}")
            super().showPage()
        super().save()


def split_front_matter(text):
    meta = {}
    match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not match:
        return meta, text
    for line in match.group(1).splitlines():
        key, _, value = line.partition(":")
        meta[key.strip()] = value.strip()
    return meta, text[match.end():]


def inline(text):
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    text = re.sub(r"(\d) (GHz|°C|mm|g|a\.m\.|p\.m\.)(?=\W|$)", "\\1\u00a0\\2", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r'(^|[\s(])"', "\\1\u201c", text)
    text = text.replace('"', "\u201d").replace("'", "\u2019")
    return text


def parse_blocks(body):
    blocks = []
    lines = body.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].rstrip()
        if not line:
            i += 1
            continue
        if line.startswith("|"):
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                i += 1
            blocks.append(("table", rows))
            continue
        if line.startswith(">"):
            quoted = []
            while i < len(lines) and lines[i].startswith(">"):
                quoted.append(lines[i].lstrip(">").strip())
                i += 1
            blocks.append(("callout", " ".join(quoted)))
            continue
        heading = re.match(r"^(#{1,3}) (.+)", line)
        if heading:
            blocks.append((f"h{len(heading.group(1))}", heading.group(2)))
        elif line.startswith("- "):
            blocks.append(("bullet", None, line[2:]))
        elif re.match(r"^\d+\. ", line):
            number, text = line.split(" ", 1)
            blocks.append(("step", number, text))
        else:
            para = [line]
            while i + 1 < len(lines) and lines[i + 1].strip() and not re.match(r"^(#|- |\d+\. |\||>)", lines[i + 1]):
                i += 1
                para.append(lines[i].strip())
            text = " ".join(para)
            clause = re.match(r"^(\d+\.\d+|\([a-z]\)) (.+)", text)
            if clause:
                kind = "lettered" if clause.group(1).startswith("(") else "clause"
                blocks.append((kind, clause.group(1), clause.group(2)))
            else:
                blocks.append(("para", None, text))
        i += 1
    return blocks


def build_table(rows, width):
    header, separator, data = rows[0], rows[1], rows[2:]
    weights = [max(len(cell), 3) for cell in separator]
    col_widths = [width * w / sum(weights) for w in weights]
    cells = [[Paragraph(inline(c), CELL_HEAD) for c in header]]
    cells += [[Paragraph(inline(c), CELL) for c in row] for row in data]
    table = Table(cells, colWidths=col_widths, repeatRows=1, hAlign="LEFT")
    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), SHADE),
        ("LINEABOVE", (0, 0), (-1, 0), 0.8, BRAND),
        ("LINEBELOW", (0, 0), (-1, 0), 0.6, RULE),
        ("LINEBELOW", (0, 1), (-1, -1), 0.4, RULE),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 5),
        ("RIGHTPADDING", (0, 0), (-1, -1), 5),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
    ]))
    return table


def build_callout(text, width):
    caution = text.lower().startswith(("**caution", "**warning"))
    box = Table([[Paragraph(inline(text), ParagraphStyle("Callout", parent=CELL, fontSize=9.4, leading=13))]],
                colWidths=[width], hAlign="LEFT")
    box.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), CAUTION_FILL if caution else NOTE_FILL),
        ("LINEBEFORE", (0, 0), (0, -1), 2.5, CAUTION if caution else BRAND),
        ("LEFTPADDING", (0, 0), (-1, -1), 10),
        ("RIGHTPADDING", (0, 0), (-1, -1), 10),
        ("TOPPADDING", (0, 0), (-1, -1), 7),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
    ]))
    return box


def title_block(title, meta, width):
    keys = [k for k in META_LABELS if k in meta]
    table = Table(
        [[Paragraph(META_LABELS[k], META_LABEL) for k in keys], [Paragraph(inline(meta[k]), META_VALUE) for k in keys]],
        colWidths=[width / len(keys)] * len(keys), hAlign="LEFT",
    )
    table.setStyle(TableStyle([
        ("LINEABOVE", (0, 0), (-1, 0), 1, BRAND),
        ("LINEBELOW", (0, -1), (-1, -1), 0.5, RULE),
        ("LEFTPADDING", (0, 0), (-1, -1), 0),
        ("TOPPADDING", (0, 0), (-1, 0), 6),
        ("BOTTOMPADDING", (0, -1), (-1, -1), 7),
    ]))
    return [Paragraph(inline(title), TITLE), table, Spacer(1, 16)]


def build_story(blocks, meta, width):
    story, title = [], COMPANY
    uses_clauses = any(b[0] == "clause" for b in blocks)
    indent = 0

    def indented(flowable):
        if indent:
            return [Indenter(left=indent), flowable, Indenter(left=-indent)]
        return [flowable]

    def with_lead_in(flowable):
        # Headings and introductory paragraphs move to the next page with the table they introduce.
        lead = []
        while not indent and story and isinstance(story[-1], Paragraph) and story[-1].getKeepWithNext():
            lead.insert(0, story.pop())
        return KeepTogether(lead + [flowable])

    for n, block in enumerate(blocks):
        kind = block[0]
        following = blocks[n + 1][0] if n + 1 < len(blocks) else None
        if kind == "h1":
            title = block[1]
            story += title_block(title, meta, width)
        elif kind == "h2":
            indent = CLAUSE_INDENT if uses_clauses else 0
            story.append(Paragraph(inline(block[1]), H2))
        elif kind == "h3":
            story.append(Paragraph(inline(block[1]), H3))
        elif kind == "table":
            table = build_table(block[1], width - indent)
            table.spaceAfter = 10
            story += indented(with_lead_in(table))
        elif kind == "callout":
            box = build_callout(block[1], width - indent)
            box.spaceAfter = 10
            story += indented(box)
        elif kind == "clause":
            style = ParagraphStyle("Clause", parent=BODY, leftIndent=CLAUSE_INDENT, bulletIndent=0)
            story.append(Paragraph(inline(block[2]), style, bulletText=block[1]))
        elif kind in ("bullet", "step", "lettered"):
            last = following != kind
            gap = {"lettered": 26}.get(kind, 16)
            style = ParagraphStyle(kind, parent=BODY, leftIndent=indent + gap, bulletIndent=indent + 2,
                                   spaceAfter=7 if last else 3)
            marker = "\u2022" if kind == "bullet" else block[1]
            story.append(Paragraph(inline(block[2]), style, bulletText=marker))
        else:
            style = ParagraphStyle("Para", parent=BODY, leftIndent=indent, keepWithNext=int(following == "table"))
            story.append(Paragraph(inline(block[2]), style))
    return story, title


def page_decorations(meta, short_title):
    reference = meta.get("document", "")
    if "version" in meta:
        reference += f"  |  Version {meta['version']}"
    elif "firmware" in meta:
        reference += f"  |  Firmware {meta['firmware']}"

    def footer(c):
        c.setStrokeColor(RULE)
        c.setLineWidth(0.5)
        c.line(MARGIN_X, FOOTER_Y + 12, PAGE_W - MARGIN_X, FOOTER_Y + 12)
        c.setFont(REGULAR, 7.2)
        c.setFillColor(MUTED)
        c.drawString(MARGIN_X, FOOTER_Y, meta.get("notice", ""))

    def first_page(c, doc):
        c.saveState()
        c.setFont(BOLD, 13)
        c.setFillColor(BRAND)
        c.drawString(MARGIN_X, HEADER_Y - 4, COMPANY)
        footer(c)
        c.restoreState()

    def later_pages(c, doc):
        c.saveState()
        c.setFont(BOLD, 8.5)
        c.setFillColor(BRAND)
        c.drawString(MARGIN_X, HEADER_Y, COMPANY)
        c.setFont(REGULAR, 8)
        c.setFillColor(MUTED)
        c.drawRightString(PAGE_W - MARGIN_X, HEADER_Y, f"{short_title}  |  {reference}")
        c.setStrokeColor(RULE)
        c.setLineWidth(0.5)
        c.line(MARGIN_X, HEADER_Y - 6, PAGE_W - MARGIN_X, HEADER_Y - 6)
        footer(c)
        c.restoreState()

    return first_page, later_pages


def render(md_path):
    meta, body = split_front_matter(md_path.read_text(encoding="utf-8"))
    width = PAGE_W - 2 * MARGIN_X
    story, title = build_story(parse_blocks(body), meta, width)
    short_title = title[len(COMPANY) + 1:] if title.startswith(COMPANY + " ") else title

    subject = meta.get("document", "")
    if "version" in meta:
        subject += f", Version {meta['version']}"

    out = OUT / f"{md_path.stem}.pdf"
    doc = BaseDocTemplate(str(out), pagesize=LETTER, title=title, author=COMPANY, subject=subject,
                          creator=f"{COMPANY} Document Control", keywords=[meta.get("document", "")], lang="en-US")
    frame = Frame(MARGIN_X, MARGIN_BOTTOM, width, PAGE_H - MARGIN_TOP - MARGIN_BOTTOM,
                  leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0)
    first_page, later_pages = page_decorations(meta, short_title)
    doc.addPageTemplates([
        PageTemplate(id="first", frames=[frame], onPage=first_page, autoNextPageTemplate="later"),
        PageTemplate(id="later", frames=[frame], onPage=later_pages),
    ])
    doc.build(story, canvasmaker=NumberedCanvas)
    return out


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for md in sorted(SRC.glob("*.md")):
        print(render(md).relative_to(ROOT))
