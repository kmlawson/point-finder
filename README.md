# Point Finder

Point Finder is a macOS app for georeferencing scanned maps. It finds where the
map's graticule lines (meridians and parallels) cross, puts a ground control
point on every crossing, and works out each point's longitude and latitude once
two of them are known. It saves a `.points` file that the QGIS Georeferencer
opens directly.

Georeferencing a map by hand means clicking dozens of intersections and typing
two numbers for each. With Point Finder the usual job is: open the scan, check
the points it found, give two of them coordinates (or let it read the degree
numbers in the margin), and save.

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [The window](#the-window)
- [Giving the grid its coordinates](#giving-the-grid-its-coordinates)
- [Checking and correcting points](#checking-and-correcting-points)
- [Finding what detection missed](#finding-what-detection-missed)
- [Other tools](#other-tools)
- [Opening the result in QGIS](#opening-the-result-in-qgis)
- [How it works](#how-it-works)
- [Limits and status](#limits-and-status)
- [Command line](#command-line)
- [Building and developing](#building-and-developing)
- [Versions and license](#versions-and-license)

## Install

**From a release.** Download `PointFinder-<version>.zip` from the
[releases page](https://github.com/kmlawson/point-finder/releases), unzip it
and move `PointFinder.app` to Applications. It needs macOS 13 or later on an
Apple silicon Mac.

The app is not signed with an Apple developer certificate, so macOS will refuse
to open it the first time. Either open System Settings ▸ Privacy & Security and
choose **Open Anyway** after the first attempt, or remove the download flag in
Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/PointFinder.app
```

**From source.** With the Xcode command-line tools installed:

```bash
git clone https://github.com/kmlawson/point-finder.git
cd point-finder
scripts/build-app.sh      # builds PointFinder.app in this folder
open PointFinder.app
```

## Quick start

1. **Open** a map image (⌘O, or drop it on the window). Detection runs straight
   away and marks each graticule intersection with an orange circle. If a
   control-point file with the map's name is already beside the image
   (`map.jpg.points` or `map.points`), its points are loaded instead.
2. Click an intersection and type its **longitude and latitude**. Do this for
   two intersections that are diagonal from each other (on different meridians
   and different parallels). Accepted forms: `110E`, `-110.5`, `35°30'N`,
   `35 30 S`.
3. **Calculate** (⌘K) fills in every other intersection from the grid.
4. **Review** (⇧⌘R) steps through the points the detector was least sure of.
5. **Save** (⌘S) writes the `.points` file. The default name is the image's
   full name plus `.points`, which is what QGIS looks for.

Quitting with points that have coordinates but are not saved asks whether to
save them first.

## The window

- **The map**, on the left. Scroll or pinch to move and zoom; a mouse wheel
  zooms about the pointer. View ▸ Zoom In / Zoom Out / Actual Size / Zoom to
  Fit (⌘+ ⌘− ⌘1 ⌘0) zoom about the middle, and Zoom to Selection (⌘E) centres
  on the selected point.
- **The inspector**, top right, shows the selected point and takes its
  coordinates.
- **The points table**, below it, lists every point. Click a column header to
  sort. The **Conf.** column is how clearly the detector saw the crossing.
- **The status bar** along the bottom reports what the last action did.

Marker colours:

| Colour | Meaning |
| --- | --- |
| Orange | No coordinate yet |
| Blue | Coordinate typed by you (a reference point) |
| Green | Coordinate calculated from the grid |
| Purple | Coordinate estimated (a point you added off the grid) |
| Red | Inferred intersection: placed from the lines, not seen in the image |
| Grey | Switched off; saved but not used |

Circles are grid intersections; squares are points you added.

### Toolbar

The toolbar can be changed: right-click it, or choose View ▸ **Customize
Toolbar…**, then drag buttons in, out or into another order. The same sheet
switches between icons only and icons with their names, and dragging the
default set back restores it. The arrangement is remembered.

It starts with Open, Save, Undo, Redo, Detect, Detection Settings, Second
Opinion, Read Labels, Calculate, Review, Add Points, Zoom to Fit and the View
menu. Also on offer: Save As, Guess Projection, Delete Point, Coordinates
(type the selected point's values), Snap to Graticule, West / East / North /
South (move the selection along the grid), Zoom Out, Zoom In, Actual Size, Zoom
to Selection, Lines and Labels (show or hide them), Magnifier and Snap (the two
Preferences switches) and Preferences.

### Preferences

**Preferences** (⌘,) holds the settings that are remembered between launches:
the magnifier and its size, snapping and its reach, whether moving between
points zooms in, the confidence below which a point is offered for review, and
two automation switches (read the margin labels after every detection; save a
projection guess with the points).

## Giving the grid its coordinates

Every grid point carries a column number and a row number: which meridian and
which parallel it is on, counted across the sheet. Coordinates are worked out
from those numbers, so only two points need real values.

**By typing.** Give two diagonal intersections their coordinates and press
Calculate. More reference points are welcome; they must agree with one another.

**By reading the margin.** **Read Labels** (⌘L) reads the degree numbers
printed in the margins with Apple's Vision text recognition, matches each to
the grid line it stands at the end of, and keeps the evenly stepped sequence
most labels agree on, so that an inset's own numbers or atlas index figures are
outvoted. It shows the longitudes and latitudes this gives the grid; confirm,
and two reference points are set and the rest calculated. East/west and
north/south are judged from the direction the numbers run, assuming north is
up, and it needs at least three agreeing labels each way.

## Checking and correcting points

| Action | How |
| --- | --- |
| Add a point | Option-click the map, or turn on Add Points and click |
| Move a point | Drag it, or arrow keys (⇧ 10 px, ⌥ 0.1 px) |
| Go to the next point | ⌘ with an arrow key |
| Remove a point | Select it and press Delete |
| Type coordinates | Return on the map, or double-click the point |
| Leave a point out | Untick Use; it is saved switched off |
| Undo / Redo | ⌘Z / ⇧⌘Z |

- **Review** (⇧⌘R) steps through the doubtful points, zoomed in: inferred ones
  first, then those below the confidence set in Preferences, least confident
  first. Return accepts, Delete removes, the arrow keys nudge, Tab or Space
  skips (⇧ goes back), Esc stops. An accepted point is marked ✓ and is not
  offered again.
- **Confidence** is the weakest of a crossing's four arms: 100% means both
  lines show clearly on every side of the point.
- While a point is dragged a **magnifier** shows the map under it enlarged.
- A point dropped near a crossing **snaps** onto it; hold Control while letting
  go to place it freely. Arrow-key nudges never snap.
- ⌘ with an arrow key selects the next intersection along the same parallel or
  meridian (the nearest point that way for points off the grid).
- **Undo and Redo** cover every change to the points: moves, deletes,
  coordinates, Detect, Calculate, Second Opinion and label reading. While a
  text field is being edited they apply to the typing instead.

**Inferred (red) points.** Where the image does not show a clean crossing
(lettering, a title box or dense linework is in the way) the point is placed
from the fitted lines or from its neighbours. It is numbered and calculated
like any other grid point. Check its position; dragging or nudging it makes it
an ordinary point. Turn this off with "Infer hidden intersections from the
lines" in the detection settings.

**Added points (squares)** get an estimated coordinate from the surrounding
grid after Calculate. Type the true value, or use Snap to Graticule to round it
to the nearest crossing of the grid.

## Finding what detection missed

**Detection Settings** in the toolbar adjusts the search and runs it again.
Points you added, and points you gave coordinates to, are kept.

- **Line contrast**: lower finds fainter lines; higher ignores more clutter.
- **Shortest line**: lower picks up short lines, such as those of an inset.
- **Black ink only**: ignores coloured lines such as rivers and routes.
- **Graticule**: lines across the map, or ticks on the frame only (below).

**Second Opinion** (⌘R) is for a part of the map where intersections are still
missing. Drag a rectangle over it. That area is searched again using the grid
already found: each empty grid position predicted to fall inside the rectangle
is looked for in the image, more leniently than in the automatic pass, and one
step beyond the outermost known lines. What it finds is added as ordinary
points; a gap between known points that the image still does not confirm gets
a red inferred point. It uses every grid point on the map as context, inside
the rectangle or not. Points it adds near the frame deserve a second look.

Detection Settings ▸ "Guided search and second opinion" holds the controls for
this and for the automatic guided search: on/off, search distance, how much of
a line must show, second-opinion leniency, and whether a second opinion may add
a line beyond the grid.

## Other tools

### Maps with ticks only

Detection Settings ▸ Graticule ▸ **Ticks on the frame only** is for maps that
show the graticule as ticks along the frame with no lines across the sheet. It
finds the frame, the ticks on its four sides (the longer ones, where long and
short alternate), joins each tick to the one opposite with a straight line and
marks where those lines cross. The crossings are constructed, not seen, so they
are right for maps with straight meridians and parallels and approximate where
the real lines would curve.

### Projection guess

Points ▸ **Guess Projection…** classifies the projection from the shape of the
grid: straight or curved meridians and parallels, whether meridians converge,
and how the parallels are spaced. It reports the likely family (cylindrical,
conic, pseudocylindrical, or curved-both such as Bonne and polyconic), the
evidence, and, once coordinates are calculated, estimated parameters such as
the central meridian and a PROJ string to start from. It is an estimate from
geometry, not something read from the map. After you have asked for it (or
always, with the Preferences switch) it is saved as `<points file minus
.points>.projection.txt` beside the points.

## Opening the result in QGIS

Layer ▸ Georeferencer, open the same image. If the file is named
`<image name>.points` it loads by itself; otherwise use File ▸ Load GCP Points.
Coordinates are longitude/latitude in WGS 84 (EPSG:4326). For a map with curved
graticule lines choose Thin Plate Spline or a higher-order polynomial; for
straight, evenly spaced lines a first-order polynomial is enough.

### The file

A `.points` file is plain text:

```
#CRS: <WGS 84 definition>
mapX,mapY,sourceX,sourceY,enable,dX,dY,residual
105,45,2452,-945.7,1,0,0,0
```

`mapX`/`mapY` are longitude and latitude. `sourceX`/`sourceY` are image pixels
from the top-left corner, with Y negative downwards, which is how the
Georeferencer addresses an image that has no georeference yet. `enable` is 0
for a point switched off. Points without a coordinate are not written.

## How it works

### Detection

1. **Isolate the linework.** Keep only thin dark strokes (a black top-hat
   filter), and drop small isolated marks such as lettering.
2. **Find straight runs.** In overlapping tiles, find straight runs of ink that
   cross the whole tile (a Hough transform), rejecting runs with as much ink
   beside them as on them.
3. **Join runs into lines.** Runs that continue one another are joined into
   long smooth curves. Pieces separated by a gap, or by a misaligned book
   gutter, are treated as one line.
4. **Sort the lines.** Split them into two families, drop lines that cross
   their own family (routes, borders) and lines whose crossings are mostly dead
   ends (the frame).
5. **Pin down the crossings.** Intersect the two families and locate each
   crossing in the full-resolution image by following both lines outward on all
   four sides. A crossing whose arms do not all show is rejected.
6. **Number the lines** from the spacing of their crossings, leaving a gap in
   the numbering where a line was missed.
7. **Guided search** (on by default). Every empty position in the numbered grid
   is predicted from its neighbours along its row and its column, from both
   sides and from each side alone, so that a line broken at the gutter is
   followed from its own page. A crossing is accepted near the predicted spot
   when both lines show on all four sides close up, carry on over three times
   that distance, run in the expected directions, and are not lines already
   ruled out (the frame, routes). New finds feed further predictions. This is
   what recovers a parallel found on one page only, or a meridian lost beside
   the gutter. It adds no new lines outside the grid; Second Opinion may.
8. **Fill in hidden crossings** (on by default). Where two found lines cross
   but the crossing failed the check in step 5, the point is placed where the
   fitted lines meet. Where a found line runs through a gap in a line of the
   other family, the point is placed on the found line, spaced like its
   neighbours along it; if the image then shows a clean crossing there it
   counts as detected, otherwise it is marked inferred. Nothing is placed
   beyond the ends of a line, or for a line that was not found at all.

### Coordinates

Longitude is taken to be a straight-line function of the column number and
latitude of the row number: each meridian is a fixed number of degrees from the
next, and likewise each parallel. Two reference points on different meridians
and different parallels fix both functions, and every other grid point follows
from its numbers alone. Extra reference points are fitted together; if they do
not agree with a regular grid, Calculate says so and changes nothing.

Because coordinates come from the grid numbering and not from pixel positions,
the result is exact for any projection whose graticule is drawn at even
intervals of degrees, however the lines curve on the sheet. The projection
matters only later, when QGIS warps the image to fit the points.

A point added off the grid is estimated from the nearest points with known
coordinates by a local fit, and is marked as an estimate.

## Limits and status

Work in progress.

- Lines must be reasonably dark and gently curved. Polar maps with circular
  parallels are not handled. Insets with their own graticule are not treated
  separately.
- Tick-only detection has been tried on a drawn test map only, not a real scan.
- The projection guess has not been checked against maps of known projection.
- Detection, the coordinate solver and the `.points` reader/writer are covered
  by tests (`swift test`, 43 tests).
- On a 5007 × 3328 atlas sheet with curved meridians and parallels, a book
  gutter and heavy lettering, detection finds 74 intersections (one inferred)
  in about a second, numbered consistently across both pages.
- The app window has been checked through its self-snapshot mode (detect,
  reference points, calculate, add, undo/redo, review, the toolbar's
  customisation sheet). The magnifier, snapping on drop, the area drag, the
  buttons added to the toolbar and the Preferences window have **not** been
  exercised by hand yet.
- Not yet checked: loading a saved file into the QGIS Georeferencer.

## Command line

The detector also runs without the app:

```bash
swift run -c release pointfinder-cli map.jpg --overlay found.png
```

It prints one line per intersection (column, row, pixel x, pixel y, quality,
inferred) and, with `--overlay`, draws what it found on a reduced copy of the
image. `--help` lists the options, among them `--contrast`, `--min-line`,
`--black-only`, `--ticks`, `--second-opinion x0,y0,x1,y1`, `--read-labels` and
`--guess-projection`.

## Building and developing

Needs macOS 13 or later and the Xcode command-line tools.

```bash
scripts/build-app.sh      # builds PointFinder.app
swift test                # run the tests
```

Layout:

- `Sources/PointFinderCore` — detection, solver, file format (no interface code)
- `Sources/PointFinder` — the app
- `Sources/pointfinder-cli` — command-line detector
- `Tests/PointFinderCoreTests` — tests
- `scripts/build-app.sh` — packages the app

Setting `PF_SNAPSHOT_DIR=<folder>` when launching makes the app run through
detect → reference points → calculate → add point → undo/redo → review →
toolbar customisation sheet, write pictures of its window to that folder, and
quit; `PF_SNAPSHOT_IMAGE=<file>` names the map to open. It is a development
aid: the reference points it sets are those of the sample map it was written
for.

## Versions and license

Versions are `1.<build>`: the build number goes up by one with each committed
set of changes (`Sources/PointFinderCore/Version.swift`). Released under the
MIT license; see `LICENSE`.
