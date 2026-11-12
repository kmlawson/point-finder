# Point Finder

A macOS app that finds where the graticule lines (meridians and parallels) cross
on a scanned map, puts a ground control point on each crossing, and works out
every point's latitude and longitude once you have typed in two of them. It
saves a `.points` file that the QGIS Georeferencer opens directly.

## Status

Work in progress.

- The detection, the coordinate solver and the `.points` reader/writer are
  written and covered by tests (`swift test`, 43 tests).
- On the 5007 × 3328 sample atlas sheet (curved meridians and parallels, a book
  gutter, heavy lettering) detection finds 74 intersections (one of them inferred) in about a second,
  numbered consistently across both pages.
- The app window has been checked through its self-snapshot mode (detect,
  reference points, calculate, add, undo/redo, review). The magnifier, snapping
  on drop, the area drag and the Preferences window have **not** been exercised
  by hand yet, and tick-only detection has only been tried on a drawn test map,
  not a real scan.
- Not yet checked: loading a saved file into the QGIS Georeferencer.

## Build and run

Needs macOS 13 or later and the Xcode command-line tools.

```bash
scripts/build-app.sh      # builds PointFinder.app in this folder
open PointFinder.app
swift test                # run the tests
```

## Using it

1. **Open** a map image (⌘O, or drop it on the window). If a control-point file
   with the map's name is beside it (`map.jpg.points` or `map.points`), its
   points are loaded. Otherwise detection runs straight away.
2. **Detect** (⌘D) marks each graticule intersection with an orange circle.
   Detection settings (contrast, shortest line, black ink only) are in the
   toolbar.
3. Click an intersection and type its **longitude and latitude**. Do this for
   two intersections that are diagonal from each other (different meridians and
   different parallels). Accepted forms: `110E`, `-110.5`, `35°30'N`, `35 30 S`.
4. **Calculate** (⌘K) fills in every other intersection from the grid.
5. **Save** (⌘S) writes the `.points` file. The default name is the image's
   full name plus `.points`, which is what QGIS looks for.

Quitting with points that have coordinates but are not saved asks whether to
save them first.

### Less typing: margin labels

**Read Labels** (⌘L) reads the degree numbers printed in the margins with
Apple's Vision text recognition, matches each to the grid line it stands at the
end of, and keeps the evenly stepped sequence most labels agree on (so an
inset's own numbers or atlas index figures are outvoted). It then shows the
longitudes and latitudes this gives the grid. Confirm, and two reference points
are set and the rest calculated. East/west and north/south are judged from the
direction the numbers run, assuming north is up; it needs at least three
agreeing labels each way. Preferences ▸ Automation can run it after every
detection.

### Review, confidence and undo

- The points table has a **Conf.** column: how clearly the detector saw each
  crossing (the weakest of its four arms), or "inferred". Click a column header
  to sort by it.
- **Review** (⇧⌘R) steps through the doubtful points, zoomed in: inferred ones
  first, then those below the confidence set in Preferences ▸ Review. Return
  accepts, Delete removes, the arrow keys nudge, Tab or Space skips (⇧ goes
  back), Esc stops. An accepted point is marked ✓ and is not offered again.
- **Undo / Redo** (⌘Z / ⇧⌘Z) cover every change to the points: moves, deletes,
  coordinates, Detect, Calculate, Second Opinion and label reading. While a
  text field is being edited they apply to the typing instead.

### Moving around

- ⌘ with an arrow key selects the next intersection along the same parallel or
  meridian (the nearest point that way for points off the grid).
- **Zoom to Selection** (⌘E) centres and zooms on the selected point.
- While a point is dragged a **magnifier** shows the map under it enlarged.
- A point dropped near a crossing **snaps** onto it; hold Control while letting
  go to place it freely.

The magnifier, snapping, navigation zoom, the review threshold and the two
automation switches are in **Preferences** (⌘,).

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

### Maps with ticks only

Detection Settings ▸ Graticule ▸ **Ticks on the frame only** is for maps that
show the graticule as ticks along the frame with no lines across the sheet. It
finds the frame, the ticks on its four sides (the longer ones, where long and
short alternate), joins each tick to the one opposite with a straight line and
marks where those lines cross. The crossings are constructed, not seen, so they
are right for maps with straight meridians and parallels and approximate where
the real lines would curve.

Editing points:

| Action | How |
| --- | --- |
| Add a point | Option-click the map, or turn on Add Points and click |
| Move a point | Drag it, or arrow keys (⇧ 10 px, ⌥ 0.1 px) |
| Go to the next point | ⌘ with an arrow key |
| Remove a point | Select it and press Delete |
| Type coordinates | Return on the map, or double-click the point |
| Leave a point out | Untick Use; it is saved switched off |

Added points (squares) get an estimated coordinate from the surrounding grid
after Calculate; type the true value or use Snap to Graticule.

Marker colours: orange = no coordinate, blue = typed by you, green =
calculated, purple = estimated, grey = switched off.

A **red** marker is an inferred intersection: the image does not show a clean
crossing there (lettering, a title box or dense linework is in the way), so the
point was placed from the fitted lines or from its neighbours. It is numbered
and calculated like any other grid point. Check its position; dragging or
nudging it makes it an ordinary point, and giving it coordinates by hand turns
it blue. Turn this off with "Infer hidden intersections from the lines" in the
detection settings.

### Second opinion on an area

**Second Opinion** (⌘R) lets you drag a rectangle over part of the map where
intersections are missing. That area is searched again using the grid already
found: each empty grid position predicted to fall inside the rectangle is
looked for in the image, more leniently than in the automatic pass, and one
step beyond the outermost known lines. What it finds is added as ordinary
points; a gap between known points that the image still does not confirm gets
a red inferred point (if inference is on). It needs the grid from Detect, and
uses every grid point on the map as context, inside the rectangle or not.

Detection Settings ▸ "Guided search and second opinion" holds the controls for
this and for the automatic guided search: on/off, search distance, how much of
a line must show, second-opinion leniency, and whether a second opinion may add
a line beyond the grid.

## Opening the result in QGIS

Layer ▸ Georeferencer, open the same image; if the file is named
`<image name>.points` it loads by itself, otherwise use File ▸ Load GCP Points.
Coordinates are longitude/latitude in WGS 84 (EPSG:4326). For a map with curved
graticule lines choose Thin Plate Spline or a higher-order polynomial.

## How detection works

1. Keep only thin dark strokes (a black top-hat filter), and drop small
   isolated marks such as lettering.
2. In overlapping tiles, find straight runs of ink that cross the whole tile
   (Hough transform), rejecting runs with as much ink beside them as on them.
3. Join runs that continue one another into long smooth curves. Pieces
   separated by a gap, or by a misaligned book gutter, are treated as one line.
4. Split the lines into two families, drop lines that cross their own family
   (routes, borders) and lines whose crossings are mostly dead ends (the frame).
5. Intersect the two families and pin each crossing down in the
   full-resolution image by following both lines outward on all four sides.
6. Number the lines from the spacing of their crossings, leaving a gap in the
   numbering where a line was missed.
7. Guided search (optional, on by default). Every empty position in the
   numbered grid is predicted from its neighbours along its row and its column,
   from both sides and from each side alone, so that a line broken at the
   gutter is followed from its own page. A crossing is accepted near the
   predicted spot when both lines show on all four sides close up, carry on
   over three times that distance, run in the expected directions, and are not
   lines already ruled out (the frame, routes). New finds feed further
   predictions. This is what recovers a parallel found on one page only, or a
   meridian lost beside the gutter. It adds no new lines outside the grid; the
   Second Opinion tool may.
8. Fill in hidden crossings (optional, on by default). Where two found lines
   cross but the crossing failed the check in step 5, the point is placed where
   the fitted lines meet. Where a found line runs through a gap in a line of the
   other family, the point is placed on the found line, spaced like its
   neighbours along it; if the image then shows a clean crossing there it counts
   as detected, otherwise it is marked inferred. Nothing is placed beyond the
   ends of a line, or for a line that was not found at all.

Because coordinates come from the grid numbering, not from pixel positions, the
calculation is exact for any projection whose graticule is evenly spaced in
degrees.

Limits: lines must be continuous (not just ticks at the frame), reasonably
dark, and gently curved. Polar maps with circular parallels are not handled.

## Command line

`swift run -c release pointfinder-cli <image> --overlay out.png` prints the
intersections and draws what was found; `--help` lists the options, including
`--second-opinion x0,y0,x1,y1`, `--read-labels`, `--guess-projection` and
`--ticks` to try those features without the app.

## Versions and license

Versions are `1.<build>`: the build number goes up by one with each committed
set of changes (`Sources/PointFinderCore/Version.swift`). Released under the
MIT license; see `LICENSE`.

## Layout

- `Sources/PointFinderCore` — detection, solver, file format (no interface code)
- `Sources/PointFinder` — the app
- `Sources/pointfinder-cli` — command-line detector
- `Tests/PointFinderCoreTests` — tests
- `scripts/build-app.sh` — packages the app

Setting `PF_SNAPSHOT_DIR=<folder>` when launching makes the app run through
detect → reference points → calculate → add point → undo/redo → review, write
pictures of its window to that folder, and quit; `PF_SNAPSHOT_IMAGE=<file>`
names the map to open. It is a development aid for the sample map.
