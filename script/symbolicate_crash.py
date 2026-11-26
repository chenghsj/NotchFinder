#!/usr/bin/env python3
import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


DEFAULT_SYMBOLS = Path(__file__).resolve().parents[1] / "dist" / "symbols"


def read_crash_report(path):
    # macOS IPS files can prefix the crash with a separate JSON metadata header.
    contents = path.read_text(encoding="utf-8-sig").lstrip()
    first, end = json.JSONDecoder().raw_decode(contents)
    payload = contents[end:].strip()
    crash = json.loads(payload) if payload else first
    if not isinstance(crash, dict) or not isinstance(crash.get("usedImages"), list):
        raise ValueError(f"{path} does not contain a JSON crash report with a usedImages list")
    if not all(isinstance(image, dict) for image in crash["usedImages"]):
        raise ValueError(f"{path} contains an invalid usedImages entry")
    return crash


def normalized_uuid(value):
    return value.replace("-", "").lower() if isinstance(value, str) else None


def matching_images(crash, symbols_dir):
    archives = sorted(symbols_dir.rglob("*.dSYM"))
    if not archives:
        raise ValueError(f"No dSYM bundles found in {symbols_dir}")

    archived_uuids = set()
    for archive in archives:
        listing = subprocess.run(
            ["xcrun", "dwarfdump", "--uuid", archive], capture_output=True, text=True
        )
        archived_uuids.update(
            normalized_uuid(line.split()[1])
            for line in listing.stdout.splitlines()
            if line.startswith("UUID: ")
        )
    if not archived_uuids:
        raise ValueError(f"No readable dSYM UUIDs found in {symbols_dir}")
    return {
        index
        for index, image in enumerate(crash["usedImages"])
        if normalized_uuid(image.get("uuid")) in archived_uuids
    }


def symbolicate(report, symbols_dir, output):
    crash = read_crash_report(report)
    images = matching_images(crash, symbols_dir)
    if not images:
        app_uuid = next(
            (image["uuid"] for image in crash["usedImages"]
             if image.get("path") == crash.get("procPath") and image.get("uuid")),
            None,
        )
        detail = f" for app UUID {app_uuid}" if app_uuid else ""
        raise ValueError(f"No matching dSYM{detail} in {symbols_dir}")

    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    resources = developer.parent / "SharedFrameworks/CoreSymbolicationDT.framework/Resources"
    symbolicator = resources / "CrashSymbolicator.py"
    if not symbolicator.is_file():
        raise ValueError("CrashSymbolicator.py requires full Xcode. Select it with xcode-select or DEVELOPER_DIR.")

    with tempfile.TemporaryDirectory(prefix="notchfinder-crash.") as temp_dir:
        result_path = Path(temp_dir) / "symbolicated.ips"
        result = subprocess.run(
            [sys.executable, symbolicator, "--pretty", "-d", symbols_dir, "-o", result_path, report],
            capture_output=True, text=True,
        )
        if result.returncode:
            raise ValueError(result.stderr.strip() or result.stdout.strip() or "Xcode symbolication failed")
        if not result_path.is_file() or not result_path.stat().st_size:
            raise ValueError(result.stdout.strip() or "Xcode did not produce a symbolicated crash report")

        symbolicated = read_crash_report(result_path)
        backtraces = [thread.get("frames", []) for thread in symbolicated.get("threads", [])]
        backtraces.append(symbolicated.get("lastExceptionBacktrace") or [])
        if not any(frame.get("imageIndex") in images and frame.get("symbol")
                   for frames in backtraces for frame in frames):
            raise ValueError("Found a matching dSYM, but Xcode could not resolve any frames for it")

        destination = output.open("xb")
        try:
            with destination, result_path.open("rb") as source:
                shutil.copyfileobj(source, destination)
        except BaseException:
            output.unlink(missing_ok=True)
            raise


def main():
    parser = argparse.ArgumentParser(description="Symbolicate a macOS IPS crash report with archived dSYMs.")
    parser.add_argument("report", type=Path, help="Input .ips file")
    parser.add_argument("-d", "--symbols-dir", type=Path, default=DEFAULT_SYMBOLS,
                        help="Directory of dSYM bundles (default: dist/symbols)")
    parser.add_argument("-o", "--output", type=Path,
                        help="New output file (default: <report>.symbolicated.ips)")
    args = parser.parse_args()
    report = args.report.expanduser().absolute()
    output = args.output or report.with_name(f"{report.stem}.symbolicated.ips")
    output = output.expanduser().absolute()
    if output.exists():
        parser.exit(1, f"Output already exists: {output}\n")

    try:
        symbolicate(report, args.symbols_dir.expanduser().absolute(), output)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")
    print(output)


if __name__ == "__main__":
    main()
