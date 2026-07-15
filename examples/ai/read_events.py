"""Read every event from the newest Lemon serial-monitoring session.

The script calls the installed JSON CLI. It never opens a COM port.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path


CLIENT = Path(r"C:\Program Files\Lemon串口监控\ai\Lemon.SerialMonitor.AI.exe")
OUTPUT = Path("lemon-events.jsonl")


def run_json(*arguments: str) -> dict:
    completed = subprocess.run(
        [str(CLIENT), *arguments],
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"Lemon AI client exited with {completed.returncode}: "
            f"{completed.stderr.strip()}"
        )
    return json.loads(completed.stdout)


def main() -> None:
    if not CLIENT.is_file():
        raise FileNotFoundError(f"AI client not found: {CLIENT}")

    session_page = run_json("sessions", "list", "--limit", "1000", "--json")
    sessions = session_page.get("sessions", [])
    if not sessions:
        raise RuntimeError("No persisted sessions were found.")
    latest = max(sessions, key=lambda item: item["startedUtc"])

    cursor: str | None = None
    receipt: str | None = None
    with OUTPUT.open("w", encoding="utf-8", newline="\n") as output:
        while True:
            arguments = [
                "events",
                "read",
                "--session-id",
                latest["sessionId"],
                "--limit",
                "500",
                "--include-hex",
                "--include-text-preview",
                "--json",
            ]
            if cursor is not None:
                arguments.extend(["--cursor", cursor, "--resume-receipt", receipt or ""])

            page = run_json(*arguments)
            for event in page["events"]:
                output.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")))
                output.write("\n")

            if not page["integrity"]["completeForReturnedRange"]:
                print("WARNING: returned range is not proven complete")
                print(json.dumps(page["integrity"], ensure_ascii=False, indent=2))
                print(json.dumps(page["warnings"], ensure_ascii=False, indent=2))

            if not page["hasMore"]:
                break
            cursor = page["nextCursor"]
            receipt = page["resumeReceipt"]

    print(f"Session: {latest['displayName']} ({latest['sessionId']})")
    print(f"Output:  {OUTPUT.resolve()}")


if __name__ == "__main__":
    main()
