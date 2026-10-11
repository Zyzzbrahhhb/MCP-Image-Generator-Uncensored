"""python -m video_ext serve | download | codebooks"""

import argparse
import logging
import sys


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="video_ext", description=__doc__)
    parser.add_argument("command", choices=("serve", "download", "codebooks"))
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
                        datefmt="%H:%M:%S")
    if args.command == "serve":
        from .server import serve

        serve()
    elif args.command == "download":
        from .models import download

        download()
    else:
        from .models import codebooks

        codebooks()
    return 0


if __name__ == "__main__":
    sys.exit(main())
