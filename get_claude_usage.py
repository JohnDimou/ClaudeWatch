#!/usr/bin/env python3
"""
get_claude_usage.py - Fetches Claude Code usage statistics

This script runs the Claude CLI interactively, sends the /usage command,
and parses the output to extract usage percentages and reset times.

Requirements:
    - Python 3.6+
    - Claude Code CLI installed and accessible in PATH

Output:
    JSON object with the following fields:
    - session_percent: Current session usage percentage (0-100)
    - session_reset: Human-readable session reset time
    - weekly_percent: Weekly usage percentage for all models (0-100)
    - weekly_reset: Human-readable weekly reset time
    - sonnet_percent: Weekly usage percentage for Sonnet model (0-100)
    - raw: Raw output for debugging
    - error: Error message if something went wrong (null on success)

Usage:
    python3 get_claude_usage.py

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


def find_claude_cli():
    """
    Finds the Claude CLI executable in common installation paths.

    Returns:
        str: Path to claude executable, or None if not found
    """
    # Check if claude is in PATH
    claude_path = shutil.which('claude')
    if claude_path:
        return claude_path

    # Common installation paths
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

    Uses a pseudo-terminal (pty) to simulate interactive input,
    sends the /usage command, and captures the terminal output.

    Returns:
        str: Raw terminal output containing usage information

    Raises:
        FileNotFoundError: If Claude CLI is not installed
        RuntimeError: If unable to communicate with Claude CLI
    """
    # Find Claude CLI
    claude_path = find_claude_cli()
    if not claude_path:
        raise FileNotFoundError(
            "Claude CLI not found. Please install it from https://claude.ai/code"
        )

    # Create pseudo-terminal for interactive communication
    master, slave = pty.openpty()

    # Start Claude process
    proc = subprocess.Popen(
        [claude_path],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
        env={**os.environ, 'TERM': 'xterm-256color'}
    )

    os.close(slave)

    output = b""

    # Helper to read all available output with timeout
    def read_all(timeout_sec):
        nonlocal output
        start = time.time()
        while time.time() - start < timeout_sec:
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                try:
                    data = os.read(master, 4096)
                    if data:
                        output += data
                except OSError:
                    break

    # Wait for Claude to fully initialize (fixed wait + read)
    time.sleep(3)
    read_all(1)

    # Check if there's a permission/theme selector or onboarding prompt
    # Claude Code may show these on first launch after restart
    output_str = output.decode('utf-8', errors='ignore').lower()

    # If we see signs of a selector/prompt, send Enter to dismiss it
    selector_patterns = ['select a theme', 'choose a theme', 'select permission']
    if any(pattern in output_str for pattern in selector_patterns):
        os.write(master, b"\r")  # Accept default selection
        time.sleep(0.5)
        read_all(2)

    # Send /usage command
    os.write(master, b"/usage")
    time.sleep(1)
    read_all(1)

    # Use Tab to accept autocomplete, then Enter to execute
    os.write(master, b"\t")
    time.sleep(0.5)
    read_all(0.5)

    os.write(master, b"\r")
    time.sleep(5)
    read_all(5)

    # Clean up process
    try:
        proc.terminate()
        proc.wait(timeout=2)
    except (subprocess.TimeoutExpired, ProcessLookupError):
        try:
            proc.kill()
        except ProcessLookupError:
            pass

    os.close(master)

    # Decode output
    return output.decode('utf-8', errors='ignore')


def parse_usage(text):
    """
    Parses the raw terminal output to extract usage statistics.

    Args:
        text: Raw terminal output from Claude CLI

    Returns:
        dict: Parsed usage data with the following keys:
            - session_percent (int)
            - session_reset (str)
            - weekly_percent (int)
            - weekly_reset (str)
            - sonnet_percent (int)
            - raw (str): Cleaned output for debugging
    """
    result = {
        "session_percent": 0,
        "session_reset": "",
        "weekly_percent": 0,
        "weekly_reset": "",
        "sonnet_percent": 0,
        "raw": ""
    }

    # Remove ANSI escape codes for cleaner parsing
    # Step 1: Standard CSI sequences like \x1b[0m, \x1b[38;2;255;255;255m
    clean = re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]', '', text)
    # Step 2: OSC sequences like \x1b]0;title\x07 (ends with BEL or ST)
    clean = re.sub(r'\x1b\][^\x07\x1b]*[\x07]?', '', clean)
    # Step 3: Other escape sequences
    clean = re.sub(r'\x1b[<>=]', '', clean)
    # Step 4: Replace non-printable with space
    clean = re.sub(r'[^\x20-\x7E\n]', ' ', clean)
    # Step 5: Collapse multiple spaces
    clean = re.sub(r' +', ' ', clean)

    # Store cleaned output (last 1000 chars for debugging)
    result["raw"] = clean[-1000:]

    lines = clean.split('\n')

    i = 0
    while i < len(lines):
        line = lines[i].strip().lower()

        # Parse "Current session" section
        if 'current session' in line:
            # Look for percentage in nearby lines
            for j in range(i, min(i + 3, len(lines))):
                match = re.search(r'(\d+)\s*%', lines[j])
                if match:
                    result["session_percent"] = int(match.group(1))
                    break

            # Look for reset time
            for j in range(i, min(i + 3, len(lines))):
                reset_match = re.search(
                    r'resets?\s*(\d+[:\d]*\s*[ap]m[^)\n]*\)?)',
                    lines[j],
                    re.IGNORECASE
                )
                if reset_match:
                    result["session_reset"] = reset_match.group(1).strip()
                    break

        # Parse "Current week (all models)" section
        if 'current week' in line and 'all models' in line:
            for j in range(i, min(i + 3, len(lines))):
                match = re.search(r'(\d+)\s*%', lines[j])
                if match:
                    result["weekly_percent"] = int(match.group(1))
                    break

            for j in range(i, min(i + 5, len(lines))):
                reset_match = re.search(
                    r'resets?\s*(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[^)\n]+\)?',
                    lines[j],
                    re.IGNORECASE
                )
                if reset_match:
                    reset_text = reset_match.group(0)
                    reset_text = re.sub(r'^resets?\s*', '', reset_text, flags=re.IGNORECASE)
                    result["weekly_reset"] = reset_text.strip()
                    break

        # Parse "Sonnet only" section
        if 'sonnet only' in line:
            for j in range(i, min(i + 3, len(lines))):
                match = re.search(r'(\d+)\s*%', lines[j])
                if match:
                    result["sonnet_percent"] = int(match.group(1))
                    break

        i += 1

    return result


def main():
    """
    Main entry point. Fetches usage and outputs JSON to stdout.
    """
    try:
        # Get raw output from Claude CLI
        text = get_usage()

        # Parse the output
        result = parse_usage(text)

        # Output as JSON
        print(json.dumps(result))

    except FileNotFoundError as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)

    except Exception as e:
        print(json.dumps({"error": f"Unexpected error: {str(e)}"}))
        sys.exit(1)


if __name__ == "__main__":
    main()
