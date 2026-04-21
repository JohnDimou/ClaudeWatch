#!/usr/bin/env python3
"""
get_claude_usage.py - Fetches Claude Code usage statistics

This script runs the Claude CLI interactively, sends the /usage command,
and parses the output to extract usage percentages, reset times, and the
"Last 24h" behavioral characteristics section.

Requirements:
    - Python 3.6+
    - Claude Code CLI installed and accessible in PATH

Output:
    JSON object with the following fields:
    - session_percent (int): Current session usage percentage (0-100)
    - session_reset (str): Human-readable session reset time
    - weekly_percent (int): Weekly usage percentage for all models (0-100)
    - weekly_reset (str): Human-readable weekly reset time
    - sonnet_percent (int): Weekly usage percentage for Sonnet (0-100)
    - sonnet_reset (str): Human-readable Sonnet reset time (independent of all-models)
    - insights (list): Dynamic array of Last-24h insight objects, each with:
        - percent (int): Percentage value (0-100)
        - title (str): Short title as rendered by the CLI
        - description (str): Follow-up explanation (may be empty)
    - raw (str): Cleaned tail of output for debugging
    - error (str): Error message if something went wrong (absent on success)

License: MIT
Author: John Dimou - OptimalVersion.io
"""

import subprocess
import time
import os
import pty
import select
import re
import json
import sys
import shutil
import fcntl
import termios
import struct


# ---------------------------------------------------------------------------
# CLI discovery + capture
# ---------------------------------------------------------------------------

def find_claude_cli():
    """Finds the Claude CLI executable in common installation paths."""
    claude_path = shutil.which('claude')
    if claude_path:
        return claude_path

    home = os.path.expanduser('~')
    possible_paths = [
        f'{home}/.local/bin/claude',
        '/usr/local/bin/claude',
        '/opt/homebrew/bin/claude',
        f'{home}/.npm-global/bin/claude',
        '/usr/bin/claude',
    ]
    for path in possible_paths:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def get_usage():
    """
    Runs Claude CLI interactively and captures /usage output.

    Uses a pseudo-terminal sized to 200 cols so the /usage box renders
    fully (default 80-col PTY truncates the right column, which loses
    the percentage on some rows).

    Returns the raw byte stream decoded as UTF-8.
    """
    claude_path = find_claude_cli()
    if not claude_path:
        raise FileNotFoundError(
            "Claude CLI not found. Please install it from https://claude.ai/code"
        )

    master, slave = pty.openpty()

    # Size the pty wide enough that the /usage box is not truncated.
    # rows=50, cols=200, xpixel=0, ypixel=0
    try:
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 50, 200, 0, 0))
    except OSError:
        pass

    proc = subprocess.Popen(
        [claude_path],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
        env={
            **{k: v for k, v in os.environ.items() if k != 'CLAUDECODE'},
            'TERM': 'xterm-256color',
            'COLUMNS': '200',
            'LINES': '50',
        },
    )

    os.close(slave)

    output = b""

    def read_all(timeout_sec):
        nonlocal output
        start = time.time()
        while time.time() - start < timeout_sec:
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                try:
                    data = os.read(master, 8192)
                    if data:
                        output += data
                except OSError:
                    break

    # Wait for Claude to fully initialize
    time.sleep(3)
    read_all(2)

    # Dismiss any first-launch selectors (theme, permissions)
    output_str = output.decode('utf-8', errors='ignore').lower()
    selector_patterns = ['select a theme', 'choose a theme', 'select permission']
    if any(pattern in output_str for pattern in selector_patterns):
        os.write(master, b"\r")
        time.sleep(0.5)
        read_all(2)

    # Send /usage, accept autocomplete, execute
    os.write(master, b"/usage")
    time.sleep(0.8)
    read_all(0.5)
    os.write(master, b"\t")
    time.sleep(0.3)
    read_all(0.3)
    os.write(master, b"\r")

    # Wait until the "Last 24h" section renders (signal of full output)
    # or up to 20 seconds, whichever comes first. Then read a little more
    # to let the final box settle.
    deadline = time.time() + 20
    saw_last_24h = False
    while time.time() < deadline:
        read_all(1)
        probe = re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]', '', output.decode('utf-8', errors='ignore'))
        probe = re.sub(r'[^\x20-\x7E\n]', ' ', probe)
        if re.search(r'last\s*24\s*h', probe, re.IGNORECASE):
            saw_last_24h = True
            read_all(3)
            break

    # If Last 24h never appeared, still wait a total of ~12s for main data
    if not saw_last_24h:
        read_all(6)

    # Clean up
    try:
        proc.terminate()
        proc.wait(timeout=2)
    except (subprocess.TimeoutExpired, ProcessLookupError):
        try:
            proc.kill()
        except ProcessLookupError:
            pass

    os.close(master)

    return output.decode('utf-8', errors='ignore')


# ---------------------------------------------------------------------------
# Parsing helpers
# ---------------------------------------------------------------------------

def _clean_ansi(text):
    """Strip ANSI, OSC, and other escape sequences; normalize whitespace.

    The Claude CLI draws its /usage box with cursor-positioning sequences
    (e.g. `\\x1b[12C` = cursor forward 12 cells). If we simply strip those,
    we lose the visual spacing between columns and words collide into
    each other ("usagecamefrom..."). Replace them with equivalent runs
    of real spaces BEFORE the strip pass so word boundaries survive.
    """
    # Cursor forward N cells → N spaces
    t = re.sub(
        r'\x1b\[(\d+)C',
        lambda m: ' ' * min(int(m.group(1)), 120),
        text,
    )
    # Absolute column move `\x1b[NG` → rough approximation: inject a space
    # so words on either side don't collide (exact column isn't important
    # for parsing, just word separation).
    t = re.sub(r'\x1b\[\d+G', ' ', t)
    # Cursor up/down/back — treat as separators
    t = re.sub(r'\x1b\[\d*[ABDEFHfdn]', ' ', t)
    # Now strip the remaining CSI, OSC, and 2-byte escape sequences
    t = re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]', '', t)
    t = re.sub(r'\x1b\][^\x07\x1b]*[\x07]?', '', t)
    t = re.sub(r'\x1b[<>=]', '', t)
    t = re.sub(r'[^\x20-\x7E\n]', ' ', t)
    t = re.sub(r' +', ' ', t)
    return t


def _last_match_before(pattern, text, before_pos):
    """Last occurrence of pattern within text[:before_pos], or None."""
    matches = list(re.finditer(pattern, text[:before_pos], re.IGNORECASE))
    return matches[-1] if matches else None


def _extract_percent(block):
    """Extract a usage percentage (0-100) from a section block.

    Prefers 'XX% used' form; falls back to a lone 'XX%'. Ignores any match
    that is clearly part of a Last-24h sentence.
    """
    if not block:
        return 0
    # Strong form: "XX% used"
    m = re.search(r'(\d{1,3})\s*%\s*used', block, re.IGNORECASE)
    if m and int(m.group(1)) <= 100:
        return int(m.group(1))
    # Lone percentage, but skip patterns that look like the Last-24h bullets
    # (those contain "of your usage").
    for m in re.finditer(r'(\d{1,3})\s*%', block):
        # Check a short context window around the match
        lo = max(0, m.start() - 40)
        hi = min(len(block), m.end() + 40)
        ctx = block[lo:hi].lower()
        if 'of your usage' in ctx or 'came from' in ctx:
            continue
        val = int(m.group(1))
        if 0 <= val <= 100:
            return val
    return 0


def _extract_reset(block, allow_date=True):
    """Extract a reset time string from a section block.

    When allow_date is True, prefers forms like 'Apr 24 at 12am (TZ)';
    otherwise extracts a time-only form like '1pm (Europe/Athens)'.
    Handles spacing irregularities caused by ANSI stripping.
    """
    if not block:
        return ""

    if allow_date:
        # Full form: "Resets Apr 24 at 12am (Europe/Athens)"
        m = re.search(
            r'resets?\s*((?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?'
            r'\s*\d{1,2}\s*(?:at\s*)?\s*\d{1,2}(?::\d{2})?\s*[ap]m'
            r'\s*\([^)]+\))',
            block,
            re.IGNORECASE,
        )
        if m:
            return _tidy_reset(m.group(1))

        # Date without "resets" prefix (box may have split 'Resets' onto
        # a neighboring cell so it got lost during cleaning).
        m = re.search(
            r'((?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?'
            r'\s*\d{1,2}\s*(?:at\s*t?\s*)?\s*\d{1,2}(?::\d{2})?\s*[ap]m'
            r'\s*\([^)]+\))',
            block,
            re.IGNORECASE,
        )
        if m:
            return _tidy_reset(m.group(1))

    # Time-only form (session): "Resets 1pm (Europe/Athens)"
    m = re.search(
        r'resets?\s*(\d{1,2}(?::\d{2})?\s*[ap]m\s*\([^)]+\))',
        block,
        re.IGNORECASE,
    )
    if m:
        return _tidy_reset(m.group(1))

    m = re.search(
        r'(\d{1,2}(?::\d{2})?\s*[ap]m\s*\([^)]+\))',
        block,
        re.IGNORECASE,
    )
    if m:
        return _tidy_reset(m.group(1))

    return ""


def _tidy_reset(s):
    """Fix common spacing artefacts so Swift can parse the reset cleanly."""
    s = s.strip()
    # "Apr24at12am" → "Apr 24 at 12am"
    s = re.sub(r'([A-Za-z]+)(\d)', r'\1 \2', s)
    s = re.sub(r'(\d)\s*at\s*(\d)', r'\1 at \2', s, flags=re.IGNORECASE)
    # "12am(Europe/Athens)" → "12am (Europe/Athens)"
    s = re.sub(r'([ap]m)\s*\(', r'\1 (', s, flags=re.IGNORECASE)
    # Correct "Apr 24 t 2pm" typo variant seen in degraded renders
    s = re.sub(r'\b(\d{1,2})\s+t\s+(\d{1,2})', r'\1 at \2', s)
    s = re.sub(r' +', ' ', s)
    return s


def _tidy_desc(s):
    """Cleanup a Last-24h description string for display."""
    if not s:
        return ""
    s = s.strip()
    # Cut at the next percentage bullet or footer hints
    s = re.split(
        r'\d+\s*%\s*of\s*your\s*usage'
        r'|\bd\s*to\s*day\b'
        r'|\bw\s*to\s*week\b'
        r'|\besc\s*to\s*cancel\b'
        r'|\brefreshing\b',
        s,
        maxsplit=1,
        flags=re.IGNORECASE,
    )[0]
    s = re.sub(r' +', ' ', s).strip(' .,')
    # Trailing period for readability if it ends mid-sentence
    if s and s[-1] not in '.!?':
        s += '.'
    return s


def _reflow(text):
    """Insert spaces that ANSI stripping may have erased between words."""
    # "%ofyour" → "% ofyour" so bullet detection works even when the CLI
    # box collapsed its inter-word spacing.
    text = re.sub(r'(%)([a-zA-Z])', r'\1 \2', text)
    # lowercase→Uppercase boundary
    text = re.sub(r'([a-z])([A-Z])', r'\1 \2', text)
    # word→digit
    text = re.sub(r'([a-zA-Z])(\d)', r'\1 \2', text)
    # digit→lowercase letter (but not the "pm"/"am"/"k" suffixes and not
    # percentages)
    text = re.sub(r'(\d)([a-z])', lambda m: (
        m.group(0) if m.group(2) in 'apkm' else f'{m.group(1)} {m.group(2)}'
    ), text)
    return re.sub(r' +', ' ', text)


# ---------------------------------------------------------------------------
# Main parse
# ---------------------------------------------------------------------------

def parse_usage(text):
    """Parses the raw terminal output into a structured dict."""
    result = {
        "session_percent": 0,
        "session_reset": "",
        "weekly_percent": 0,
        "weekly_reset": "",
        "sonnet_percent": 0,
        "sonnet_reset": "",
        "plan": "",
        "model": "",
        "insights": [],
        "raw": "",
    }

    clean = _clean_ansi(text)
    result["raw"] = clean[-1500:]

    # -----------------------------------------------------------------
    # Plan + model line, e.g. "Opus 4.7 (1M context) Claude Max"
    #
    # Structural match only — captures whatever model descriptor the CLI
    # prints and whatever plan name follows it. If Anthropic renames
    # "Claude Max" to "Claude Pro Max" or adds a new tier, this still
    # works; the text is passed through verbatim.
    # -----------------------------------------------------------------
    plan_match = re.search(
        r'(\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?\s+[\d.]+\s*'
        r'\([^)]*(?:context|tokens|k|M)[^)]*\))\s+'
        r'(Claude\s+[A-Z][a-zA-Z]*(?:\s+[A-Z][a-zA-Z]*)?)',
        clean,
    )
    if plan_match:
        result["model"] = re.sub(r'\s+', ' ', plan_match.group(1)).strip()
        result["plan"] = re.sub(r'\s+', ' ', plan_match.group(2)).strip()

    # -----------------------------------------------------------------
    # Anchor on the last "Last 24h" header and walk backwards to find
    # each preceding section's start. This tolerates multiple terminal
    # redraws by always picking the latest coherent set of headers.
    # -----------------------------------------------------------------
    last24h_matches = list(re.finditer(r'last\s*24\s*h', clean, re.IGNORECASE))
    if last24h_matches:
        last24h_start = last24h_matches[-1].start()
        last24h_end = last24h_matches[-1].end()
    else:
        last24h_start = len(clean)
        last24h_end = len(clean)

    # Tolerate degraded sonnet header ("Sonet nly") seen in late redraws.
    sonnet_header = (
        r'current\s*week\s*\(?\s*sonnet\s*only\s*\)?'
        r'|current\s*week\s*\(?\s*son[a-z]*\s*(?:only|nly)\s*\)?'
    )
    sonnet_m = _last_match_before(sonnet_header, clean, last24h_start)
    sonnet_start = sonnet_m.start() if sonnet_m else last24h_start
    sonnet_end_of_header = sonnet_m.end() if sonnet_m else last24h_start

    all_header = r'current\s*week\s*\(?\s*all\s*models?\s*\)?'
    all_m = _last_match_before(all_header, clean, sonnet_start)
    all_start = all_m.start() if all_m else sonnet_start
    all_end_of_header = all_m.end() if all_m else sonnet_start

    session_m = _last_match_before(r'current\s*session', clean, all_start)
    session_start_of_body = session_m.end() if session_m else 0

    session_block = clean[session_start_of_body:all_start]
    all_block = clean[all_end_of_header:sonnet_start]
    sonnet_block = clean[sonnet_end_of_header:last24h_start]
    last24h_block = clean[last24h_end:]

    # -----------------------------------------------------------------
    # Session: time-only reset
    # -----------------------------------------------------------------
    result["session_percent"] = _extract_percent(session_block)
    result["session_reset"] = _extract_reset(session_block, allow_date=False)

    # -----------------------------------------------------------------
    # Weekly (all models): dated reset
    # -----------------------------------------------------------------
    result["weekly_percent"] = _extract_percent(all_block)
    result["weekly_reset"] = _extract_reset(all_block, allow_date=True)

    # -----------------------------------------------------------------
    # Weekly (Sonnet only): dated reset, may show no percent when 0
    # -----------------------------------------------------------------
    result["sonnet_percent"] = _extract_percent(sonnet_block)
    result["sonnet_reset"] = _extract_reset(sonnet_block, allow_date=True)

    # -----------------------------------------------------------------
    # Last 24h insights — fully dynamic, purely structural.
    #
    # We do NOT hardcode any CLI wording (no "of your usage", no
    # "sessions", no "context"). Bullets are identified only by their
    # structural shape: a percentage followed by descriptive text, with
    # the next bullet starting at the next percentage in the section.
    # If Anthropic rewords, reorders, adds or removes bullets, this
    # logic still picks them up.
    # -----------------------------------------------------------------
    reflowed = _reflow(last24h_block)

    # Drop the interactive-footer hints so we don't read past the box.
    # These are short, known single-letter prompts — not insight content.
    footer = re.search(
        r'\bd\s*to\s*day\b|\bw\s*to\s*week\b|\besc\s*to\s*cancel\b|\brefreshing\b',
        reflowed,
        re.IGNORECASE,
    )
    if footer:
        reflowed = reflowed[:footer.start()]

    # Every percentage in the block (0-100 only, ignoring huge numbers).
    pct_matches = [
        m for m in re.finditer(r'(\d{1,3})\s*%', reflowed)
        if int(m.group(1)) <= 100
    ]

    insights = []
    for i, m in enumerate(pct_matches):
        percent = int(m.group(1))
        body_start = m.end()
        body_end = pct_matches[i + 1].start() if i + 1 < len(pct_matches) else len(reflowed)
        body = reflowed[body_start:body_end].strip()

        # Skip short/empty segments — likely a stray percentage embedded
        # inside a description rather than a real bullet (heuristic
        # threshold; avoids noise without hardcoding any words).
        if len(body) < 15:
            continue

        title, description = _split_title_description(body)
        title = _tidy_title(title)
        description = _tidy_desc(description)
        if title:
            insights.append({
                "percent": percent,
                "title": title,
                "description": description,
            })

    result["insights"] = insights

    return result


def _split_title_description(body):
    """Split 'title <Description sentence>' into (title, description).

    The CLI renders each insight as a short title followed on the next
    line by a longer explanatory sentence. ANSI cleaning concatenates
    them, but the description almost always begins with a capitalized
    word that immediately follows a lowercase/digit word. We use that
    transition as the split point, requiring at least ~10 chars of
    title first so we don't split on an in-title proper noun.
    """
    body = body.strip()
    if not body:
        return "", ""

    m = re.search(
        r'^(.{10,}?[a-z0-9+>])\s+([A-Z][a-z].*)$',
        body,
        re.DOTALL,
    )
    if m:
        return m.group(1), m.group(2)
    return body, ""


def _tidy_title(s):
    """Light cleanup for the insight title line."""
    s = re.sub(r'\s+', ' ', s).strip(' .,')
    # Capitalize the first letter for visual consistency
    if s:
        s = s[0].upper() + s[1:]
    return s


def main():
    try:
        text = get_usage()
        result = parse_usage(text)
        print(json.dumps(result))
    except FileNotFoundError as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)
    except Exception as e:
        print(json.dumps({"error": f"Unexpected error: {str(e)}"}))
        sys.exit(1)


if __name__ == "__main__":
    main()
