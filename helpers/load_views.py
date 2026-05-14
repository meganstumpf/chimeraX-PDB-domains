# Load named camera views from views/<basename>_views.cxc into the current
# session, if the file exists. Called near the top of each main .cxc script:
#
#   runscript ../helpers/load_views.py <basename>
#
# If the views file does not exist (e.g. before first-time setup), the script
# logs a warning and continues silently rather than erroring — letting headless
# runs proceed using the default camera. To create the file, see
# helpers/export_views.py.

import sys
from pathlib import Path
from chimerax.core.commands import run

if len(sys.argv) < 2:
    raise SystemExit("Usage: runscript load_views.py <basename>")
basename = sys.argv[1]

repo_root = Path(__file__).resolve().parent.parent
views_file = repo_root / "views" / f"{basename}_views.cxc"

if views_file.exists():
    run(session, f'open "{views_file}"')
    session.logger.info(f"Loaded camera views from {views_file.name}")
else:
    session.logger.warning(
        f"No saved views at {views_file.relative_to(repo_root)}; "
        f"camera commands referencing {basename}_* views will fail. "
        f"Run helpers/export_views.py after defining views interactively."
    )
