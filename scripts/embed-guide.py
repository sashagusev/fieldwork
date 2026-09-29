#!/usr/bin/env python3
"""Embed AGENT_FILE_GUIDE.md in ResearchCore so every new workspace gets a copy. Runs before each build."""
import pathlib

root = pathlib.Path(__file__).resolve().parents[1]
guide = (root / 'AGENT_FILE_GUIDE.md').read_text(encoding='utf-8')
assert '"""#' not in guide, 'The guide cannot contain the raw-string terminator """#'
# A multi-line literal drops the newline before its closing delimiter, so one is added to keep the file byte-for-byte.
target = root / 'Sources/ResearchCore/AgentGuide.swift'
generated = f'''// Generated from AGENT_FILE_GUIDE.md by scripts/embed-guide.py. Edit the Markdown file, not this one.
public enum AgentGuide {{
    public static let filename = "AGENT_FILE_GUIDE.md"
    public static let text = #"""
{guide}
"""#
}}
'''
if not target.exists() or target.read_text(encoding='utf-8') != generated:
    target.write_text(generated, encoding='utf-8')
