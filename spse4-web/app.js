/*  SPSE4 web client — single-page app.
    Part of FRKCSA / SPSE4.  GPLv3 License.

    Architecture:
      - API module: talks to /health, /projection, /events
      - State: one mutable object with current mt, filters, selection
      - Graph: Cytoscape + dagre, hover/click handlers, 1-hop highlight
      - Filters: chip toggles for status & relation, critical-path toggle
      - Panel: task detail rendering, edge lists, actions
      - Poll: fetch /events and repaint on change
*/

(function () {
  'use strict';

  // ============================================================
  // State
  // ============================================================

  const State = {
    baseUrl: window.location.origin,
    auth: null,            // {user, password} or null
    mt: 'autopackager',    // current microtheory
    selectedId: null,
    goalId: null,          // restrict to connected component of this goal
    showCP: true,          // critical-path overlay on
    statusFilters: new Set(),   // empty = all
    relationFilters: new Set(), // empty = all
    lastEventTime: 0,
    pollTimer: null,
    lastSnapshot: null,    // last projection data
  };

  // ============================================================
  // API
  // ============================================================

  const API = {
    async get(path) {
      const headers = {};
      if (State.auth) {
        const b = btoa(State.auth.user + ':' + State.auth.password);
        headers['Authorization'] = 'Basic ' + b;
      }
      const res = await fetch(State.baseUrl + path, { headers });
      if (!res.ok) {
        const body = await res.text().catch(() => '');
        throw new Error(`HTTP ${res.status} ${res.statusText} for ${path}: ${body.slice(0, 200)}`);
      }
      return res.json();
    },

    health() { return this.get('/health'); },

    projection(mt, opts = {}) {
      const qs = new URLSearchParams();
      qs.set('mt', mt);
      if (State.showCP) qs.set('critical_path', '1');
      if (State.goalId) qs.set('goal', State.goalId);
      for (const s of State.statusFilters) qs.append('status', s);
      for (const r of State.relationFilters) qs.append('relation', r);
      return this.get('/projection?' + qs.toString());
    },

    events(since) {
      const qs = since > 0 ? `?since=${since}` : '';
      return this.get('/events' + qs);
    },

    async createTask({ mt, id, label, status, props }) {
      const headers = { 'Content-Type': 'application/json' };
      if (State.auth) {
        const b = btoa(State.auth.user + ':' + State.auth.password);
        headers['Authorization'] = 'Basic ' + b;
      }
      const body = { mt, id, label, status };
      if (props && Object.keys(props).length > 0) body.props = props;
      const res = await fetch(State.baseUrl + '/tasks', {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
      });
      const text = await res.text();
      let parsed = null;
      try { parsed = text ? JSON.parse(text) : null; } catch (_) { /* ignore */ }
      if (!res.ok) {
        const msg = (parsed && parsed.message) || `HTTP ${res.status}`;
        const err = new Error(msg);
        err.status = res.status;
        throw err;
      }
      return parsed;
    },

    async deleteTask(mt, id) {
      const headers = {};
      if (State.auth) {
        const b = btoa(State.auth.user + ':' + State.auth.password);
        headers['Authorization'] = 'Basic ' + b;
      }
      const url = `${State.baseUrl}/tasks/${encodeURIComponent(mt)}/${encodeURIComponent(id)}`;
      const res = await fetch(url, { method: 'DELETE', headers });
      const text = await res.text();
      let parsed = null;
      try { parsed = text ? JSON.parse(text) : null; } catch (_) { /* ignore */ }
      if (!res.ok) {
        const msg = (parsed && parsed.message) || `HTTP ${res.status}`;
        const err = new Error(msg);
        err.status = res.status;
        throw err;
      }
      return parsed;
    },

    async updateTaskStatus(mt, id, newStatus) {
      const headers = { 'Content-Type': 'application/json' };
      if (State.auth) {
        const b = btoa(State.auth.user + ':' + State.auth.password);
        headers['Authorization'] = 'Basic ' + b;
      }
      const url = `${State.baseUrl}/tasks/${encodeURIComponent(mt)}/${encodeURIComponent(id)}`;
      const res = await fetch(url, {
        method: 'PATCH',
        headers,
        body: JSON.stringify({ status: newStatus }),
      });
      const text = await res.text();
      let parsed = null;
      try { parsed = text ? JSON.parse(text) : null; } catch (_) { /* ignore */ }
      if (!res.ok) {
        const msg = (parsed && parsed.message) || `HTTP ${res.status}`;
        const err = new Error(msg);
        err.status = res.status;
        throw err;
      }
      return parsed;
    },

    async createEdge({ mt, from, kind, to, props }) {
      const headers = { 'Content-Type': 'application/json' };
      if (State.auth) {
        const b = btoa(State.auth.user + ':' + State.auth.password);
        headers['Authorization'] = 'Basic ' + b;
      }
      const body = { mt, from, kind, to };
      if (props && Object.keys(props).length > 0) body.props = props;
      const res = await fetch(State.baseUrl + '/edges', {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
      });
      const text = await res.text();
      let parsed = null;
      try { parsed = text ? JSON.parse(text) : null; } catch (_) { /* ignore */ }
      if (!res.ok) {
        const msg = (parsed && parsed.message) || `HTTP ${res.status}`;
        const err = new Error(msg);
        err.status = res.status;
        throw err;
      }
      return parsed;
    },

    async deleteEdge(mt, from, kind, to) {
      const headers = {};
      if (State.auth) {
        const b = btoa(State.auth.user + ':' + State.auth.password);
        headers['Authorization'] = 'Basic ' + b;
      }
      const url = `${State.baseUrl}/edges/${encodeURIComponent(mt)}/${encodeURIComponent(from)}/${encodeURIComponent(kind)}/${encodeURIComponent(to)}`;
      const res = await fetch(url, { method: 'DELETE', headers });
      const text = await res.text();
      let parsed = null;
      try { parsed = text ? JSON.parse(text) : null; } catch (_) { /* ignore */ }
      if (!res.ok) {
        const msg = (parsed && parsed.message) || `HTTP ${res.status}`;
        const err = new Error(msg);
        err.status = res.status;
        throw err;
      }
      return parsed;
    },

    async updateEdgeProps(mt, from, kind, to, props) {
      const headers = { 'Content-Type': 'application/json' };
      if (State.auth) {
        const b = btoa(State.auth.user + ':' + State.auth.password);
        headers['Authorization'] = 'Basic ' + b;
      }
      const url = `${State.baseUrl}/edges/${encodeURIComponent(mt)}/${encodeURIComponent(from)}/${encodeURIComponent(kind)}/${encodeURIComponent(to)}`;
      const body = { props: props || {} };
      const res = await fetch(url, {
        method: 'PATCH',
        headers,
        body: JSON.stringify(body),
      });
      const text = await res.text();
      let parsed = null;
      try { parsed = text ? JSON.parse(text) : null; } catch (_) { /* ignore */ }
      if (!res.ok) {
        const msg = (parsed && parsed.message) || `HTTP ${res.status}`;
        const err = new Error(msg);
        err.status = res.status;
        throw err;
      }
      return parsed;
    },
  };

  // ============================================================
  // Graph (Cytoscape)
  // ============================================================

  let cy = null;

  function cytoscapeStyles() {
    const cssVar = (name) => {
      return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
    };
    return [
      {
        selector: 'node',
        style: {
          'shape': 'round-rectangle',
          'label': 'data(id)',
          'text-valign': 'center',
          'text-halign': 'center',
          'font-family': 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
          'font-size': 11,
          'font-weight': 500,
          'width': 'label',
          'height': 28,
          'padding': '8px',
          'border-width': 1,
          'text-wrap': 'none',
          'text-max-width': 200,
          'background-color': cssVar('--s-open-bg') || '#f1efe8',
          'border-color': cssVar('--s-open-br') || '#888780',
          'color': cssVar('--s-open-fg') || '#444441',
          'transition-property': 'opacity, border-width, border-color, background-color',
          'transition-duration': 120,
        },
      },

      // Status-specific node styling
      ...(['completed','in_progress','open','cancelled','deleted','showstopper','obsoleted','habitual','skipped','rejected','ridiculous']
        .map(s => ({
          selector: `node[status = "${s}"]`,
          style: {
            'background-color': cssVar(`--s-${s}-bg`),
            'border-color':     cssVar(`--s-${s}-br`),
            'color':            cssVar(`--s-${s}-fg`),
          },
        }))),

      // Critical-path nodes
      {
        selector: 'node[?critical]',
        style: {
          'border-width': 2.5,
          'border-color': cssVar('--crit-br') || '#7f77dd',
        },
      },

      // Selected node
      {
        selector: 'node:selected',
        style: {
          'border-width': 3,
          'border-color': cssVar('--crit-br') || '#7f77dd',
          'background-color': cssVar('--crit-bg') || '#eeedfe',
          'color': cssVar('--crit-fg') || '#26215c',
        },
      },

      // Dimmed nodes (during hover highlight)
      {
        selector: 'node.dim',
        style: { 'opacity': 0.3 },
      },

      // Edges
      {
        selector: 'edge',
        style: {
          'curve-style': 'bezier',
          'width': 1.2,
          'line-color': cssVar('--edge-default') || '#b4b2a9',
          'target-arrow-shape': 'triangle',
          'target-arrow-color': cssVar('--edge-default') || '#b4b2a9',
          'target-arrow-fill': 'filled',
          'arrow-scale': 0.9,
          'transition-property': 'opacity, width, line-color, target-arrow-color',
          'transition-duration': 120,
        },
      },
      {
        selector: 'edge[kind = "depends"]',
        style: { 'line-style': 'solid' },
      },
      {
        selector: 'edge[kind = "provides"]',
        style: { 'line-color': '#378add', 'target-arrow-color': '#378add' },
      },
      {
        selector: 'edge[kind = "attacks"]',
        style: { 'line-color': '#e24b4a', 'target-arrow-color': '#e24b4a', 'line-style': 'dashed' },
      },
      {
        selector: 'edge[kind = "supports"]',
        style: { 'line-color': '#97c459', 'target-arrow-color': '#97c459' },
      },
      {
        selector: 'edge[kind = "eases"]',
        style: { 'line-color': '#b4b2a9', 'target-arrow-color': '#b4b2a9', 'line-style': 'dotted' },
      },

      // Critical-path edges
      {
        selector: 'edge.critical',
        style: {
          'width': 2.2,
          'line-color': cssVar('--edge-crit') || '#7f77dd',
          'target-arrow-color': cssVar('--edge-crit') || '#7f77dd',
        },
      },

      // Dimmed edges
      {
        selector: 'edge.dim',
        style: { 'opacity': 0.18 },
      },

      // Highlight on hover for 1-hop neighborhood
      {
        selector: 'node.focus',
        style: {
          'border-width': 3,
          'z-index': 99,
        },
      },
      {
        selector: 'edge.focus',
        style: {
          'width': 2.2,
          'z-index': 98,
        },
      },
    ];
  }

  function initCytoscape() {
    if (typeof cytoscape === 'undefined') return;
    if (typeof cytoscapeDagre !== 'undefined') cytoscape.use(cytoscapeDagre);

    cy = cytoscape({
      container: document.getElementById('cy'),
      elements: [],
      style: cytoscapeStyles(),
      layout: { name: 'dagre' },
      minZoom: 0.3,
      maxZoom: 2.5,
      wheelSensitivity: 0.2,
    });

    // Click selects
    cy.on('tap', 'node', (evt) => {
      const id = evt.target.id();
      State.selectedId = id;
      renderPanel();
    });

    // Tap on blank deselects
    cy.on('tap', (evt) => {
      if (evt.target === cy) {
        State.selectedId = null;
        renderPanel();
      }
    });

    // Double-click to center
    cy.on('dblclick', 'node', (evt) => {
      cy.animate({ center: { eles: evt.target }, zoom: 1.2, duration: 220 });
    });

    // Hover tooltips + 1-hop highlight
    cy.on('mouseover', 'node', (evt) => {
      const n = evt.target;
      showNodeTooltip(n);
      highlightNeighborhood(n);
    });
    cy.on('mouseout', 'node', () => {
      hideTooltip();
      clearHighlight();
    });
    cy.on('mouseover', 'edge', (evt) => {
      showEdgeTooltip(evt.target);
    });
    cy.on('mouseout', 'edge', hideTooltip);

    cy.on('mousemove', (evt) => {
      // Reposition the tooltip to follow cursor
      const tip = document.getElementById('tooltip');
      if (tip.style.display !== 'none') {
        const pt = evt.renderedPosition || evt.position;
        moveTooltipTo(pt);
      }
    });
  }

  function highlightNeighborhood(n) {
    const hood = n.closedNeighborhood();
    cy.nodes().not(hood.nodes()).addClass('dim');
    cy.edges().not(hood.edges()).addClass('dim');
    hood.addClass('focus');
  }

  function clearHighlight() {
    cy.elements().removeClass('dim focus');
  }

  function showNodeTooltip(n) {
    const d = n.data();
    const rows = [];
    const dur = readProp(d.props, 'duration');
    if (dur) rows.push({ k: 'duration', v: formatDuration(dur) });
    const es = readProp(d.props, 'earliest_start');
    if (es) rows.push({ k: 'earliest start', v: String(es) });
    const lf = readProp(d.props, 'latest_finish');
    if (lf) rows.push({ k: 'latest finish', v: String(lf) });
    const kind = readProp(d.props, 'task_kind');
    if (kind) rows.push({ k: 'kind', v: String(kind) });
    const needs = readPropAll(d.props, 'needs_resource');
    if (needs.length) rows.push({ k: 'resources', v: needs.join(', ') });

    const tip = document.getElementById('tooltip');
    tip.innerHTML = `
      <div class="tooltip-id">${escapeHtml(d.id)}</div>
      <div style="color: var(--fg-1); margin-bottom: 6px;">${escapeHtml(d.label || '')}</div>
      ${rows.map(r => `<div class="tooltip-row"><span class="k">${r.k}</span><span class="v">${escapeHtml(String(r.v))}</span></div>`).join('')}
      ${d.critical ? `<div class="tooltip-row"><span class="k">critical</span><span class="v" style="color: var(--crit-br)">yes</span></div>` : ''}
    `;
    tip.style.display = 'block';
    const pos = n.renderedPosition();
    moveTooltipTo({ x: pos.x, y: pos.y });
  }

  function showEdgeTooltip(e) {
    const d = e.data();
    const rows = Object.entries(d.props || {})
      .filter(([k]) => k !== undefined)
      .slice(0, 5)
      .map(([k, v]) => `<div class="tooltip-row"><span class="k">${escapeHtml(k)}</span><span class="v">${escapeHtml(String(v))}</span></div>`)
      .join('');
    const tip = document.getElementById('tooltip');
    tip.innerHTML = `
      <div class="tooltip-id">${escapeHtml(d.source)} → ${escapeHtml(d.target)}</div>
      <div class="tooltip-row"><span class="k">relation</span><span class="v">${escapeHtml(d.kind)}</span></div>
      ${rows}
    `;
    tip.style.display = 'block';
    const mid = e.midpoint();
    // cy.midpoint is model coords; convert to rendered
    const rp = { x: (e.source().renderedPosition().x + e.target().renderedPosition().x) / 2,
                 y: (e.source().renderedPosition().y + e.target().renderedPosition().y) / 2 };
    moveTooltipTo(rp);
  }

  function moveTooltipTo(rpt) {
    const tip = document.getElementById('tooltip');
    const container = document.getElementById('cy');
    const cw = container.clientWidth, ch = container.clientHeight;
    const tw = tip.offsetWidth, th = tip.offsetHeight;
    let x = rpt.x + 14;
    let y = rpt.y + 14;
    if (x + tw > cw - 8) x = rpt.x - tw - 14;
    if (y + th > ch - 8) y = rpt.y - th - 14;
    if (x < 8) x = 8;
    if (y < 8) y = 8;
    tip.style.left = x + 'px';
    tip.style.top = y + 'px';
  }

  function hideTooltip() {
    document.getElementById('tooltip').style.display = 'none';
  }

  // ============================================================
  // Render
  // ============================================================

  function render(snapshot) {
    State.lastSnapshot = snapshot;
    const els = snapshot.elements || { nodes: [], edges: [] };

    document.getElementById('empty-hint').style.display =
      (els.nodes.length === 0) ? 'flex' : 'none';

    // Mark critical-path edges (both endpoints are critical nodes)
    const critSet = new Set(els.nodes.filter(n => n.data.critical).map(n => n.data.id));
    const edgesWithCrit = els.edges.map(e => ({
      ...e,
      classes: (critSet.has(e.data.source) && critSet.has(e.data.target)) ? 'critical' : '',
    }));

    cy.elements().remove();
    cy.add(els.nodes);
    cy.add(edgesWithCrit);
    cy.layout({
      name: 'dagre',
      rankDir: 'LR',
      nodeSep: 40,
      rankSep: 80,
      animate: false,
    }).run();

    cy.fit(null, 30);

    // Stats
    const critCount = Array.from(critSet).length;
    document.getElementById('s-tasks').textContent = `${els.nodes.length} tasks`;
    document.getElementById('s-edges').textContent = `${els.edges.length} edges`;
    document.getElementById('s-crit').textContent = critCount
      ? `critical path: ${critCount} nodes`
      : 'critical path: —';

    renderFilterChips(snapshot);
    renderPanel();
  }

  function renderFilterChips(snapshot) {
    const nodes = (snapshot.elements || {}).nodes || [];
    const edges = (snapshot.elements || {}).edges || [];

    const statusCounts = {};
    for (const n of nodes) {
      const s = n.data.status || 'open';
      statusCounts[s] = (statusCounts[s] || 0) + 1;
    }

    const relationCounts = {};
    for (const e of edges) {
      const k = e.data.kind || 'depends';
      relationCounts[k] = (relationCounts[k] || 0) + 1;
    }

    const statusEl = document.getElementById('status-chips');
    statusEl.innerHTML = Object.entries(statusCounts)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([s, n]) => {
        const active = State.statusFilters.has(s);
        const inactive = State.statusFilters.size > 0 && !active;
        return `<span class="chip status-${s} ${inactive ? 'inactive' : ''}" data-status="${s}">
          ${s} <span class="chip-count">${n}</span>
        </span>`;
      }).join('');

    statusEl.querySelectorAll('.chip').forEach(chip => {
      chip.addEventListener('click', () => {
        const s = chip.dataset.status;
        if (State.statusFilters.has(s)) State.statusFilters.delete(s);
        else State.statusFilters.add(s);
        refresh();
      });
    });

    const relEl = document.getElementById('relation-chips');
    relEl.innerHTML = Object.entries(relationCounts)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([k, n]) => {
        const active = State.relationFilters.has(k);
        const inactive = State.relationFilters.size > 0 && !active;
        return `<span class="chip ${inactive ? 'inactive' : ''}" data-rel="${k}">
          ${k} <span class="chip-count">${n}</span>
        </span>`;
      }).join('');

    relEl.querySelectorAll('.chip').forEach(chip => {
      chip.addEventListener('click', () => {
        const k = chip.dataset.rel;
        if (State.relationFilters.has(k)) State.relationFilters.delete(k);
        else State.relationFilters.add(k);
        refresh();
      });
    });
  }

  function renderPanel() {
    // If a status-edit is currently mounted in the panel, don't
    // clobber its dropdown with a re-render.  The edit's finish
    // handler will trigger renderPanel itself when done.
    if (_statusEditing) return;

    const body = document.getElementById('detail-body');
    const empty = document.getElementById('detail-empty');

    if (!State.selectedId || !State.lastSnapshot) {
      body.style.display = 'none';
      empty.style.display = 'block';
      return;
    }

    const nodes = (State.lastSnapshot.elements || {}).nodes || [];
    const edges = (State.lastSnapshot.elements || {}).edges || [];
    const node = nodes.find(n => n.data.id === State.selectedId);
    if (!node) {
      body.style.display = 'none';
      empty.style.display = 'block';
      return;
    }

    empty.style.display = 'none';
    body.style.display = 'block';

    const d = node.data;
    document.getElementById('d-id').textContent = d.id;
    const pill = document.getElementById('d-status');
    pill.textContent = d.status;
    pill.className = 'status-pill status-' + d.status + ' clickable';
    pill.title = 'Click to change status';
    pill.onclick = () => beginStatusEdit(d.id, d.status);
    document.getElementById('d-label').textContent = d.label || '';

    // Meta
    const metaEl = document.getElementById('d-meta');
    const rows = [];
    const kind = readProp(d.props, 'task_kind');
    if (kind) rows.push({ k: 'kind', v: kind });
    const dur = readProp(d.props, 'duration');
    if (dur) rows.push({ k: 'duration', v: formatDuration(dur) });
    const es = readProp(d.props, 'earliest_start');
    if (es) rows.push({ k: 'earliest start', v: es });
    const lf = readProp(d.props, 'latest_finish');
    if (lf) rows.push({ k: 'latest finish', v: lf });

    // Structural: outgoing depends = "depends on", incoming = "dependents"
    // (kept for the meta summary block).
    const outDeps = edges.filter(e => e.data.source === d.id && e.data.kind === 'depends');
    const inDeps  = edges.filter(e => e.data.target === d.id && e.data.kind === 'depends');
    const blockers = outDeps.filter(e => {
      const tgt = nodes.find(n => n.data.id === e.data.target);
      return tgt && tgt.data.status !== 'completed';
    });

    // All incident edges (any kind) for the new outgoing/incoming
    // sections that support per-row edit/delete.
    const outAll = edges.filter(e => e.data.source === d.id);
    const inAll  = edges.filter(e => e.data.target === d.id);

    rows.push({ k: 'dependencies', v: String(outDeps.length) });
    rows.push({ k: 'dependents',   v: String(inDeps.length) });
    if (blockers.length > 0) rows.push({ k: 'blockers', v: String(blockers.length), cls: 'warn' });
    if (d.critical) rows.push({ k: 'critical path', v: 'yes', cls: 'crit' });

    metaEl.innerHTML = rows.map(r =>
      `<div class="meta-row"><span class="k">${r.k}</span><span class="v ${r.cls || ''}">${escapeHtml(String(r.v))}</span></div>`
    ).join('');

    // Blocking
    const blSec = document.getElementById('d-blocking-section');
    if (blockers.length > 0) {
      blSec.style.display = 'block';
      document.getElementById('d-blockers').innerHTML = blockers.map(e => {
        const tgt = nodes.find(n => n.data.id === e.data.target);
        const status = tgt ? tgt.data.status : '?';
        return `<div class="blocker-item" data-id="${e.data.target}">
          <span class="bl-id">${escapeHtml(e.data.target)}</span>
          <span class="bl-status">${escapeHtml(status)}</span>
        </div>`;
      }).join('');
    } else {
      blSec.style.display = 'none';
    }

    // Outgoing edges (any kind): row shows kind + target id + status,
    // plus edit/delete buttons.  Click the row body to navigate to target.
    const depsSec = document.getElementById('d-deps-section');
    if (outAll.length > 0) {
      depsSec.style.display = 'block';
      document.getElementById('d-deps').innerHTML = outAll.map(e => {
        const tgt = nodes.find(n => n.data.id === e.data.target);
        const status = tgt ? tgt.data.status : '?';
        return renderEdgeRow_({
          fromId: d.id, toId: e.data.target, kind: e.data.kind,
          otherId: e.data.target, otherStatus: status, props: e.data.props || {},
          direction: 'out',
        });
      }).join('');
    } else {
      depsSec.style.display = 'none';
    }

    // Incoming edges (any kind).
    const depsBySec = document.getElementById('d-dependents-section');
    if (inAll.length > 0) {
      depsBySec.style.display = 'block';
      document.getElementById('d-dependents').innerHTML = inAll.map(e => {
        const src = nodes.find(n => n.data.id === e.data.source);
        const status = src ? src.data.status : '?';
        return renderEdgeRow_({
          fromId: e.data.source, toId: d.id, kind: e.data.kind,
          otherId: e.data.source, otherStatus: status, props: e.data.props || {},
          direction: 'in',
        });
      }).join('');
    } else {
      depsBySec.style.display = 'none';
    }

    // Wire row clicks (navigation) and per-row buttons (edit/delete).
    document.querySelectorAll('.blocker-item').forEach(el => {
      el.addEventListener('click', () => {
        State.selectedId = el.dataset.id;
        renderPanel();
        const target = cy.getElementById(State.selectedId);
        if (target.length) {
          cy.animate({ center: { eles: target }, zoom: cy.zoom(), duration: 180 });
          target.select();
        }
      });
    });
    document.querySelectorAll('.edge-row').forEach(el => {
      const body = el.querySelector('.edge-row-body');
      if (body) {
        body.addEventListener('click', () => {
          State.selectedId = el.dataset.other;
          renderPanel();
          const target = cy.getElementById(State.selectedId);
          if (target.length) {
            cy.animate({ center: { eles: target }, zoom: cy.zoom(), duration: 180 });
            target.select();
          }
        });
      }
      const delBtn = el.querySelector('.edge-row-del');
      if (delBtn) {
        delBtn.addEventListener('click', (ev) => {
          ev.stopPropagation();
          deleteEdgeFromRow(el);
        });
      }
      const editBtn = el.querySelector('.edge-row-edit');
      if (editBtn) {
        editBtn.addEventListener('click', (ev) => {
          ev.stopPropagation();
          openEdgePropsEditor(el);
        });
      }
    });

    // Action buttons
    document.querySelectorAll('.act').forEach(btn => {
      btn.onclick = () => {
        const act = btn.dataset.act;
        const el = cy.getElementById(State.selectedId);
        if (act === 'center' && el.length) {
          cy.animate({ center: { eles: el }, zoom: 1.3, duration: 220 });
        } else if (act === 'focus' && el.length) {
          State.goalId = State.selectedId;
          updateGoalChip();
          refresh();
        } else if (act === 'setgoal' && State.selectedId) {
          State.goalId = State.selectedId;
          updateGoalChip();
          refresh();
        } else if (act === 'delete' && State.selectedId) {
          deleteSelectedTask();
        }
      };
    });
  }

  // ============================================================
  // Mutation: inline status edit on the side-panel pill
  // ============================================================

  // The full vocabulary the core's validate_property_/2 accepts for status:
  const STATUS_VALUES = [
    'open', 'in_progress', 'completed', 'cancelled',
    'deleted', 'skipped', 'obsoleted', 'rejected',
    'showstopper', 'ridiculous', 'habitual',
  ];

  // Track per-render edit lock so we can prevent re-render-while-editing
  let _statusEditing = false;

  function beginStatusEdit(taskId, currentStatus) {
    if (_statusEditing) return;
    _statusEditing = true;

    const pill = document.getElementById('d-status');
    if (!pill) { _statusEditing = false; return; }

    // Replace the pill's content with an inline <select>.  We keep the
    // pill element itself so its position in the layout is preserved;
    // we just swap the children.
    pill.innerHTML = '';
    pill.classList.remove('clickable');
    pill.classList.add('editing');
    pill.title = '';
    pill.onclick = null;

    const sel = document.createElement('select');
    sel.className = 'status-select';
    for (const s of STATUS_VALUES) {
      const opt = document.createElement('option');
      opt.value = s;
      opt.textContent = s;
      if (s === currentStatus) opt.selected = true;
      sel.appendChild(opt);
    }
    pill.appendChild(sel);
    sel.focus();

    let committed = false;

    const finish = async (commit) => {
      if (committed) return;
      committed = true;
      const newStatus = sel.value;
      _statusEditing = false;

      if (!commit || newStatus === currentStatus) {
        // Restore display without round-tripping the server.
        renderPanel();
        return;
      }

      // Optimistic UI: show the new status immediately.
      pill.textContent = newStatus;
      pill.className = 'status-pill status-' + newStatus;

      try {
        await API.updateTaskStatus(State.mt, taskId, newStatus);
        // Refresh to pull authoritative state and re-trigger CP recalc.
        await refresh();
        renderPanel();
      } catch (e) {
        // Roll back optimistic UI.
        let msg = e.message || String(e);
        if (e.status === 401) msg = 'Authentication required. Pass ?u=USER&p=PASS in the URL.';
        else if (e.status === 403) msg = `Forbidden: you don't have write access to "${State.mt}".`;
        else if (e.status === 404) msg = `Task "${taskId}" not found.`;
        alert(`Status change failed: ${msg}`);
        renderPanel();
      }
    };

    sel.addEventListener('change', () => finish(true));
    sel.addEventListener('blur', () => finish(true));
    sel.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        finish(false);
      } else if (e.key === 'Enter') {
        e.preventDefault();
        finish(true);
      }
    });
  }

  // ============================================================
  // Mutation: delete the currently-selected task
  // ============================================================

  async function deleteSelectedTask() {
    const id = State.selectedId;
    if (!id) return;
    if (!confirm(`Delete task "${id}"?\n\nThis also removes all edges incident to it. Cannot be undone.`)) {
      return;
    }
    try {
      await API.deleteTask(State.mt, id);
      State.selectedId = null;
      await refresh();
      renderPanel();
    } catch (e) {
      alert(`Delete failed: ${e.message || e}`);
    }
  }

  // ============================================================
  // Mutation: edge CRUD via side-panel rows (added v0.2.2)
  // ============================================================

  // Render one row of the outgoing/incoming edge list.  The row body
  // (kind badge + other endpoint id + status) is the navigation target;
  // the action buttons live in their own column so clicks on them don't
  // bubble into navigation.
  function renderEdgeRow_(opts) {
    const { fromId, toId, kind, otherId, otherStatus, props, direction } = opts;
    const propStr = encodeURIComponent(JSON.stringify(props || {}));
    return `<div class="edge-row" data-from="${escapeHtml(fromId)}" data-to="${escapeHtml(toId)}" data-kind="${escapeHtml(kind)}" data-other="${escapeHtml(otherId)}" data-direction="${direction}" data-props="${propStr}">
      <div class="edge-row-body">
        <span class="edge-kind kind-${escapeHtml(kind)}">${escapeHtml(kind)}</span>
        <span class="e-id">${escapeHtml(otherId)}</span>
        <span class="e-status">${escapeHtml(otherStatus)}</span>
      </div>
      <div class="edge-row-actions">
        <button class="edge-row-edit" title="Edit props">✎</button>
        <button class="edge-row-del" title="Delete edge">✕</button>
      </div>
    </div>`;
  }

  async function deleteEdgeFromRow(rowEl) {
    const from = rowEl.dataset.from;
    const to = rowEl.dataset.to;
    const kind = rowEl.dataset.kind;
    if (!from || !to || !kind) return;
    if (!confirm(`Delete edge ${from} —[${kind}]→ ${to}?\n\nCannot be undone.`)) {
      return;
    }
    try {
      await API.deleteEdge(State.mt, from, kind, to);
      await refresh();
      renderPanel();
    } catch (e) {
      let msg = e.message || String(e);
      if (e.status === 401) msg = 'Authentication required. Pass ?u=USER&p=PASS in the URL.';
      else if (e.status === 403) msg = `Forbidden: you don't have write access to "${State.mt}".`;
      else if (e.status === 404) msg = `Edge not found.`;
      alert(`Delete failed: ${msg}`);
    }
  }

  function openEdgePropsEditor(rowEl) {
    const from = rowEl.dataset.from;
    const to = rowEl.dataset.to;
    const kind = rowEl.dataset.kind;
    let props = {};
    try {
      props = JSON.parse(decodeURIComponent(rowEl.dataset.props || '{}'));
    } catch (_) { /* ignore malformed payload, start empty */ }
    EdgeModal.openForEdit({ from, to, kind, props });
  }

  // Parse a key:value-per-line textarea body into a flat props object.
  // Numeric-looking values become Number; everything else stays as a string.
  // Lines without a colon, or with empty keys, are skipped silently.
  function parseEdgePropsText(text) {
    const out = {};
    const lines = String(text || '').split(/\r?\n/);
    for (const raw of lines) {
      const line = raw.trim();
      if (!line) continue;
      const idx = line.indexOf(':');
      if (idx < 0) continue;
      const k = line.slice(0, idx).trim();
      const vRaw = line.slice(idx + 1).trim();
      if (!k) continue;
      let v = vRaw;
      if (vRaw !== '' && !isNaN(Number(vRaw)) && /^-?[0-9]+(\.[0-9]+)?$/.test(vRaw)) {
        v = Number(vRaw);
      }
      out[k] = v;
    }
    return out;
  }

  function formatEdgePropsText(props) {
    if (!props) return '';
    return Object.entries(props).map(([k, v]) => `${k}: ${v}`).join('\n');
  }

  function updateGoalChip() {
    const lbl = document.getElementById('goal-label');
    if (State.goalId) {
      lbl.style.display = 'inline-flex';
      document.getElementById('goal-name').textContent = State.goalId;
    } else {
      lbl.style.display = 'none';
    }
  }

  // ============================================================
  // Helpers
  // ============================================================

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function readProp(props, key) {
    if (!props) return null;
    if (Array.isArray(props)) {
      const found = props.find(([k]) => k === key);
      return found ? found[1] : null;
    }
    // Dict shape
    return props[key] !== undefined ? props[key] : null;
  }

  function readPropAll(props, key) {
    if (!props) return [];
    if (Array.isArray(props)) {
      return props.filter(([k]) => k === key).map(([, v]) => v);
    }
    return props[key] !== undefined ? [props[key]] : [];
  }

  function formatDuration(d) {
    // d may be "fixed(N)" or a number of seconds or a string
    if (typeof d === 'number') return humanSeconds(d);
    if (typeof d === 'string') {
      const m = /^fixed\(([0-9.]+)\)$/.exec(d);
      if (m) return humanSeconds(parseFloat(m[1]));
      return d;
    }
    return JSON.stringify(d);
  }

  function humanSeconds(sec) {
    if (sec < 60) return `${sec}s`;
    if (sec < 3600) return `${Math.round(sec / 60)}m`;
    if (sec < 86400) return `${Math.round(sec / 3600)}h`;
    return `${(sec / 86400).toFixed(1)}d`;
  }

  // ============================================================
  // Main flows
  // ============================================================

  async function refresh() {
    const btn = document.getElementById('refresh-btn');
    btn.classList.add('spinning');
    try {
      const snapshot = await API.projection(State.mt);
      render(snapshot);
      setConnected(true, 'connected');
    } catch (e) {
      console.error(e);
      setConnected(false, `error: ${e.message.slice(0, 60)}`);
    } finally {
      setTimeout(() => btn.classList.remove('spinning'), 200);
    }
  }

  async function checkHealth() {
    try {
      const h = await API.health();
      document.getElementById('server-version').textContent = 'v' + (h.version || '?');
      setConnected(true, 'connected');
    } catch (e) {
      setConnected(false, 'offline');
    }
  }

  function setConnected(ok, label) {
    const dot = document.getElementById('conn-dot');
    dot.className = 'conn-dot ' + (ok ? 'ok' : 'err');
    document.getElementById('conn-label').textContent = label;
  }

  async function pollEvents() {
    try {
      const result = await API.events(State.lastEventTime);
      State.lastEventTime = result.now || State.lastEventTime;
      if (result.events && result.events.length > 0) {
        document.getElementById('s-last-event').textContent =
          `last event: ${result.events.length} new`;
        // Any event in our mt invalidates our snapshot; refresh
        const ourEvents = result.events.filter(e => e.event && e.event.includes(State.mt));
        if (ourEvents.length > 0) await refresh();
      }
    } catch (e) {
      // events endpoint may not be reachable in strict mode without auth; that's fine
    }
  }

  // ============================================================
  // New-task modal
  // ============================================================

  const NewTaskModal = {
    isOpen() {
      const bd = document.getElementById('modal-backdrop');
      return bd && bd.style.display !== 'none';
    },

    open() {
      const bd = document.getElementById('modal-backdrop');
      if (!bd) return;
      // Prefill microtheory with current state
      document.getElementById('f-mt').value = State.mt;
      document.getElementById('f-id').value = '';
      document.getElementById('f-label').value = '';
      document.getElementById('f-status').value = 'open';
      const err = document.getElementById('f-error');
      err.style.display = 'none';
      err.textContent = '';
      bd.style.display = 'flex';
      // Focus the ID field after the animation begins
      setTimeout(() => document.getElementById('f-id').focus(), 50);
    },

    close() {
      const bd = document.getElementById('modal-backdrop');
      if (bd) bd.style.display = 'none';
    },

    showError(msg) {
      const err = document.getElementById('f-error');
      err.textContent = msg;
      err.style.display = 'block';
    },

    validate() {
      const id = document.getElementById('f-id').value.trim();
      const label = document.getElementById('f-label').value.trim();
      const mt = document.getElementById('f-mt').value.trim();
      const status = document.getElementById('f-status').value;

      if (!id) return { ok: false, msg: 'ID is required.' };
      if (!/^[a-z][a-z0-9_]*$/.test(id)) {
        return { ok: false, msg: 'ID must start with a lowercase letter and contain only lowercase letters, digits, and underscores.' };
      }
      if (!label) return { ok: false, msg: 'Label is required.' };
      if (!mt) return { ok: false, msg: 'Microtheory is required.' };

      return { ok: true, payload: { id, label, mt, status } };
    },

    async submit() {
      const v = this.validate();
      if (!v.ok) { this.showError(v.msg); return; }

      const submitBtn = document.getElementById('modal-submit');
      submitBtn.disabled = true;
      submitBtn.textContent = 'Adding…';

      try {
        await API.createTask(v.payload);
        this.close();
        // The newly created task lives in the just-named mt; switch to
        // it if the form's mt differs from the current view, so the
        // user actually sees what they just added.
        if (v.payload.mt !== State.mt) {
          State.mt = v.payload.mt;
          const sel = document.getElementById('mt-select');
          if (sel && sel.value !== State.mt) {
            // Add the option dynamically if it isn't there yet
            if (!Array.from(sel.options).some(o => o.value === State.mt)) {
              const opt = document.createElement('option');
              opt.value = State.mt;
              opt.textContent = State.mt;
              sel.appendChild(opt);
            }
            sel.value = State.mt;
          }
        }
        await refresh();
        // Select the new task so the user immediately sees it in the panel
        State.selectedId = v.payload.id;
        renderPanel();
        const target = cy.getElementById(v.payload.id);
        if (target.length) {
          cy.animate({ center: { eles: target }, zoom: 1.3, duration: 220 });
          target.select();
        }
      } catch (e) {
        let msg = e.message || String(e);
        if (e.status === 401) msg = 'Authentication required. Pass ?u=USER&p=PASS in the URL.';
        else if (e.status === 403) msg = `Forbidden: you don't have write access to "${v.payload.mt}".`;
        this.showError(msg);
      } finally {
        submitBtn.disabled = false;
        submitBtn.textContent = 'Add task';
      }
    },
  };

  // ============================================================
  // Edge modal (create new edge OR edit existing edge's props)
  // ============================================================

  // Edge kinds that the core's valid_edge_kind/1 accepts.
  const EDGE_KINDS = [
    'depends', 'provides', 'eases', 'allen',
    'attacks', 'supports', 'contingent_on', 'subsumes', 'prefer',
  ];

  const EdgeModal = {
    // mode is 'create' or 'edit'
    _mode: 'create',
    _editKey: null,   // {from, kind, to} for edit mode

    isOpen() {
      const bd = document.getElementById('edge-modal-backdrop');
      return bd && bd.style.display !== 'none';
    },

    openForCreate() {
      this._mode = 'create';
      this._editKey = null;
      const bd = document.getElementById('edge-modal-backdrop');
      if (!bd) return;
      document.getElementById('edge-modal-title').textContent = 'Add edge';
      document.getElementById('edge-modal-submit').textContent = 'Add edge';
      // Prefill from = current selection if any
      document.getElementById('ef-from').value = State.selectedId || '';
      document.getElementById('ef-from').disabled = false;
      document.getElementById('ef-kind').value = 'depends';
      document.getElementById('ef-kind').disabled = false;
      document.getElementById('ef-to').value = '';
      document.getElementById('ef-to').disabled = false;
      document.getElementById('ef-props').value = '';
      const err = document.getElementById('ef-error');
      err.style.display = 'none';
      err.textContent = '';
      bd.style.display = 'flex';
      setTimeout(() => {
        const which = State.selectedId ? document.getElementById('ef-to')
                                       : document.getElementById('ef-from');
        which.focus();
      }, 50);
    },

    openForEdit({ from, kind, to, props }) {
      this._mode = 'edit';
      this._editKey = { from, kind, to };
      const bd = document.getElementById('edge-modal-backdrop');
      if (!bd) return;
      document.getElementById('edge-modal-title').textContent = 'Edit edge props';
      document.getElementById('edge-modal-submit').textContent = 'Save';
      document.getElementById('ef-from').value = from;
      document.getElementById('ef-from').disabled = true;
      document.getElementById('ef-kind').value = kind;
      document.getElementById('ef-kind').disabled = true;
      document.getElementById('ef-to').value = to;
      document.getElementById('ef-to').disabled = true;
      document.getElementById('ef-props').value = formatEdgePropsText(props);
      const err = document.getElementById('ef-error');
      err.style.display = 'none';
      err.textContent = '';
      bd.style.display = 'flex';
      setTimeout(() => document.getElementById('ef-props').focus(), 50);
    },

    close() {
      const bd = document.getElementById('edge-modal-backdrop');
      if (bd) bd.style.display = 'none';
      // Re-enable disabled fields for next open
      document.getElementById('ef-from').disabled = false;
      document.getElementById('ef-kind').disabled = false;
      document.getElementById('ef-to').disabled = false;
    },

    showError(msg) {
      const err = document.getElementById('ef-error');
      err.textContent = msg;
      err.style.display = 'block';
    },

    validate() {
      if (this._mode === 'edit') {
        return { ok: true, props: parseEdgePropsText(document.getElementById('ef-props').value) };
      }
      const from = document.getElementById('ef-from').value.trim();
      const kind = document.getElementById('ef-kind').value;
      const to   = document.getElementById('ef-to').value.trim();
      const propsText = document.getElementById('ef-props').value;
      if (!from) return { ok: false, msg: 'From task ID is required.' };
      if (!to)   return { ok: false, msg: 'To task ID is required.' };
      if (!/^[a-z][a-z0-9_]*$/.test(from)) {
        return { ok: false, msg: 'From ID must be a lowercase atom.' };
      }
      if (!/^[a-z][a-z0-9_]*$/.test(to)) {
        return { ok: false, msg: 'To ID must be a lowercase atom.' };
      }
      if (from === to) {
        return { ok: false, msg: 'Self-loops are not supported (from and to are the same).' };
      }
      if (!EDGE_KINDS.includes(kind)) {
        return { ok: false, msg: `Unknown edge kind: ${kind}.` };
      }
      const props = parseEdgePropsText(propsText);
      return { ok: true, payload: { from, kind, to, props } };
    },

    async submit() {
      const v = this.validate();
      if (!v.ok) { this.showError(v.msg); return; }

      const submitBtn = document.getElementById('edge-modal-submit');
      const originalLabel = submitBtn.textContent;
      submitBtn.disabled = true;
      submitBtn.textContent = (this._mode === 'edit') ? 'Saving…' : 'Adding…';

      try {
        if (this._mode === 'edit') {
          const { from, kind, to } = this._editKey;
          await API.updateEdgeProps(State.mt, from, kind, to, v.props);
        } else {
          await API.createEdge({ mt: State.mt, ...v.payload });
        }
        this.close();
        await refresh();
        renderPanel();
      } catch (e) {
        let msg = e.message || String(e);
        if (e.status === 401) msg = 'Authentication required. Pass ?u=USER&p=PASS in the URL.';
        else if (e.status === 403) msg = `Forbidden: you don't have write access to "${State.mt}".`;
        else if (e.status === 404) msg = `Endpoint task or edge not found.`;
        else if (e.status === 409) msg = `That edge already exists.`;
        this.showError(msg);
      } finally {
        submitBtn.disabled = false;
        submitBtn.textContent = originalLabel;
      }
    },
  };

  // ============================================================
  // Wire up
  // ============================================================

  function wireUp() {
    document.getElementById('mt-select').addEventListener('change', (e) => {
      State.mt = e.target.value;
      State.selectedId = null;
      State.goalId = null;
      updateGoalChip();
      refresh();
    });

    document.getElementById('refresh-btn').addEventListener('click', refresh);

    document.getElementById('cp-check').addEventListener('change', (e) => {
      State.showCP = e.target.checked;
      refresh();
    });

    document.getElementById('goal-clear').addEventListener('click', () => {
      State.goalId = null;
      updateGoalChip();
      refresh();
    });

    // New-task modal triggers
    document.getElementById('new-task-btn').addEventListener('click', () => {
      NewTaskModal.open();
    });
    document.getElementById('modal-close').addEventListener('click', () => {
      NewTaskModal.close();
    });
    document.getElementById('modal-cancel').addEventListener('click', () => {
      NewTaskModal.close();
    });
    document.getElementById('modal-submit').addEventListener('click', () => {
      NewTaskModal.submit();
    });
    // Click on backdrop (but not on the modal itself) closes
    document.getElementById('modal-backdrop').addEventListener('click', (e) => {
      if (e.target.id === 'modal-backdrop') NewTaskModal.close();
    });
    // Enter inside form fields submits, Escape closes
    ['f-id', 'f-label', 'f-mt', 'f-status'].forEach(fid => {
      const el = document.getElementById(fid);
      if (!el) return;
      el.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') { e.preventDefault(); NewTaskModal.submit(); }
        else if (e.key === 'Escape') { e.preventDefault(); NewTaskModal.close(); }
      });
    });

    // Edge modal triggers
    const newEdgeBtn = document.getElementById('new-edge-btn');
    if (newEdgeBtn) {
      newEdgeBtn.addEventListener('click', () => EdgeModal.openForCreate());
    }
    document.getElementById('edge-modal-close').addEventListener('click', () => {
      EdgeModal.close();
    });
    document.getElementById('edge-modal-cancel').addEventListener('click', () => {
      EdgeModal.close();
    });
    document.getElementById('edge-modal-submit').addEventListener('click', () => {
      EdgeModal.submit();
    });
    document.getElementById('edge-modal-backdrop').addEventListener('click', (e) => {
      if (e.target.id === 'edge-modal-backdrop') EdgeModal.close();
    });
    // Enter on simple inputs submits; Escape on any field closes.
    // The props textarea allows newlines normally; only Cmd/Ctrl+Enter submits there.
    ['ef-from', 'ef-kind', 'ef-to'].forEach(fid => {
      const el = document.getElementById(fid);
      if (!el) return;
      el.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') { e.preventDefault(); EdgeModal.submit(); }
        else if (e.key === 'Escape') { e.preventDefault(); EdgeModal.close(); }
      });
    });
    const propsEl = document.getElementById('ef-props');
    if (propsEl) {
      propsEl.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') { e.preventDefault(); EdgeModal.close(); }
        else if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
          e.preventDefault(); EdgeModal.submit();
        }
      });
    }

    // Keyboard shortcuts
    document.addEventListener('keydown', (e) => {
      // If either modal is open, only handle Escape; let the form take everything else.
      if (NewTaskModal.isOpen()) {
        if (e.key === 'Escape') NewTaskModal.close();
        return;
      }
      if (EdgeModal.isOpen()) {
        if (e.key === 'Escape') EdgeModal.close();
        return;
      }
      if (e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT' || e.target.tagName === 'TEXTAREA') return;
      if (e.key === 'r') refresh();
      else if (e.key === 'n') { e.preventDefault(); NewTaskModal.open(); }
      else if (e.key === 'e') { e.preventDefault(); EdgeModal.openForCreate(); }
      else if (e.key === 'Escape') {
        State.selectedId = null;
        State.goalId = null;
        updateGoalChip();
        if (State.lastSnapshot) render(State.lastSnapshot);
        renderPanel();
      } else if (e.key === 'f' && State.selectedId) {
        const el = cy.getElementById(State.selectedId);
        if (el.length) cy.animate({ center: { eles: el }, zoom: 1.3, duration: 220 });
      }
    });

    // Auth prompt via URL: ?u=alice&p=hunter2  (dev convenience only)
    const params = new URLSearchParams(window.location.search);
    const u = params.get('u');
    const p = params.get('p');
    if (u && p) {
      State.auth = { user: u, password: p };
      document.getElementById('conn-user').textContent = u;
    }
    const mt = params.get('mt');
    if (mt) {
      State.mt = mt;
      document.getElementById('mt-select').value = mt;
    }
  }

  async function init() {
    wireUp();
    initCytoscape();
    await checkHealth();
    await refresh();
    State.pollTimer = setInterval(pollEvents, 3000);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

})();
