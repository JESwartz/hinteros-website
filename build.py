"""Build the HinterOS.org static site.

Renders the pages in src/ into an output directory: each page gets the shared header and footer,
and {{name}} placeholders are filled from release.json (the manifest publish-iso writes). The
docs pages come from the hinteros-docs repo (--docs): its pages.toml gives the order, and each
Markdown page is rendered and wrapped in src/_docs.html with the docs sidebar and previous/next
links. The launcher screenshots (--shots, WebP files made from the docs repo's images/) go to
/img/shots/. The launcher web demo, when given, is copied verbatim to /demo/.

  python3 build.py --release release.json --docs <hinteros-docs> --shots <dir> --out _site \
    [--demo <dir>] [--preview]

Each page gets a canonical URL, Open Graph tags and a sitemap entry, from its <title> and
description. --preview asks search engines not to index the site (robots.txt), for builds from
example data.
"""

import argparse
import html
import json
import re
import shutil
import sys
import tomllib
from pathlib import Path

import markdown

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
PAGES = ["index.html", "try.html", "download.html", "contact.html", "404.html"]
NAV = [("/try/", "Demo"), ("/docs/", "Docs"), ("/contact/", "Contact"), ("/download/", "Download")]
SITE = "https://hinteros.org"
FORGE = "https://git.hinteros.org"
GITHUB = "https://github.com/JESwartz"


def fail(msg):
    sys.exit(f"build.py: {msg}")


def load_release(path):
    try:
        rel = json.loads(Path(path).read_text())
    except (OSError, ValueError) as e:
        fail(f"cannot read {path}: {e}")
    for key in ("version", "channel", "date", "commit", "source", "iso", "sha256sums_url",
                "signature_url", "signer", "notes"):
        if key not in rel:
            fail(f"{path}: missing '{key}'")
    iso = rel["iso"]
    for key in ("name", "url", "size", "sha256"):
        if key not in iso:
            fail(f"{path}: missing 'iso.{key}'")
    if not re.fullmatch(r"[0-9a-f]{64}", iso["sha256"]):
        fail(f"{path}: iso.sha256 is not 64 lowercase hex digits")
    if not re.fullmatch(r"[0-9a-f]{40}", rel["commit"]):
        fail(f"{path}: commit is not a full 40-digit sha")
    return rel


def copytree(src, dest):
    # Inputs come from the read-only Nix store: copy contents, not permissions.
    shutil.copytree(src, dest, copy_function=shutil.copyfile)
    for d in [dest, *Path(dest).rglob("*")]:
        if Path(d).is_dir():
            Path(d).chmod(0o755)


def gib(size):
    return f"{size / 1024**3:.1f} GiB"


def fields(rel):
    iso = rel["iso"]
    esc = html.escape
    return {
        "version": esc(rel["version"]),
        "channel": esc(rel["channel"]),
        "date": esc(rel["date"]),
        "commit": esc(rel["commit"]),
        "commit_short": esc(rel["commit"][:12]),
        "source_url": esc(rel["source"]),
        "iso_name": esc(iso["name"]),
        "iso_url": esc(iso["url"]),
        "iso_size": gib(iso["size"]),
        "iso_bytes": f"{iso['size']:,}",
        "sha256": esc(iso["sha256"]),
        "sha256sums_url": esc(rel["sha256sums_url"]),
        "signature_url": esc(rel["signature_url"]),
        "signer_principal": esc(rel["signer"]["principal"]),
        "signer_namespace": esc(rel["signer"]["namespace"]),
        "signer_fingerprint": esc(rel["signer"]["fingerprint"]),
        "allowed_signers_url": esc(
            f"{FORGE}/hinteros/raw/commit/{rel['commit']}/release/allowed_signers"),
        # The notes come from release/notes.md in the signed release commit.
        "notes": markdown.markdown(rel["notes"]),
        "forge": FORGE,
        "github": GITHUB,
    }


def url_of(page):
    return {"index.html": "/", "404.html": None}.get(page, f"/{page.removesuffix('.html')}/")


def doc_url(slug):
    return "/docs/" if slug == "index" else f"/docs/{slug}/"


def nav(current):
    # A docs page marks "Docs" as the section it is in; only its overview is that very page.
    items = []
    for href, label in NAV:
        attr = ""
        if href == current:
            attr = ' aria-current="page"'
        elif current and href != "/" and current.startswith(href):
            attr = ' aria-current="true"'
        items.append(f'<a href="{href}"{attr}>{label}</a>')
    return "\n        ".join(items)


# Controller buttons in the docs: <kbd>A</kbd> shows as a round face button, the others as bars.
PAD_ROUND = {"A", "B", "X", "Y"}
PAD_BAR = {"LB", "RB", "LT", "RT", "Guide", "View", "Menu"}


def slugify(text, sep="-"):
    # The same heading anchors as Forgejo and hinteros-docs/check.py.
    return re.sub(r"[^\w\- ]", "", text.lower()).strip().replace(" ", sep)


class Docs:
    """The hinteros-docs repo: pages in pages.toml order, rendered to HTML fragments."""

    def __init__(self, root):
        self.root = Path(root)
        try:
            pages = tomllib.loads((self.root / "pages.toml").read_text())["page"]
        except (OSError, ValueError, KeyError) as e:
            fail(f"--docs {root}: cannot read pages.toml: {e}")
        self.pages = {}  # slug -> (title, description, summary, markdown body)
        for p in pages:
            slug = p["slug"]
            try:
                text = (self.root / "pages" / f"{slug}.md").read_text()
            except OSError as e:
                fail(f"docs: {e}")
            m = re.match(r"\s*# (.+)\n\s*<!-- description: (.+?) -->\n", text)
            if not m:
                fail(f"docs: pages/{slug}.md must start with a title and a description comment")
            self.pages[slug] = (m.group(1).strip(), m.group(2), p["summary"], text[m.end():])
        self.order = [("index", "Overview")] + [(s, v[0]) for s, v in self.pages.items()]

    def index(self):
        topics = "\n".join(
            f'        <li><a href="{doc_url(s)}"><strong>{html.escape(t)}</strong>'
            f"<span>{html.escape(summary)}</span></a></li>"
            for s, (t, _, summary, _) in self.pages.items())
        content = (
            '      <p class="lede">Instructions to install and use HinterOS. For development '
            'information, refer to the READMEs in the <a href="{{forge}}">source repositories</a>.'
            f'</p>\n      <ul class="topics">\n{topics}\n      </ul>\n')
        return ("Documentation", "Instructions to install and use HinterOS.", content)

    def page(self, slug):
        title, description, _, body = self.pages[slug]
        steps = body.lstrip().startswith("<!-- steps -->")
        out = markdown.markdown(
            body, extensions=["tables", "fenced_code", "toc"],
            extension_configs={"toc": {"slugify": slugify}})
        out = re.sub(r"<!--.*?-->", "", out, flags=re.S)

        def link(m):
            target = m.group(1)
            if target.startswith("../images/"):
                return f'href="/docs/images/{target[10:]}"'
            path, _, frag = target.partition("#")
            if re.fullmatch(r"[a-z0-9-]+\.md", path):
                return f'href="{doc_url(path[:-3])}' + (f"#{frag}" if frag else "") + '"'
            return m.group(0)

        out = re.sub(r'href="([^"]+)"', link, out)
        out = re.sub(r'src="\.\./images/([^"]+)"', r'src="/docs/images/\1"', out)

        def alert(m):
            kind = " warn" if m.group(1) == "WARNING" else ""
            return f'<div class="callout{kind}" role="note">\n<p>{m.group(2)}</div>'

        out = re.sub(r"<blockquote>\s*<p>\[!(WARNING|NOTE)\]\s*(.*?)</blockquote>", alert, out,
                     flags=re.S)
        out = re.sub(r"<kbd>([^<]+)</kbd>", lambda m: (
            f'<span class="pad-btn">{m.group(1)}</span>' if m.group(1) in PAD_ROUND else
            f'<span class="pad-btn bar">{m.group(1)}</span>' if m.group(1) in PAD_BAR else
            m.group(0)), out)
        out = out.replace("<table>", '<table class="controls">')
        # The text before the first heading is the lede.
        first_h2 = out.find("<h2")
        if out.lstrip().startswith("<p>") and (first_h2 < 0 or out.find("<p>") < first_h2):
            out = out.replace("<p>", '<p class="lede">', 1)
        if steps:
            head, _, rest = out.partition("<h2")
            parts = ["<h2" + x for x in rest.split("<h2")] if rest else []
            out = head + '<ol class="steps">\n' + "".join(
                f"<li>\n{x}</li>\n" for x in parts) + "</ol>\n"
        # Placeholders belong to the site's own pages; docs text is literal.
        return (title, description, out.replace("{{", "&#123;&#123;"))


def docs_nav(docs, slug):
    items = []
    for s, title in docs.order:
        attr = ' aria-current="page"' if s == slug else ""
        items.append(f'<li><a href="{doc_url(s)}"{attr}>{html.escape(title)}</a></li>')
    return "\n".join(items)


def docs_pager(docs, slug):
    order = docs.order
    i = [s for s, _ in order].index(slug)
    links = []
    if i > 0:
        s, t = order[i - 1]
        links.append(f'<a class="prev" href="{doc_url(s)}"><span>Previous</span>{html.escape(t)}</a>')
    if i + 1 < len(order):
        s, t = order[i + 1]
        links.append(f'<a class="next" href="{doc_url(s)}"><span>Next</span>{html.escape(t)}</a>')
    return "\n      ".join(links)


def doc_page(docs, slug):
    title, description, content = docs.index() if slug == "index" else docs.page(slug)
    layout = (SRC / "_docs.html").read_text()
    for key, value in {
        "doc_title": html.escape(title),
        "doc_head_title": "HinterOS documentation" if slug == "index"
        else f"{html.escape(title)}: HinterOS documentation",
        "doc_description": html.escape(description),
        "docs_nav": docs_nav(docs, slug),
        "docs_pager": docs_pager(docs, slug),
        "doc_content": content,
    }.items():
        layout = layout.replace("{{" + key + "}}", value)
    return layout


def seo(text, url, version):
    """Head tags for search engines and link previews: canonical, Open Graph and, on the home
    page, JSON-LD. A page without a URL (404) is kept out of the index."""
    if url is None:
        return '<meta name="robots" content="noindex">'
    title = re.search(r"<title>(.*?)</title>", text).group(1)
    desc = re.search(r'<meta name="description" content="(.*?)">', text).group(1)
    tags = [
        f'<link rel="canonical" href="{SITE}{url}">',
        '<meta property="og:type" content="website">',
        '<meta property="og:site_name" content="HinterOS">',
        f'<meta property="og:title" content="{title}">',
        f'<meta property="og:description" content="{desc}">',
        f'<meta property="og:url" content="{SITE}{url}">',
        f'<meta property="og:image" content="{SITE}/social.png">',
        '<meta property="og:image:width" content="1200">',
        '<meta property="og:image:height" content="630">',
        '<meta property="og:image:alt" content="The HinterOS Home screen on a TV.">',
        '<meta name="twitter:card" content="summary_large_image">',
        '<meta name="theme-color" content="#0e1118">',
    ]
    if url == "/":
        data = {
            "@context": "https://schema.org",
            "@graph": [
                {"@type": "WebSite", "name": "HinterOS", "url": f"{SITE}/"},
                {
                    "@type": "SoftwareApplication",
                    "name": "HinterOS",
                    "description": html.unescape(desc),
                    "url": f"{SITE}/",
                    "applicationCategory": "OperatingSystem",
                    "operatingSystem": "Linux",
                    "softwareVersion": html.unescape(version),
                    "downloadUrl": f"{SITE}/download/",
                    "image": f"{SITE}/social.png",
                    "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
                },
            ],
        }
        ld = json.dumps(data, indent=2).replace("</", "<\\/")
        tags.append(f'<script type="application/ld+json">\n{ld}\n</script>')
    return "\n  ".join(tags)


def sitemap(urls):
    entries = "".join(f"  <url><loc>{SITE}{u}</loc></url>\n" for u in urls)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
            f"{entries}</urlset>\n")


def render(page, values, demo, text=None, current=None):
    if text is None:
        text = (SRC / page).read_text()
        current = url_of(page)
    header = (SRC / "_header.html").read_text().replace("{{nav}}", nav(current))
    text = text.replace("{{header}}", header)
    text = text.replace("{{footer}}", (SRC / "_footer.html").read_text())
    # try.html has one block for a built demo and one for "not built yet".
    keep, drop = ("demo", "nodemo") if demo else ("nodemo", "demo")
    text = re.sub(rf"<!-- {drop} -->.*?<!-- /{drop} -->", "", text, flags=re.S)
    text = text.replace(f"<!-- {keep} -->", "").replace(f"<!-- /{keep} -->", "")

    def sub(m):
        if m.group(1) not in values:
            fail(f"{page}: unknown placeholder {{{{{m.group(1)}}}}}")
        return values[m.group(1)]

    text = re.sub(r"\{\{([a-z_0-9]+)\}\}", sub, text)
    icon = '  <link rel="icon"'
    return text.replace(icon, f"  {seo(text, current, values['version'])}\n{icon}", 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--release", required=True)
    ap.add_argument("--docs", required=True, help="the hinteros-docs repo")
    ap.add_argument("--shots", required=True, help="the launcher screenshots as .webp")
    ap.add_argument("--out", required=True)
    ap.add_argument("--demo")
    ap.add_argument("--fonts", help="directory of .woff2 files for /fonts/")
    ap.add_argument("--preview", action="store_true")
    args = ap.parse_args()

    values = fields(load_release(args.release))
    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    urls = []
    for page in PAGES:
        target = {"index.html": "index.html", "404.html": "404.html"}.get(
            page, f"{page.removesuffix('.html')}/index.html")
        dest = out / target
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(render(page, values, args.demo))
        if url_of(page):
            urls.append(url_of(page))

    docs = Docs(args.docs)
    for slug, _ in docs.order:
        dest = out / doc_url(slug).strip("/") / "index.html"
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(render(f"docs/{slug}", values, args.demo,
                               text=doc_page(docs, slug), current=doc_url(slug)))
        urls.append(doc_url(slug))
    if (docs.root / "images").is_dir():
        copytree(docs.root / "images", out / "docs" / "images")

    for static in ("style.css", "site.js", "favicon.svg", "social.png", "_headers"):
        shutil.copyfile(SRC / static, out / static)
    shutil.copyfile(args.release, out / "release.json")
    copytree(args.shots, out / "img" / "shots")
    if args.fonts:
        copytree(args.fonts, out / "fonts")
    if args.demo:
        if not (Path(args.demo) / "index.html").is_file():
            fail(f"--demo {args.demo}: no index.html at its root")
        copytree(args.demo, out / "demo")
    (out / "sitemap.xml").write_text(sitemap(urls))
    (out / "robots.txt").write_text(
        "User-agent: *\nDisallow: /\n" if args.preview
        else f"User-agent: *\nAllow: /\n\nSitemap: {SITE}/sitemap.xml\n")


if __name__ == "__main__":
    main()
