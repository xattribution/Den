"""Turns `flutter analyze` or `flutter test` output into one GitHub error annotation, so the
problems show on the pull request's checks without opening the job log.

    python3 annotate_failures.py analyze|test <output file> <title>
"""

import re
import sys

LIMIT = 30000
PROGRESS = re.compile(r'^\d+:\d\d \+\d+')


def analyze(lines):
    return [line.strip() for line in lines if ' • ' in line]


def tests(lines):
    """Each failed test's output: what it printed since the previous test, its [E] line, and
    what came after until the next test."""
    found, since_last, after_failure = [], [], False
    for line in lines:
        if PROGRESS.match(line):
            if line.rstrip().endswith('[E]'):
                found += ['', *since_last[-150:], line]
                after_failure = True
            else:
                after_failure = False
            since_last = []
        elif after_failure:
            found.append(line)
        else:
            since_last.append(line)
    return found


def escape(text):
    return text.replace('%', '%25').replace('\r', '').replace('\n', '%0A')


def main():
    mode, path, title = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(path, encoding='utf-8', errors='replace') as f:
        lines = f.read().splitlines()
    found = analyze(lines) if mode == 'analyze' else tests(lines)
    if not found:
        found = lines[-120:]
    message = '\n'.join(found)
    if len(message) > LIMIT:
        message = message[:LIMIT] + '\n[cut]'
    print(f'::error title={title}::{escape(message)}')


if __name__ == '__main__':
    main()
