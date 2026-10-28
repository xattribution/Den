"""Turns `flutter analyze` or `flutter test` output into GitHub error annotations, so the
problems show on the pull request's checks without opening the job log: one annotation per
failed test (or per screenful of analyzer problems), each under GitHub's 4 KB limit.

    python3 annotate_failures.py analyze|test <output file> <title>
"""

import re
import sys

PER_ANNOTATION = 3800
MAX_ANNOTATIONS = 9
PROGRESS = re.compile(r'^\d+:\d\d \+\d+')


def analyze(lines):
    problems = [line.strip() for line in lines if ' • ' in line]
    chunks, current = [], []
    for p in problems:
        if current and len('\n'.join(current + [p])) > PER_ANNOTATION:
            chunks.append(current)
            current = []
        current.append(p)
    if current:
        chunks.append(current)
    return chunks


def tests(lines):
    """Each failed test's output. On GitHub Actions flutter test uses the GitHub reporter, which
    wraps a failed test's output in ::group::❌ ... ::endgroup::; elsewhere the compact reporter
    marks the test [E]."""
    failed, current = [], None
    for line in lines:
        if line.startswith('::group::❌'):
            current = [line[len('::group::'):]]
        elif line.startswith('::endgroup::'):
            if current is not None:
                failed.append(current)
            current = None
        elif current is not None:
            current.append(line)
        elif line.startswith('❌'):
            failed.append([line])
    if failed:
        return failed

    since_last, after_failure = [], False
    for line in lines:
        if PROGRESS.match(line):
            if line.rstrip().endswith('[E]'):
                failed.append([line, *since_last[-150:]])
                after_failure = True
            else:
                after_failure = False
            since_last = []
        elif after_failure:
            failed[-1].append(line)
        else:
            since_last.append(line)
    return failed


def escape(text):
    return text.replace('%', '%25').replace('\r', '').replace('\n', '%0A')


def main():
    mode, path, title = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(path, encoding='utf-8', errors='replace') as f:
        lines = f.read().splitlines()
    found = analyze(lines) if mode == 'analyze' else tests(lines)
    if not found:
        found = [lines[-60:]]
    for block in found[:MAX_ANNOTATIONS]:
        message = '\n'.join(block)
        if len(message) > PER_ANNOTATION:
            message = message[:PER_ANNOTATION] + '\n[cut]'
        print(f'::error title={title}::{escape(message)}')
    if len(found) > MAX_ANNOTATIONS:
        print(f'::error title={title}::{len(found) - MAX_ANNOTATIONS} more not shown')


if __name__ == '__main__':
    main()
