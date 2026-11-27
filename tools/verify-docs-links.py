#!/usr/bin/env python3

import argparse
import re
import subprocess
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote, urlsplit


LINK_PATTERN = re.compile(
    r"(?<!\\)\[[^\]]*\]\("
    r"\s*(?:<(?P<angle>[^>]*)>|(?P<plain>[^)\s]+))"
    r"(?:\s+(?:\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|\((?:\\.|[^)\\])*\)))?"
    r"\s*\)"
)
HEADING_PATTERN = re.compile(r"^ {0,3}(#{1,6})\s+(?P<text>.*?)(?:\s+#+)?\s*$")
SETEXT_PATTERN = re.compile(r"^ {0,3}(?:=+|-+)\s*$")
FENCE_PATTERN = re.compile(r"^ {0,3}((?:`{3,}|~{3,}))")


@dataclass(frozen=True)
class BrokenLink:
    path: str
    line: int
    target: str
    reason: str


def tracked_markdown_files() -> list[Path]:
    output = subprocess.check_output(
        ["git", "ls-files", "-z", "*.md"], text=False
    )
    return sorted(
        Path(item)
        for item in output.decode("utf-8").split("\0")
        if item
    )


def heading_text(raw_text: str) -> str:
    text = raw_text.strip()
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\[[^\]]*\]", r"\1", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"[*_~]+", "", text)
    text = re.sub(r"\\(.)", r"\1", text)
    return text.strip()


def github_slug(text: str) -> str:
    value = text.strip().lower()
    characters = []
    for character in value:
        category = unicodedata.category(character)
        if character.isspace() or category.startswith("P") or category.startswith("S"):
            characters.append(" " if character.isspace() else "")
        else:
            characters.append(character)
    return "".join(characters).replace(" ", "-")


def heading_slugs(path: Path) -> set[str]:
    slugs: set[str] = set()
    counts: dict[str, int] = {}
    in_fence = False
    fence_marker = ""
    lines = path.read_text(encoding="utf-8").splitlines()
    previous_text = ""

    for line in lines:
        fence = FENCE_PATTERN.match(line)
        if fence:
            marker = fence.group(1)
            if not in_fence:
                in_fence = True
                fence_marker = marker[0]
            elif marker[0] == fence_marker:
                in_fence = False
            previous_text = ""
            continue
        if in_fence:
            continue

        heading = HEADING_PATTERN.match(line)
        if heading:
            slug = github_slug(heading_text(heading.group("text")))
        elif (
            previous_text
            and SETEXT_PATTERN.match(line)
            and not HEADING_PATTERN.match(previous_text)
        ):
            slug = github_slug(heading_text(previous_text))
        else:
            previous_text = line.strip() if line.strip() and not line.startswith(("-", "*", "+", ">")) else ""
            continue

        if not slug:
            previous_text = ""
            continue
        count = counts.get(slug, 0)
        counts[slug] = count + 1
        slugs.add(slug if count == 0 else f"{slug}-{count}")
        previous_text = ""

    return slugs


def link_target(link: str) -> str:
    return link[1:-1] if link.startswith("<") and link.endswith(">") else link


def validate_links(path: Path) -> list[BrokenLink]:
    broken: list[BrokenLink] = []
    lines = path.read_text(encoding="utf-8").splitlines()
    for line_number, line in enumerate(lines, start=1):
        for match in LINK_PATTERN.finditer(line):
            target = link_target(match.group("angle") or match.group("plain"))
            target = target.replace("\\(", "(").replace("\\)", ")").replace("\\ ", " ")
            parsed = urlsplit(target)
            if parsed.scheme or parsed.netloc or not target or target.startswith("#"):
                continue

            raw_fragment = parsed.fragment
            candidate = Path(unquote(target.split("#", 1)[0].split("?", 1)[0]))
            if not candidate.is_absolute():
                resolved = path.parent / candidate
            else:
                resolved = Path(*candidate.parts[1:])

            if not resolved.is_file():
                broken.append(
                    BrokenLink(path.as_posix(), line_number, target, "file does not exist")
                )
                continue

            if raw_fragment:
                fragment = unquote(raw_fragment)
                slugs = heading_slugs(resolved)
                if fragment not in slugs:
                    broken.append(
                        BrokenLink(
                            path.as_posix(),
                            line_number,
                            target,
                            "anchor does not match a heading",
                        )
                    )
    return broken


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Verify links in tracked Markdown files.")
    parser.add_argument("paths", nargs="*", help="Optional tracked Markdown paths to check")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.paths:
        selected = {Path(value).as_posix() for value in args.paths}
        files = [path for path in tracked_markdown_files() if path.as_posix() in selected]
        missing = sorted(selected - {path.as_posix() for path in files})
        if missing:
            print("ERROR: untracked or non-Markdown paths: " + ", ".join(missing))
            return 2
    else:
        files = tracked_markdown_files()

    link_count = 0
    broken: list[BrokenLink] = []
    for path in files:
        path_links = validate_links(path)
        link_count += len(LINK_PATTERN.findall(path.read_text(encoding="utf-8")))
        broken.extend(path_links)

    print(f"Checked {len(files)} Markdown files and {link_count} links.")
    if broken:
        for item in broken:
            print(f"{item.path}:{item.line}: {item.target}: {item.reason}")
        print(f"FAILED: {len(broken)} broken link(s).")
        return 1
    print("PASS: all links are valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
