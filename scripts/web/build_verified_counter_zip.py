"""Build the fixed counter in a fresh workspace and emit only validated ZIP bytes."""
import pathlib
import sys
import tempfile

from run_counter_journal_smoke import (
    generate_counter,
    validate_generated_zip,
    verify_browser_tests,
)


def main():
    with tempfile.TemporaryDirectory(prefix='aivexus-counter-') as temporary:
        output = pathlib.Path(temporary) / 'build'
        generate_counter(output)
        archive = validate_generated_zip(output / 'aivexus-web-counter-smoke.zip')
        if not verify_browser_tests():
            raise RuntimeError('Counter tests failed')
        sys.stdout.buffer.write(archive)


if __name__ == '__main__':
    main()
