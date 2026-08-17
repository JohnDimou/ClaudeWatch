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
    - notes (list): Dynamic array of Last-24h sub-sections that have no
      percentage column (e.g. "Skills, subagents, and plugins"), each with:
        - heading (str): Section heading as rendered by the CLI
        - body (str): Explanatory text under the heading (may be empty)
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

    # Drop every Claude Code session marker we may have inherited. If
    # ClaudeWatch (or this script) is launched from inside a Claude Code
    # session, markers like CLAUDE_CODE_CHILD_SESSION make the spawned CLI
    # treat itself as a child session — transcript saving switches off and
    # the "what's contributing" local-session scan behaves differently.
    child_env = {
        k: v for k, v in os.environ.items()
        if not k.startswith(('CLAUDECODE', 'CLAUDE_CODE', 'CLAUDE_PID', 'AI_AGENT'))
    }

    proc = subprocess.Popen(
        [claude_path],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
        # Run from a neutral directory so claude doesn't scan the parent
        # app's cwd for CLAUDE.md / project files. When ClaudeWatch is
        # launched from the user's Desktop (or any TCC-protected folder),
        # an inherited cwd would trigger a Desktop/Documents permission
        # prompt every poll cycle.
        cwd='/tmp',
        env={
            **child_env,
            'TERM': 'xterm-256color',
            'COLUMNS': '200',
            'LINES': '50',
            # Strip directory hints so claude can't backtrack to a
            # protected folder via $PWD or $OLDPWD.
            'PWD': '/tmp',
            'OLDPWD': '/tmp',
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

    # Wait until the dialog is fully populated, or up to 20 seconds.
    #
    # Claude CLI 2.1.x renders the limit buckets progressively: the session
    # and all-models rows paint immediately, but the per-model weekly bucket
    # ("Current week (Fable)") is fetched asynchronously and lands a few
    # seconds later, as does the "Usage credits" row. Older builds instead
    # ended the dialog with a "Last 24h" section.
    #
    # So the completion signal is structural rather than textual: keep
    # reading until we have seen at least three "NN% used" rows (session +
    # all models + the per-model bucket), or the legacy "Last 24h" header.
    # We deliberately do NOT match on the words "usage credits" — that
    # phrase also appears in the /usage-credits entry of the slash-command
    # autocomplete menu, which renders before the dialog even opens.
    started = time.time()
    deadline = started + 20
    settled = False
    last_size = len(output)
    last_change = time.time()

    while time.time() < deadline:
        read_all(0.5)
        if len(output) != last_size:
            last_size = len(output)
            last_change = time.time()

        probe = _clean_ansi(output.decode('utf-8', errors='ignore'), keep_rows=True)
        widest = max((len(_PCT_USED.findall(f)) for f in _frames(probe)), default=0)

        # Best signal: a SINGLE paint showing all three buckets. Counting
        # across the whole buffer would be wrong — two consecutive paints of
        # two buckets each also total three, and breaking there exits before
        # the per-model bucket has painted at all.
        if widest >= 3:
            settled = True
            # Let the final repaint land so the bucket's reset row arrives.
            read_all(2)
            break

        # Otherwise settle on quiescence: the dialog has painted at least the
        # session and weekly buckets and has since stopped emitting. Waiting
        # longer cannot help — not every account has a third bucket, and the
        # local-session scan behind "what's contributing" may never resolve.
        if widest >= 2 and time.time() - last_change > 2.5:
            settled = True
            read_all(1)
            break

    # Nothing recognisable rendered — give the main data a final chance.
    if not settled:
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

def _clean_ansi(text, keep_rows=False):
    """Strip ANSI, OSC, and other escape sequences; normalize whitespace.

    The Claude CLI draws its /usage box with cursor-positioning sequences
    (e.g. `\\x1b[12C` = cursor forward 12 cells). If we simply strip those,
    we lose the visual spacing between columns and words collide into
    each other ("usagecamefrom..."). Replace them with equivalent runs
    of real spaces BEFORE the strip pass so word boundaries survive.

    Two views of the same stream are produced, because the two parsers
    want opposite things:

    * ``keep_rows=False`` (default) — vertical cursor moves also become
      spaces, giving the flowing prose view the Last-24h bullet parser
      was written against.
    * ``keep_rows=True`` — vertical cursor moves become newlines, so the
      screen's row structure survives. The limit-bucket and stats parsers
      read row by row and need this: the CLI does not always separate
      rows with CR/LF, and some paints position purely with cursor
      sequences, collapsing the whole dialog onto one line.
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
    if keep_rows:
        # Cursor back / device-status stay horizontal.
        t = re.sub(r'\x1b\[\d*[Dn]', ' ', t)
        # Vertical movement starts a new screen row.
        t = re.sub(r'\x1b\[[\d;]*[ABEFHfd]', '\n', t)
    else:
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
    """Parses the raw terminal output into a structured dict.

    Strategy: the Claude CLI repaints its /usage dialog several times as
    asynchronous data lands, and Ink only rewrites the cells that changed.
    Concatenating every paint therefore yields a buffer full of half-drawn
    rows ("Europe/Athe s", a bare "Fable)" whose "Current week (" prefix
    was never redrawn). Instead of tolerating that with ever-looser
    regexes, we split the stream into individual paints, parse each one on
    its own, and merge field-by-field — taking the freshest value that is
    also well-formed. See `_merge_frames`.
    """
    # Two views of the same capture — see `_clean_ansi`. `clean` is the
    # flowing-prose view the Last-24h parser expects; `rows` preserves the
    # screen's row structure for the limit-bucket and stats parsers.
    clean = _clean_ansi(text)
    rows = _clean_ansi(text, keep_rows=True)

    result = {
        # --- limit buckets: legacy keys, unchanged meaning -------------
        "session_percent": 0,
        "session_reset": "",
        "weekly_percent": 0,
        "weekly_reset": "",
        # `sonnet_*` predates the CLI making this bucket model-agnostic.
        # Kept as an alias of the per-model bucket so older builds of the
        # app keep working; new code should read `model_bucket_*`.
        "sonnet_percent": 0,
        "sonnet_reset": "",
        # --- limit buckets: per-model, now dynamically named -----------
        "model_bucket_name": "",
        "model_bucket_percent": 0,
        "model_bucket_reset": "",
        # --- did the CLI actually render each bucket? -------------------
        #
        # A bucket that never painted is NOT a bucket at 0%. The per-model
        # bucket in particular loads asynchronously and is sometimes absent
        # entirely, and reporting that as 0% tells the user they have a full
        # allowance left when they may have almost none. These flags let the
        # UI distinguish "unused" from "unknown".
        "session_reported": False,
        "weekly_reported": False,
        "model_bucket_reported": False,
        # --- identity ---------------------------------------------------
        "plan": "",
        "model": "",
        "cli_version": "",
        # --- session stats (Claude CLI 2.1.x "Stats" block) -------------
        "session_cost_usd": 0.0,
        "session_api_duration": "",
        "session_wall_duration": "",
        "lines_added": 0,
        "lines_removed": 0,
        "tokens_input": 0,
        "tokens_output": 0,
        "tokens_cache_read": 0,
        "tokens_cache_write": 0,
        # --- extras ------------------------------------------------------
        "promo_text": "",
        "promo_url": "",
        "credits_enabled": False,
        "credits_text": "",
        "contributors": [],
        "contributors_status": "",
        # --- legacy Last-24h behavioural section -------------------------
        "insights": [],
        "notes": [],
        "raw": "",
    }
    result["raw"] = clean[-1500:]

    _parse_identity(clean, result)
    _merge_frames([_parse_frame(f) for f in _frames(rows)], result)

    # Legacy Last-24h section — removed in Claude CLI 2.1.x in favour of
    # "What's contributing to your limits usage?", but still parsed so the
    # app keeps working against older CLI builds.
    last24h_matches = list(re.finditer(r'last\s*24\s*h', clean, re.IGNORECASE))
    insights, notes = _extract_best_insights(clean, last24h_matches)
    result["insights"] = insights
    result["notes"] = notes

    # Safety net: if the frame walk produced nothing usable (an unfamiliar
    # layout, or a badly degraded capture), fall back to the original
    # block-scanning heuristics so we never do worse than before.
    if not result["session_percent"] and not result["weekly_percent"]:
        _legacy_block_parse(clean, last24h_matches, result)

    return result


def _parse_identity(clean, result):
    """Extract the CLI version, model descriptor, and plan name."""
    # "Claude Code v2.1.233"
    version = re.search(r'Claude\s+Code\s+v([\d]+\.[\d]+\.[\d]+)', clean)
    if version:
        result["cli_version"] = version.group(1)

    # Plan + model line, e.g. "Opus 5 (1M context) Claude Max".
    #
    # Structural match only — captures whatever model descriptor the CLI
    # prints and whatever plan name follows it. If Anthropic renames
    # "Claude Max" to "Claude Pro Max" or adds a new tier, this still
    # works; the text is passed through verbatim.
    plan_match = re.search(
        r'(\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?\s+[\d.]+\s*'
        r'\([^)]*(?:context|tokens|k|M)[^)]*\))\s+'
        r'(Claude\s+[A-Z][a-zA-Z]*(?:\s+[A-Z][a-zA-Z]*)?)',
        clean,
    )
    if plan_match:
        result["model"] = re.sub(r'\s+', ' ', plan_match.group(1)).strip()
        result["plan"] = re.sub(r'\s+', ' ', plan_match.group(2)).strip()


def _legacy_block_parse(clean, last24h_matches, result):
    """Original (pre-2.1.x) section-block parser, kept as a fallback.

    Anchors on the last "Last 24h" header and walks backwards to find each
    preceding section's start, then scans each block for a percentage and
    a reset string. Only invoked when the frame-aware parser found no
    session or weekly percentage at all.
    """
    if last24h_matches:
        last24h_start = last24h_matches[-1].start()
    else:
        last24h_start = len(clean)

    # Tolerate degraded sonnet header. Late redraws have been seen as
    # "Sonet nly", "Son et nly", "S nnet only" — basically any cell-split
    # variation.
    sonnet_header = (
        r'current\s*week\s*\(?\s*'
        r'son[a-z]*(?:\s+[a-z]{1,4})*\s*'
        r'(?:only|nly|nl|ly)\s*\)?'
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

    result["session_percent"] = _extract_percent(session_block)
    result["session_reset"] = _extract_reset(session_block, allow_date=False)
    result["weekly_percent"] = _extract_percent(all_block)
    result["weekly_reset"] = _extract_reset(all_block, allow_date=True)
    result["sonnet_percent"] = _extract_percent(sonnet_block)
    result["sonnet_reset"] = _extract_reset(sonnet_block, allow_date=True)
    result["model_bucket_percent"] = result["sonnet_percent"]
    result["model_bucket_reset"] = result["sonnet_reset"]

    # This path scans blocks rather than tracking which rows painted, so
    # infer presence: a bucket that yielded either a percentage or a reset
    # was rendered.
    result["session_reported"] = bool(
        result["session_percent"] or result["session_reset"]
    )
    result["weekly_reported"] = bool(
        result["weekly_percent"] or result["weekly_reset"]
    )
    result["model_bucket_reported"] = bool(
        result["model_bucket_percent"] or result["model_bucket_reset"]
    )


# ---------------------------------------------------------------------------
# Frame-aware parsing (Claude CLI 2.1.x)
#
# The dialog is redrawn several times while asynchronous data lands, and
# only changed cells are rewritten. Parsing each paint separately and then
# merging keeps half-drawn rows from poisoning the result.
# ---------------------------------------------------------------------------

# Every full repaint of the dialog begins with its tab bar, which makes it
# a dependable frame delimiter.
_FRAME_SPLIT = re.compile(r'(?=Settings\s+Status\s+Config\s+Usage)')
_FRAME_SPLIT_FALLBACK = re.compile(r'(?=Current\s+session)', re.IGNORECASE)

_PCT_USED = re.compile(r'(\d{1,3})\s*%\s*used\b', re.IGNORECASE)

_MONTHS = r'jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec'

# A reset string we trust: an optional "Mon DD at" prefix, a clock time,
# and a timezone in parentheses containing no spaces. That last condition
# is what rejects half-repainted values such as "(Europe/Athe s)".
_GOOD_RESET = re.compile(
    r'^(?:(?:' + _MONTHS + r')[a-z]*\.?\s+\d{1,2}\s+at\s+)?'
    r'\d{1,2}(?::\d{2})?\s*[ap]m\s*'
    r'\([A-Za-z][A-Za-z0-9_+\-]*(?:/[A-Za-z0-9_+\-]+)*\)$',
    re.IGNORECASE,
)

# A permissive match used to *find* a reset anywhere on a row.
_ANY_RESET = re.compile(
    r'(?:(?:' + _MONTHS + r')[a-z]*\.?\s+\d{1,2}\s+(?:at\s+)?)?'
    r'\d{1,2}(?::\d{2})?\s*[ap]m\s*\([^)]*\)',
    re.IGNORECASE,
)


def _frames(clean):
    """Split the cleaned stream into individual screen paints."""
    parts = [p for p in _FRAME_SPLIT.split(clean) if p.strip()]
    if len(parts) < 2:
        parts = [p for p in _FRAME_SPLIT_FALLBACK.split(clean) if p.strip()]
    return parts or [clean]


def _parse_frame(frame):
    """Extract every field we can from one paint.

    Only keys that were actually found are set, so the merge step can tell
    "this paint didn't redraw that row" apart from "the value is zero".
    """
    found = {}
    lines = frame.split('\n')
    _frame_buckets(lines, found)
    _frame_stats(lines, found)
    _frame_extras(lines, found)
    _frame_contributors(lines, found)
    return found


def _num(token):
    """Parse a token like '1,234', '1.2k' or '3.4M' into an int."""
    token = token.strip().replace(',', '')
    m = re.match(r'^([\d.]+)\s*([kKmMbB]?)$', token)
    if not m:
        return None
    try:
        value = float(m.group(1))
    except ValueError:
        return None
    scale = {'k': 1e3, 'm': 1e6, 'b': 1e9}.get(m.group(2).lower(), 1)
    return int(value * scale)


# --- limit buckets ---------------------------------------------------------

def _is_label(s):
    """True if `s` looks like a bucket heading rather than data."""
    if len(re.findall(r'[A-Za-z]', s)) < 2:
        return False
    low = s.lower()
    if s.startswith('+') or 'promo' in low or 'clau.de' in low:
        return False
    if _PCT_USED.search(s):
        return False
    if re.match(r'^resets?\b', low):
        return False
    if _ANY_RESET.match(s.strip()):
        return False
    if low.startswith(('total ', 'usage:', 'approximate')):
        return False
    return True


def _bucket_label(lines, i, match):
    """Heading for the bucket whose 'NN% used' row is at `lines[i]`.

    The CLI usually puts the heading on its own row above the percentage,
    but a narrow layout can place both on one row — so check that first.
    """
    same_row = (lines[i][:match.start()] + ' ' + lines[i][match.end():]).strip()
    if _is_label(same_row):
        return re.sub(r'\s+', ' ', same_row)
    for j in range(i - 1, max(-1, i - 5), -1):
        candidate = lines[j].strip()
        if not candidate:
            continue
        if _is_label(candidate):
            return re.sub(r'\s+', ' ', candidate)
    return ""


def _bucket_reset(lines, i):
    """Reset string belonging to the bucket whose percentage row is `i`.

    Scans the next few non-blank rows, stopping at the following bucket —
    each bucket renders as heading / percentage / reset, so the next
    'NN% used' always precedes the next bucket's reset.
    """
    examined = 0
    for j in range(i, len(lines)):
        row = lines[j]
        if j > i:
            if not row.strip():
                continue
            if _PCT_USED.search(row):
                break
            examined += 1
            if examined > 3:
                break
        m = _ANY_RESET.search(row)
        if m:
            return _tidy_reset(m.group(0))
    return ""


def _bucket_model_name(label):
    """Model name from a per-model bucket heading.

    'Current week (Fable)' -> 'Fable'. A partial repaint can drop the
    prefix and leave just 'Fable)', which is handled too.
    """
    m = re.search(r'\(([^)]{1,40})\)', label)
    name = m.group(1) if m else re.sub(
        r'^\s*current\s+week\s*\(?', '', label, flags=re.IGNORECASE
    )
    name = name.strip().rstrip(')').strip()
    if name.lower() in ('all models', 'all model'):
        return ""
    if not re.match(r'^[A-Za-z][A-Za-z0-9 .\-]{0,30}$', name):
        return ""
    return name


def _classify_bucket(label, index):
    """Map a bucket heading to session / weekly / model."""
    low = label.lower()
    if 'session' in low:
        return 'session'
    if 'all model' in low:
        return 'weekly'
    if label:
        return 'model'
    # Heading never repainted — fall back to render order.
    return ('session', 'weekly', 'model')[index] if index < 3 else 'model'


def _frame_buckets(lines, found):
    """Read every 'NN% used' bucket in this paint."""
    buckets = []
    for i, line in enumerate(lines):
        m = _PCT_USED.search(line)
        if not m:
            continue
        percent = int(m.group(1))
        if percent > 100:
            continue
        buckets.append({
            'label': _bucket_label(lines, i, m),
            'percent': percent,
            'reset': _bucket_reset(lines, i),
        })

    for index, bucket in enumerate(buckets):
        kind = _classify_bucket(bucket['label'], index)
        if kind == 'session':
            found['session_percent'] = bucket['percent']
            if bucket['reset']:
                found['session_reset'] = bucket['reset']
        elif kind == 'weekly':
            found['weekly_percent'] = bucket['percent']
            if bucket['reset']:
                found['weekly_reset'] = bucket['reset']
        else:
            found['model_bucket_percent'] = bucket['percent']
            if bucket['reset']:
                found['model_bucket_reset'] = bucket['reset']
            name = _bucket_model_name(bucket['label'])
            if name:
                found['model_bucket_name'] = name


# --- session stats ---------------------------------------------------------

def _frame_stats(lines, found):
    """Read the 'Stats / Session' block added in Claude CLI 2.1.x."""
    for line in lines:
        s = line.strip()

        m = re.match(r'Total\s+cost:\s*\$\s*([\d.,]+)', s, re.IGNORECASE)
        if m:
            try:
                found['session_cost_usd'] = float(m.group(1).replace(',', ''))
            except ValueError:
                pass
            continue

        m = re.match(r'Total\s+duration\s*\(\s*API\s*\)\s*:\s*(.+)$', s, re.IGNORECASE)
        if m:
            found['session_api_duration'] = re.sub(r'\s+', ' ', m.group(1)).strip()
            continue

        m = re.match(r'Total\s+duration\s*\(\s*wall\s*\)\s*:\s*(.+)$', s, re.IGNORECASE)
        if m:
            found['session_wall_duration'] = re.sub(r'\s+', ' ', m.group(1)).strip()
            continue

        m = re.match(r'Total\s+code\s+changes:\s*(.+)$', s, re.IGNORECASE)
        if m:
            body = m.group(1)
            added = re.search(r'([\d.,]+\s*[kKmMbB]?)\s*lines?\s+added', body, re.IGNORECASE)
            removed = re.search(r'([\d.,]+\s*[kKmMbB]?)\s*lines?\s+removed', body, re.IGNORECASE)
            # A degraded repaint ("0 li es added") simply fails to match;
            # the merge then keeps a cleaner paint's value.
            if added and _num(added.group(1)) is not None:
                found['lines_added'] = _num(added.group(1))
            if removed and _num(removed.group(1)) is not None:
                found['lines_removed'] = _num(removed.group(1))
            continue

        m = re.match(r'Usage:\s*(.+)$', s, re.IGNORECASE)
        if m:
            body = m.group(1)
            for key, label in (
                ('tokens_input', r'input'),
                ('tokens_output', r'output'),
                ('tokens_cache_read', r'cache\s*read'),
                ('tokens_cache_write', r'cache\s*write'),
            ):
                mm = re.search(r'([\d.,]+\s*[kKmMbB]?)\s*' + label, body, re.IGNORECASE)
                if mm and _num(mm.group(1)) is not None:
                    found[key] = _num(mm.group(1))


# --- promo banner + usage credits -----------------------------------------

def _frame_extras(lines, found):
    """Read the promo banner and the usage-credits row."""
    for line in lines:
        s = re.sub(r'\s+', ' ', line.strip())
        low = s.lower()

        if 'promo' in low and '%' in s:
            url = re.search(
                r'\b((?:https?://)?[a-z0-9][a-z0-9.\-]*\.[a-z]{2,}/\S+)', s, re.IGNORECASE
            )
            if url:
                found['promo_url'] = url.group(1)
                s = s.replace(url.group(1), '')
            found['promo_text'] = s.strip(' .,-')
            continue

        if re.search(r'credits?\s+are\s+', low):
            found['credits_text'] = s
            found['credits_enabled'] = not re.search(r'credits?\s+are\s+off', low)


# --- "What's contributing to your limits usage?" ---------------------------

def _frame_contributors(lines, found):
    """Read the contributing-usage table that replaced the Last-24h block.

    The table is populated asynchronously from a scan of local sessions,
    so most paints show only a "Scanning local sessions…" placeholder —
    recorded as a status so the UI can say so rather than showing nothing.
    """
    start = None
    for i, line in enumerate(lines):
        if re.search(r'contributing\s+to\s+your\s+limits', line, re.IGNORECASE):
            start = i + 1
            break
    if start is None:
        return

    rows = []
    status = ''
    for line in lines[start:start + 30]:
        s = re.sub(r'\s{3,}', '  ', line.rstrip()).strip()
        if not s:
            continue
        low = s.lower()
        if low.startswith('approximate') or 'does not include' in low:
            continue
        if 'scanning' in low or 'refreshing' in low:
            status = 'scanning'
            continue
        if 'esc to cancel' in low:
            continue
        if re.search(r'current\s+(session|week)', low) or 'usage credits' in low:
            break
        # "<name>  NN%" or "NN%  <name>" — accept either column order.
        m = re.match(r'^(.{1,48}?)\s{2,}(\d{1,3})\s*%$', s)
        if m and int(m.group(2)) <= 100:
            rows.append({'name': m.group(1).strip(), 'percent': int(m.group(2))})
            continue
        m = re.match(r'^(\d{1,3})\s*%\s+(.{1,48})$', s)
        if m and int(m.group(1)) <= 100:
            rows.append({'name': m.group(2).strip(), 'percent': int(m.group(1))})

    if rows:
        found['contributors'] = rows
        found['contributors_status'] = 'ready'
    elif status:
        found['contributors_status'] = status


# --- merge -----------------------------------------------------------------

# Fields where the freshest paint wins: they legitimately change between
# repaints (a percentage ticking up, a duration counting on).
_FRESHEST_WINS = (
    'session_percent', 'weekly_percent', 'model_bucket_percent',
    'model_bucket_name',
    'session_cost_usd', 'session_api_duration', 'session_wall_duration',
    'lines_added', 'lines_removed',
    'tokens_input', 'tokens_output', 'tokens_cache_read', 'tokens_cache_write',
    'promo_text', 'promo_url', 'credits_text', 'credits_enabled',
    'contributors', 'contributors_status',
)


def _merge_frames(frames, result):
    """Fold per-paint results into one, preferring fresh, well-formed values."""
    for key in _FRESHEST_WINS:
        for frame in frames:
            if key in frame:
                result[key] = frame[key]

    # Reset strings get stricter treatment: take the freshest value that is
    # also well-formed, so a partially repainted timezone never wins over a
    # clean one from an earlier paint.
    for key in ('session_reset', 'weekly_reset', 'model_bucket_reset'):
        best = ''
        for frame in frames:
            value = frame.get(key, '')
            if not value:
                continue
            if _GOOD_RESET.match(value) or not best:
                best = value
        result[key] = best

    # Record which buckets actually painted, so the UI can show "unknown"
    # rather than a misleading 0%.
    for percent_key, flag_key in (
        ('session_percent', 'session_reported'),
        ('weekly_percent', 'weekly_reported'),
        ('model_bucket_percent', 'model_bucket_reported'),
    ):
        result[flag_key] = any(percent_key in frame for frame in frames)

    # Keep the pre-2.1.x key names working as aliases.
    result['sonnet_percent'] = result['model_bucket_percent']
    result['sonnet_reset'] = result['model_bucket_reset']


def _extract_best_insights(clean, last24h_matches):
    """Pick the Last-24h section that yields the richest structure.

    Iterates through every "Last 24h" header in the buffer, builds a
    candidate section ending at either the next "Last 24h" header or a
    footer/control hint, and returns the bullet/note pair from whichever
    candidate is most complete. Returns a tuple `(insights, notes)`.

    Inside Last-24h, the CLI separates each sub-section with a blank
    line. Sub-sections that start with "NN%" are insight bullets; those
    that start with a Capitalized heading (e.g. "Skills, subagents, and
    plugins") are *notes* — explanatory blocks with no percent. We pick
    the render that yields the most bullets; ties break toward the
    render that also surfaces the most notes.
    """
    if not last24h_matches:
        return [], []

    best_insights = []
    best_notes = []
    for i, header in enumerate(last24h_matches):
        section_start = header.end()
        section_end = (
            last24h_matches[i + 1].start()
            if i + 1 < len(last24h_matches)
            else len(clean)
        )
        section = clean[section_start:section_end]

        reflowed = _reflow(section)
        footer = re.search(
            r'\bd\s*to\s*day\b|\bw\s*to\s*week\b|\besc\s*to\s*cancel\b|\brefreshing\b',
            reflowed,
            re.IGNORECASE,
        )
        if footer:
            reflowed = reflowed[:footer.start()]

        # Drop any "<Name> % of usage" table form up front — its rows have
        # the percent at the END (e.g. "MyPlugin  5%") and would otherwise
        # add noise to the paragraph split.
        subsection = re.search(
            r'\b[A-Z][a-zA-Z]+(?:\s+[A-Z][a-zA-Z]+){0,3}\s+%\s+of\s+usage\b',
            reflowed,
        )
        if subsection:
            reflowed = reflowed[:subsection.start()]

        # Each sub-section sits in its own paragraph (blank-line separated)
        paragraphs = [p for p in re.split(r'\n\s*\n', reflowed) if p.strip()]

        candidate_insights = []
        candidate_notes = []
        for para in paragraphs:
            # A bullet's "NN%" may follow intro prose without a paragraph
            # break — the section subtitle ("these are independent
            # characteristics of your usage, not a breakdown") often
            # shares a line with the first bullet. Search anywhere in the
            # paragraph and require a substantial body so a stray percent
            # inside note prose can't masquerade as a bullet.
            bullet = re.search(
                r'(\d{1,3})\s*%\s+(.{15,})',
                para,
                re.DOTALL,
            )
            if bullet and int(bullet.group(1)) <= 100:
                percent = int(bullet.group(1))
                body = bullet.group(2).strip()
                title, description = _split_bullet_body(body)
                title = _tidy_title(title)
                description = _tidy_desc(description)
                if title:
                    candidate_insights.append({
                        "percent": percent,
                        "title": title,
                        "description": description,
                    })
                    continue
            note = _parse_note(para)
            if note:
                candidate_notes.append(note)

        better = (
            len(candidate_insights) > len(best_insights)
            or (
                len(candidate_insights) == len(best_insights)
                and len(candidate_notes) > len(best_notes)
            )
        )
        if better:
            best_insights = candidate_insights
            best_notes = candidate_notes

    return best_insights, best_notes


def _split_bullet_body(body):
    """Split bullet body into (title, description).

    Prefers the first newline as the boundary — the CLI normally breaks
    the line between the bullet's headline and its explanatory sentence.
    Falls back to the legacy capitalization heuristic when wrap removed
    the newline (e.g. when the entire bullet fits on one PTY column row).
    """
    nl = body.find('\n')
    if nl > 10:
        title = re.sub(r'\s+', ' ', body[:nl]).strip()
        description = re.sub(r'\s+', ' ', body[nl + 1:]).strip()
        if title:
            return title, description
    return _split_title_description(re.sub(r'\s+', ' ', body))


def _parse_note(para):
    """Parse a non-bullet paragraph as a (heading, body) note.

    Notes are no-percent sub-sections inside Last-24h, like
    "Skills, subagents, and plugins\\n<explanation>". The first short,
    capitalized line becomes the heading; remaining lines are joined as
    the body. Returns None if the paragraph doesn't look like a heading
    block (avoids picking up stray prose).
    """
    lines = [l.strip() for l in re.split(r'\n+', para) if l.strip()]
    if not lines:
        return None
    heading = lines[0]
    if re.match(r'^\d+\s*%', heading):
        return None
    if not re.match(r'^[A-Z]', heading):
        return None
    if len(heading) > 80:
        return None
    body = ' '.join(lines[1:])
    body = re.sub(r' +', ' ', body).strip(' .,')
    if body and body[-1] not in '.!?':
        body += '.'
    return {
        "heading": heading.rstrip('.,').strip(),
        "body": body,
    }


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
