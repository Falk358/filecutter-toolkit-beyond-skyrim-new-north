"""
Integration tests for FileCutterToolkit macros (Skyrim.py).

These tests launch LibreOffice Calc in headless mode, open a working copy of
the sample spreadsheet via UNO, and call the **real macro functions** exported
by Skyrim.py.  For each macro we verify that:

  1. Every cell in the target row gets the correct background colour.
  2. The "Filecutting Note" column receives the expected comment string.
  3. The "bonus" column (column index 6) remains transparent.

The original sample file is never modified — a temporary copy is used and
discarded after the test session.  Any LibreOffice lock files are also
cleaned up.
"""

import builtins
import glob
import importlib
import os
import shutil
import sys
import tempfile
import time

import pytest

# ---------------------------------------------------------------------------
# UNO bootstrap — connect to a headless LibreOffice instance
# ---------------------------------------------------------------------------

import uno
from com.sun.star.beans import PropertyValue


def _make_property(name, value):
    """Create a UNO PropertyValue."""
    prop = PropertyValue()
    prop.Name = name
    prop.Value = value
    return prop


def _connect_to_lo(max_attempts=30, delay=1.0):
    """
    Try to connect to a running LibreOffice instance listening on port 2002.
    Retries up to *max_attempts* times, sleeping *delay* seconds between tries.
    """
    local_context = uno.getComponentContext()
    resolver = local_context.ServiceManager.createInstanceWithContext(
        "com.sun.star.bridge.UnoUrlResolver", local_context
    )

    for attempt in range(max_attempts):
        try:
            ctx = resolver.resolve(
                "uno:socket,host=localhost,port=2002;"
                "urp;StarOffice.ComponentContext"
            )
            return ctx
        except Exception:
            if attempt == max_attempts - 1:
                raise RuntimeError(
                    f"Could not connect to LibreOffice after {max_attempts} "
                    "attempts.  Make sure soffice is running with "
                    "'--accept=socket,host=localhost,port=2002;urp;'"
                )
            time.sleep(delay)


# ---------------------------------------------------------------------------
# Project paths
# ---------------------------------------------------------------------------

PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
SAMPLE_FILE = os.path.join(PROJECT_DIR, "BSMNNMaleUniqueLustidrike.xlsx")


# ---------------------------------------------------------------------------
# Fixture — sets up LO, opens doc, imports Skyrim with mocked XSCRIPTCONTEXT
# ---------------------------------------------------------------------------

class _MockDesktop:
    """
    Mock desktop that returns the loaded document for getCurrentComponent.
    """

    def __init__(self, doc):
        self._doc = doc

    def getCurrentComponent(self):
        return self._doc


class _MockXSCRIPTCONTEXT:
    """
    Minimal stand-in for the XSCRIPTCONTEXT global that LibreOffice's macro
    runner normally injects.  Only ``getDesktop()`` is needed.
    """

    def __init__(self, mock_desktop):
        self._desktop = mock_desktop

    def getDesktop(self):
        return self._desktop


@pytest.fixture(scope="module")
def skyrim_env():
    """
    Module-scoped fixture that:

      1. Copies the sample .xlsx to a temporary directory.
      2. Connects to the already-running headless LibreOffice instance.
      3. Opens the working copy in Calc.
      4. Injects a mock ``XSCRIPTCONTEXT`` into builtins so that
         ``Skyrim.py`` can be imported normally.
      5. Imports ``Skyrim`` and patches ``copy_to_clipboard`` (the system
         clipboard service is unavailable over the UNO bridge).
      6. Yields ``(toolkit, sheet, doc)`` for the tests.
      7. Closes the document *without saving* and cleans up temp files,
         the builtins mock, and any lock files left behind.
    """
    # -- 1. Create a working copy ----------------------------------------
    tmp_dir = tempfile.mkdtemp(prefix="filecutter_test_")
    work_file = os.path.join(tmp_dir, os.path.basename(SAMPLE_FILE))
    shutil.copy2(SAMPLE_FILE, work_file)

    # -- 2. Connect to LibreOffice ---------------------------------------
    ctx = _connect_to_lo()
    smgr = ctx.ServiceManager
    desktop = smgr.createInstanceWithContext(
        "com.sun.star.frame.Desktop", ctx
    )

    # -- 3. Open the working copy ----------------------------------------
    file_url = "file://" + work_file
    doc = desktop.loadComponentFromURL(
        file_url,
        "_blank",
        0,
        (
            _make_property("Hidden", True),
            _make_property("MacroExecutionMode", 4),
        ),
    )
    assert doc is not None, f"Failed to open {file_url}"

    # -- 4. Inject mock XSCRIPTCONTEXT -----------------------------------
    mock_desktop = _MockDesktop(doc)
    builtins.XSCRIPTCONTEXT = _MockXSCRIPTCONTEXT(mock_desktop)

    # -- 5. Import Skyrim (force fresh import) ---------------------------
    # Ensure Skyrim.py's directory is on sys.path so it can be found.
    if PROJECT_DIR not in sys.path:
        sys.path.insert(0, PROJECT_DIR)

    # Drop any cached import so we get a fresh one with our mock active.
    sys.modules.pop("Skyrim", None)
    Skyrim = importlib.import_module("Skyrim")

    # Patch clipboard — the system clipboard service is not available
    # over the remote UNO bridge; clipboard behaviour is out of scope.
    Skyrim.TOOLKIT.copy_to_clipboard = lambda data: None

    sheet = doc.Sheets.getByIndex(0)

    yield Skyrim, sheet, doc

    # -- 6. Teardown -----------------------------------------------------
    try:
        doc.setModified(False)
        doc.close(True)
    except Exception:
        pass

    # Remove the builtins mock
    if hasattr(builtins, "XSCRIPTCONTEXT"):
        del builtins.XSCRIPTCONTEXT

    # Remove Skyrim from sys.modules so later imports aren't poisoned
    sys.modules.pop("Skyrim", None)

    # Remove temp directory
    shutil.rmtree(tmp_dir, ignore_errors=True)

    # Clean up any lock files
    for lock_file in glob.glob(os.path.join(PROJECT_DIR, ".~lock.*")):
        try:
            os.remove(lock_file)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _select_row(doc, sheet, row_number):
    """Select a cell in the given row so ``get_selected_row()`` returns it."""
    cell = sheet.getCellByPosition(0, row_number)
    doc.CurrentController.select(cell)


def _verify_row(sheet, row_number, expected_color, expected_comment, format_map):
    """
    Assert that a row has been correctly committed:

      1. All format columns have the expected background colour.
      2. The "Filecutting Note" column holds the expected comment.
      3. The bonus column (one past the last format column) is transparent.
    """
    total_cols = len(format_map)
    comment_col = format_map["Filecutting Note"]

    # Check colour on every format column
    for col_idx in range(total_cols):
        cell = sheet.getCellByPosition(col_idx, row_number)
        actual_color = cell.CellBackColor
        assert actual_color == expected_color, (
            f"Row {row_number}, Col {col_idx}: expected colour "
            f"0x{expected_color:06X} but got 0x{actual_color:06X}"
        )

    # Check filecutting note content
    actual_comment = sheet.getCellByPosition(comment_col, row_number).String
    assert actual_comment == expected_comment, (
        f"Row {row_number}: expected Filecutting Note "
        f"{expected_comment!r} but got {actual_comment!r}"
    )

    # Check bonus column is transparent
    bonus_cell = sheet.getCellByPosition(total_cols, row_number)
    assert bonus_cell.IsCellBackgroundTransparent, (
        f"Row {row_number}: bonus column (col {total_cols}) "
        f"should be transparent but has colour "
        f"0x{bonus_cell.CellBackColor:06X}"
    )


# ---------------------------------------------------------------------------
# Tests — one per macro, each calling the REAL exported function
# ---------------------------------------------------------------------------

def test_perfect(skyrim_env):
    """Macro: perfect — row 3, cyan (0x00B0F0), comment 'Perfect'."""
    Skyrim, sheet, doc = skyrim_env
    row = 3
    _select_row(doc, sheet, row)

    Skyrim.Perfect()

    _verify_row(sheet, row, Skyrim.TOOLKIT.PERFECT_COLOR, "Perfect",
                Skyrim.TOOLKIT.current_format)


def test_mispelled(skyrim_env):
    """Macro: mispelled — row 4, purple (0x7030A0), template comment."""
    Skyrim, sheet, doc = skyrim_env
    row = 4
    _select_row(doc, sheet, row)

    Skyrim.Mispelled()

    _verify_row(
        sheet, row, Skyrim.TOOLKIT.MISPELLED_COLOR,
        "Script error: TODO red highlight of mispell and comment",
        Skyrim.TOOLKIT.current_format,
    )


def test_sound_quality(skyrim_env):
    """Macro: sound_quality — row 5, orange (0xFFC000), template comment."""
    Skyrim, sheet, doc = skyrim_env
    row = 5
    _select_row(doc, sheet, row)

    Skyrim.SoundQuality()

    _verify_row(
        sheet, row, Skyrim.TOOLKIT.SOUND_QUALITY_COLOR,
        "Sound quality: TODO describe the problem",
        Skyrim.TOOLKIT.current_format,
    )


def test_acting(skyrim_env):
    """Macro: acting — row 6, green (0x00B050), template comment."""
    Skyrim, sheet, doc = skyrim_env
    row = 6
    _select_row(doc, sheet, row)

    Skyrim.Acting()

    _verify_row(
        sheet, row, Skyrim.TOOLKIT.ACTING_COLOR,
        "Acting: TODO helpful comment for the voice actor",
        Skyrim.TOOLKIT.current_format,
    )


def test_mispronunced(skyrim_env):
    """Macro: mispronunced — row 7, blue (0x0070C0), template comment."""
    Skyrim, sheet, doc = skyrim_env
    row = 7
    _select_row(doc, sheet, row)

    Skyrim.Mispronunced()

    _verify_row(
        sheet, row, Skyrim.TOOLKIT.MISPRONUNCED_COLOR,
        "Mispronunciation: TODO red highlight of mispronunced word and comment",
        Skyrim.TOOLKIT.current_format,
    )


def test_missing(skyrim_env):
    """Macro: missing — row 8, red (0xFF0000), comment 'Missing'."""
    Skyrim, sheet, doc = skyrim_env
    row = 8
    _select_row(doc, sheet, row)

    Skyrim.Missing()

    _verify_row(
        sheet, row, Skyrim.TOOLKIT.MISSING_COLOR,
        "Missing",
        Skyrim.TOOLKIT.current_format,
    )
