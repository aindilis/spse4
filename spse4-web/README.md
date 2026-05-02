# spse4-web

Browser client for [SPSE4](https://github.com/aindilis/spse4). Renders
task graphs from a running `pack-spse4-server` using Cytoscape.js.

Single-page app. No framework, no build step. One HTML, one CSS, one JS.
Drop into any static file server or let `pack-spse4-server` serve it via
its `client_dir` option.

## Features

- Interactive graph view of any microtheory's task DAG
- Hierarchical left-to-right layout (dagre), stable across reloads
- Status-coded node fills with light/dark-mode-aware palette
- Critical-path overlay (purple borders, thicker edges)
- Hover any node for a tooltip with label, duration, deadlines, resources
- Hover highlight: 1-hop neighborhood stays bright, the rest dims
- Filter chips: toggle any status or relation kind, instantly
- Goal focus: restrict view to one goal's connected component
- Detail panel: full task metadata, blockers list, forward+backward deps
- Click any edge-list item to jump to that node
- Live event polling: new/changed tasks repaint within 3 seconds
- Keyboard: `r` refresh, `f` focus selected, `Esc` clear selection/goal

## Running against the demo server

From the SPSE4 root:

```sh
swipl pack-spse4-server/examples/server_demo.pl
```

Then open http://localhost:4040/ in a browser. Or with credentials:

```
http://localhost:4040/?u=alice&p=hunter2&mt=autopackager
```

## Running standalone

The client only needs a base URL and credentials. If you serve this
directory from a different host than your SPSE4 server, edit `app.js`
and change `State.baseUrl` at the top of the file.

```sh
cd spse4-web
python3 -m http.server 8000
```

Then point a browser at http://localhost:8000/ and make sure the
SPSE4 server's CORS permits your origin.

## Status color map

| Status         | Color ramp | Reasoning                              |
|----------------|------------|----------------------------------------|
| `completed`    | green      | positive, done                         |
| `in_progress`  | amber      | caution / active attention             |
| `open`         | gray       | neutral, not yet started               |
| `cancelled`    | red        | ended without completion               |
| `showstopper`  | red        | blocks downstream work                 |
| `habitual`     | blue       | informational, recurring               |
| `ridiculous`   | pink       | from the legacy SPSE2 enum             |
| *others*       | gray       | neutral                                |

Critical-path nodes get a 2.5px purple border and critical-path edges
are drawn thicker in the same purple. This reads cleanly in both
light and dark mode.

## Dependencies

Loaded from jsdelivr CDN:

- `cytoscape@3.30.4`
- `dagre@0.8.5`
- `cytoscape-dagre@2.5.0`

No build pipeline, no npm, no bundler. Pin these to whatever versions
your site policy requires; the code doesn't use any API that's changed
in cytoscape 3.x.

## License

MIT. See the top-level SPSE4 LICENSE.
