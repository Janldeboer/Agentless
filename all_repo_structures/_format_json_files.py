#!/usr/bin/env python3
"""Format JSON files in a directory with consistent indentation.

Usage:
  - Default (current directory):
	  python _format_json_files.py
  - Specific directory:
	  python _format_json_files.py --dir path/to/folder
  - Recursive:
	  python _format_json_files.py --dir path/to/folder --recursive
  - Custom indent (default 2):
	  python _format_json_files.py --indent 4

The script will rewrite .json files in-place using the provided indentation,
preserving key order and Unicode characters.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Iterable


def find_json_files(root: Path, recursive: bool = False) -> Iterable[Path]:
	"""Yield paths to JSON files under root.

	Args:
		root: Directory to search.
		recursive: If True, search subdirectories.
	"""
	if recursive:
		yield from (p for p in root.rglob("*.json") if p.is_file())
	else:
		yield from (p for p in root.glob("*.json") if p.is_file())


def format_json_file(path: Path, indent: int) -> tuple[bool, str | None]:
	"""Format a single JSON file in-place.

	Args:
		path: Path to the JSON file.
		indent: Number of spaces to indent.

	Returns:
		(changed, error): changed indicates whether file content changed.
		error contains message if an error occurred, else None.
	"""
	try:
		original_text = path.read_text(encoding="utf-8")
	except Exception as e:  # I/O errors
		return False, f"Failed to read {path}: {e}"

	try:
		data = json.loads(original_text)
	except Exception as e:  # JSON decode errors
		return False, f"Invalid JSON in {path}: {e}"

	# Build pretty JSON string with desired formatting
	try:
		# ensure_ascii=False to keep Unicode, separators for compact spacing after colon
		formatted = json.dumps(
			data, indent=indent, ensure_ascii=False, separators=(",", ": ")
		)
		# Ensure trailing newline at EOF (common convention)
		if not formatted.endswith("\n"):
			formatted += "\n"
	except Exception as e:
		return False, f"Failed to serialize JSON for {path}: {e}"

	if formatted == original_text:
		return False, None

	try:
		# Write back only if changed
		path.write_text(formatted, encoding="utf-8", newline="\n")
		return True, None
	except Exception as e:
		return False, f"Failed to write {path}: {e}"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
	parser = argparse.ArgumentParser(
		description="Reformat JSON files in a directory with consistent indentation.",
	)
	parser.add_argument(
		"--dir",
		"-d",
		type=Path,
		default=Path.cwd(),
		help="Directory containing .json files (default: current directory)",
	)
	parser.add_argument(
		"--recursive",
		"-r",
		action="store_true",
		help="Recurse into subdirectories",
	)
	parser.add_argument(
		"--indent",
		"-i",
		type=int,
		default=2,
		help="Number of spaces for indentation (default: 2)",
	)
	return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
	args = parse_args(argv)

	target_dir: Path = args.dir
	if not target_dir.exists():
		print(f"Directory does not exist: {target_dir}", file=sys.stderr)
		return 2
	if not target_dir.is_dir():
		print(f"Not a directory: {target_dir}", file=sys.stderr)
		return 2
	if args.indent < 0:
		print("Indent must be non-negative", file=sys.stderr)
		return 2

	json_files = list(find_json_files(target_dir, recursive=args.recursive))
	if not json_files:
		print("No JSON files found.")
		return 0

	changed = 0
	skipped = 0
	errors = 0

	for path in sorted(json_files):
		did_change, err = format_json_file(path, indent=args.indent)
		rel = str(path.relative_to(target_dir)) if path.is_relative_to(target_dir) else str(path)
		if err:
			errors += 1
			print(f"[ERROR] {rel}: {err}", file=sys.stderr)
		elif did_change:
			changed += 1
			print(f"[UPDATED] {rel}")
		else:
			skipped += 1
			print(f"[OK] {rel}")

	print(
		f"\nDone. Files: {len(json_files)} | Updated: {changed} | Unchanged: {skipped} | Errors: {errors}"
	)
	return 0 if errors == 0 else 1


if __name__ == "__main__":
	raise SystemExit(main())

