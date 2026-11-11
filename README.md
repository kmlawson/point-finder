# Point Finder

A macOS app that finds where the graticule lines (meridians and parallels) cross
on a scanned map, puts a ground control point on each crossing, and works out
every point's latitude and longitude once you have typed in two of them. It
saves a `.points` file that the QGIS Georeferencer opens directly.

## Status

Work in progress.

- The detection, the coordinate solver and the `.points` reader/writer are
  written and covered by tests (`swift test`, 20 tests).
- On the 5007 × 3328 sample atlas sheet (curved meridians and parallels, a book
  gutter, heavy lettering) detection finds 61 intersections in under a second,
  numbered consistently across both pages.
- The app window compiles and packages, but **has not yet been seen running**:
  it was built in a session that could not open windows or take screenshots.
  Expect to find interface bugs on first launch.
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

Editing points:

| Action | How |
| --- | --- |
| Add a point | Option-click the map, or turn on Add Points and click |
| Move a point | Drag it, or arrow keys (⇧ 10 px, ⌥ 0.1 px) |
| Remove a point | Select it and press Delete |
| Type coordinates | Return on the map, or double-click the point |
| Leave a point out | Untick Use; it is saved switched off |

Added points (squares) get an estimated coordinate from the surrounding grid
after Calculate; type the true value or use Snap to Graticule.

Marker colours: orange = no coordinate, blue = typed by you, green =
calculated, purple = estimated, grey = switched off.

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

Because coordinates come from the grid numbering, not from pixel positions, the
calculation is exact for any projection whose graticule is evenly spaced in
degrees.

Limits: lines must be continuous (not just ticks at the frame), reasonably
dark, and gently curved. Polar maps with circular parallels are not handled.

## Command line

`swift run -c release pointfinder-cli <image> --overlay out.png` prints the
intersections and draws what was found; `--help` lists the options.

## Layout

- `Sources/PointFinderCore` — detection, solver, file format (no interface code)
- `Sources/PointFinder` — the app
- `Sources/pointfinder-cli` — command-line detector
- `Tests/PointFinderCoreTests` — tests
- `scripts/build-app.sh` — packages the app

Setting `PF_SNAPSHOT_DIR=<folder>` when launching makes the app run through
detect → reference points → calculate → add point, write pictures of its window
to that folder, and quit. It is a development aid for the sample map.
