"""Summarize real-device capture_saved messages copied from macOS Console."""

import argparse
import math
from pathlib import Path
import re


METRICS = ("total_ms", "confirmation_ms", "processing_ms")
TARGET_MS = 2_000
MESSAGE = re.compile(
    r"\bcapture_saved\s+total_ms=(\S+)\s+confirmation_ms=(\S+)\s+processing_ms=(\S+)"
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    samples = []
    try:
        with args.log.open(encoding="utf-8-sig") as log:
            for line_number, line in enumerate(log, 1):
                if not re.search(r"\bcapture_saved\b", line):
                    continue
                message = MESSAGE.search(line)
                try:
                    if message is None:
                        raise ValueError
                    sample = tuple(map(float, message.groups()))
                    if not all(math.isfinite(value) and value >= 0 for value in sample):
                        raise ValueError
                except ValueError:
                    parser.error(f"invalid capture_saved measurements on line {line_number}")
                samples.append(sample)
    except (OSError, UnicodeError) as error:
        parser.error(str(error))
    if not samples:
        parser.error("no capture_saved measurements in the log")

    rank = math.ceil(0.9 * len(samples))
    percentiles = [sorted(values)[rank - 1] for values in zip(*samples)]
    print(f"Samples: {len(samples)} (P90 nearest rank: {rank})")
    for metric, value in zip(METRICS, percentiles):
        print(f"{metric} P90: {value:.1f} ms")
    passed = percentiles[0] <= TARGET_MS
    print(f"Total P90 ≤ {TARGET_MS} ms: {'PASS' if passed else 'FAIL'}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
