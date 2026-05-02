/*  SPSE4 web client — single-page app.
    Part of FRKCSA / SPSE4.  MIT License.

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
    pill.className = 'status-pill status-' + d.status;
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
    const outDeps = edges.filter(e => e.data.source === d.id && e.data.kind === 'depends');
    const inDeps  = edges.filter(e => e.data.target === d.id && e.data.kind === 'depends');
    const blockers = outDeps.filter(e => {
      const tgt = nodes.find(n => n.data.id === e.data.target);
      return tgt && tgt.data.status !== 'completed';
    });

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

    // Depends on
    const depsSec = document.getElementById('d-deps-section');
    if (outDeps.length > 0) {
      depsSec.style.display = 'block';
      document.getElementById('d-deps').innerHTML = outDeps.map(e => {
        const tgt = nodes.find(n => n.data.id === e.data.target);
        const status = tgt ? tgt.data.status : '?';
        return `<div class="edge-item" data-id="${e.data.target}">
          <span class="e-id">${escapeHtml(e.data.target)}</span>
          <span class="e-status">${escapeHtml(status)}</span>
        </div>`;
      }).join('');
    } else {
      depsSec.style.display = 'none';
    }

    // Dependents
    const depsBySec = document.getElementById('d-dependents-section');
    if (inDeps.length > 0) {
      depsBySec.style.display = 'block';
      document.getElementById('d-dependents').innerHTML = inDeps.map(e => {
        const src = nodes.find(n => n.data.id === e.data.source);
        const status = src ? src.data.status : '?';
        return `<div class="edge-item" data-id="${e.data.source}">
          <span class="e-id">${escapeHtml(e.data.source)}</span>
          <span class="e-status">${escapeHtml(status)}</span>
        </div>`;
      }).join('');
    } else {
      depsBySec.style.display = 'none';
    }

    // Wire edge-list clicks to selection
    document.querySelectorAll('.blocker-item, .edge-item').forEach(el => {
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
        }
      };
    });
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

    // Keyboard shortcuts
    document.addEventListener('keydown', (e) => {
      if (e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT') return;
      if (e.key === 'r') refresh();
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
