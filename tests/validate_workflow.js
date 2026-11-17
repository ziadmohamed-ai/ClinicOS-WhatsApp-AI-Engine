#!/usr/bin/env node
// Workflow structural, source-of-truth sync, and L2V add-on contract validator (Task T5 / T6).
// Usage:
//   node tests/validate_workflow.js
//   node tests/validate_workflow.js workflow/clinicos-main-engine.json workflow/clinicos-main-engine.l2v.json

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { getSourceOfTruthMap } = require('../scripts/sync_node_code.js');

const REPO_ROOT = path.resolve(__dirname, '..');
const ORIG_WF_PATH = path.join(REPO_ROOT, 'workflow', 'clinicos-main-engine.json');
const L2V_WF_PATH = path.join(REPO_ROOT, 'workflow', 'clinicos-main-engine.l2v.json');
const SLA_WF_PATH = path.join(REPO_ROOT, 'workflow', 'clinicos-l2v-sla-tick.json');
const TASKS_MD_PATH = path.join(REPO_ROOT, 'docs', 'l2v', 'TASKS.md');

const EXPECTED_ADDED_NODES = [
  'L2V Prepare',
  'L2V Gate',
  'L2V Merge',
  'Is Staff?',
  'L2V Qualify?',
  'L2V Qualify',
];

const TRIGGER_TYPES = new Set([
  'n8n-nodes-base.webhook',
  'n8n-nodes-base.scheduleTrigger',
  'n8n-nodes-base.errorTrigger',
]);

function extractGateSqlFromTasksMd() {
  const md = fs.readFileSync(TASKS_MD_PATH, 'utf8').replace(/\r\n/g, '\n');
  const m = md.match(/`L2V Gate` query[^\n]*\n```sql\n([\s\S]*?)\n```/);
  assert.ok(m && m[1], 'Could not extract L2V Gate SQL block from docs/l2v/TASKS.md');
  return m[1].trim();
}

function extractQualifySqlFromTasksMd() {
  const md = fs.readFileSync(TASKS_MD_PATH, 'utf8').replace(/\r\n/g, '\n');
  const m = md.match(/`L2V Qualify` runs `(SELECT \* FROM l2v\.qualify_contact\([^`]+\);)`/);
  assert.ok(m && m[1], 'Could not extract L2V Qualify SQL from docs/l2v/TASKS.md');
  return m[1].trim();
}

function validateStructure(wfPath) {
  const rel = path.relative(REPO_ROOT, wfPath);
  const wf = JSON.parse(fs.readFileSync(wfPath, 'utf8'));
  const sourceMap = getSourceOfTruthMap();

  assert.ok(
    typeof wf.name === 'string' && wf.name.startsWith('ClinicOS'),
    `${rel}: workflow name must start with "ClinicOS", got ${JSON.stringify(wf.name)}`
  );
  assert.ok(Array.isArray(wf.nodes) && wf.nodes.length > 0, `${rel}: wf.nodes must be a non-empty array`);
  assert.ok(wf.connections && typeof wf.connections === 'object', `${rel}: wf.connections must be an object`);

  const names = new Set();
  const ids = new Set();
  for (const n of wf.nodes) {
    assert.ok(n && typeof n.name === 'string' && n.name.trim(), `${rel}: every node must have a non-empty name`);
    assert.ok(typeof n.id === 'string' && n.id.trim(), `${rel}: node "${n.name}" must have a non-empty id`);
    assert.ok(typeof n.type === 'string' && n.type.trim(), `${rel}: node "${n.name}" must have a non-empty type`);
    assert.ok(!names.has(n.name), `${rel}: duplicate node name "${n.name}"`);
    assert.ok(!ids.has(n.id), `${rel}: duplicate node id "${n.id}" on "${n.name}"`);
    names.add(n.name);
    ids.add(n.id);

    if (n.credentials && typeof n.credentials === 'object') {
      for (const [credType, credObj] of Object.entries(n.credentials)) {
        assert.ok(
          credObj && typeof credObj.id === 'string' && /^YOUR_[A-Z0-9_]+_CREDENTIAL_ID$/.test(credObj.id),
          `${rel}: node "${n.name}" credential "${credType}" id must be a YOUR_*_CREDENTIAL_ID placeholder, got ${JSON.stringify(credObj?.id)}`
        );
      }
    }

    // Every code/agent node backed by a source file in nodes/*.js or prompts/*.xml must match it exactly
    const spec = sourceMap[n.name];
    if (spec) {
      if (spec.kind === 'jsCode') {
        const actual = String(n.parameters?.jsCode ?? '').replace(/\r\n/g, '\n');
        assert.strictEqual(
          actual,
          spec.expected,
          `${rel}: node "${n.name}" parameters.jsCode is out of sync with ${spec.relPath} (run node scripts/sync_node_code.js)`
        );
      } else if (spec.kind === 'systemMessage') {
        const actual = String(n.parameters?.options?.systemMessage ?? '').replace(/\r\n/g, '\n');
        assert.strictEqual(
          actual,
          spec.expected,
          `${rel}: node "${n.name}" parameters.options.systemMessage is out of sync with ${spec.relPath} (run node scripts/sync_node_code.js)`
        );
      }
    }
  }

  const incomingCount = new Map([...names].map((n) => [n, 0]));
  const outgoingCount = new Map([...names].map((n) => [n, 0]));

  for (const [srcName, connByType] of Object.entries(wf.connections)) {
    assert.ok(names.has(srcName), `${rel}: connection source "${srcName}" does not exist in nodes`);
    assert.ok(connByType && typeof connByType === 'object', `${rel}: invalid connection entry for "${srcName}"`);
    for (const [connType, branches] of Object.entries(connByType)) {
      assert.ok(Array.isArray(branches), `${rel}: "${srcName}.${connType}" must be an array of branches`);
      for (const branch of branches) {
        assert.ok(Array.isArray(branch), `${rel}: branch in "${srcName}.${connType}" must be an array`);
        for (const target of branch) {
          assert.ok(
            target && typeof target.node === 'string' && names.has(target.node),
            `${rel}: connection target "${target?.node}" from "${srcName}" does not exist in nodes`
          );
          outgoingCount.set(srcName, (outgoingCount.get(srcName) || 0) + 1);
          incomingCount.set(target.node, (incomingCount.get(target.node) || 0) + 1);
        }
      }
    }
  }

  for (const n of wf.nodes) {
    const inc = incomingCount.get(n.name) || 0;
    const out = outgoingCount.get(n.name) || 0;
    assert.ok(inc + out > 0, `${rel}: orphan node "${n.name}" has neither incoming nor outgoing connections`);
    const isAiSubNode = n.type.startsWith('@n8n/n8n-nodes-langchain.lm');
    if (!TRIGGER_TYPES.has(n.type) && !isAiSubNode) {
      assert.ok(inc > 0, `${rel}: non-trigger node "${n.name}" (${n.type}) has no incoming connection`);
    }
  }

  return wf;
}

function validateL2vAddonContract(origWf, l2vWf) {
  const origByName = new Map(origWf.nodes.map((n) => [n.name, n]));
  const l2vByName = new Map(l2vWf.nodes.map((n) => [n.name, n]));
  const sourceMap = getSourceOfTruthMap();

  const removed = [...origByName.keys()].filter((k) => !l2vByName.has(k));
  const added = [...l2vByName.keys()].filter((k) => !origByName.has(k));

  assert.deepStrictEqual(removed, [], `L2V workflow must not remove any existing nodes, removed: ${removed.join(', ')}`);
  assert.deepStrictEqual(
    added,
    EXPECTED_ADDED_NODES,
    `L2V workflow must add only ${JSON.stringify(EXPECTED_ADDED_NODES)}, got ${JSON.stringify(added)}`
  );

  // Check that no existing node changed except Reminder & Outbox Timer (1 min) plus synced jsCode/systemMessage fields
  for (const [name, origNode] of origByName.entries()) {
    const l2vNode = l2vByName.get(name);
    const cloneOrig = JSON.parse(JSON.stringify(origNode));
    if (name === 'Reminder & Outbox Timer') {
      const interval = l2vNode.parameters?.rule?.interval;
      assert.deepStrictEqual(
        interval,
        [{ field: 'minutes', minutesInterval: 1 }],
        `Reminder & Outbox Timer interval must be 1 minute, got ${JSON.stringify(interval)}`
      );
      cloneOrig.parameters.rule.interval = [{ field: 'minutes', minutesInterval: 1 }];
    }
    const spec = sourceMap[name];
    if (spec) {
      if (spec.kind === 'jsCode') {
        cloneOrig.parameters.jsCode = spec.expected;
      } else if (spec.kind === 'systemMessage') {
        if (!cloneOrig.parameters.options) cloneOrig.parameters.options = {};
        cloneOrig.parameters.options.systemMessage = spec.expected;
      }
    }
    assert.strictEqual(
      JSON.stringify(l2vNode),
      JSON.stringify(cloneOrig),
      `Pre-existing node "${name}" changed disallowed properties`
    );
  }

  // Verify pre-existing connections preserved except Parse Turn & State -> Route Turn and Emergency Reply Guard side branch
  for (const [src, origConn] of Object.entries(origWf.connections)) {
    const l2vConn = l2vWf.connections[src];
    assert.ok(l2vConn, `Pre-existing connection source "${src}" missing in L2V workflow`);
    if (src === 'Parse Turn & State') {
      assert.deepStrictEqual(
        l2vConn,
        { main: [[{ node: 'L2V Prepare', type: 'main', index: 0 }]] },
        'Parse Turn & State must connect only to L2V Prepare'
      );
    } else if (src === 'Emergency Reply Guard') {
      assert.deepStrictEqual(
        l2vConn,
        {
          main: [
            [
              { node: 'Search Slots?', type: 'main', index: 0 },
              { node: 'L2V Qualify?', type: 'main', index: 0 },
            ],
          ],
        },
        'Emergency Reply Guard must connect to Search Slots? and L2V Qualify?'
      );
    } else {
      assert.strictEqual(
        JSON.stringify(l2vConn),
        JSON.stringify(origConn),
        `Connections for pre-existing node "${src}" were modified`
      );
    }
  }

  // Verify new L2V connections
  assert.deepStrictEqual(
    l2vWf.connections['L2V Prepare'],
    { main: [[{ node: 'L2V Gate', type: 'main', index: 0 }]] },
    'L2V Prepare must connect to L2V Gate'
  );
  assert.deepStrictEqual(
    l2vWf.connections['L2V Gate'],
    { main: [[{ node: 'L2V Merge', type: 'main', index: 0 }]] },
    'L2V Gate must connect to L2V Merge'
  );
  assert.deepStrictEqual(
    l2vWf.connections['L2V Merge'],
    { main: [[{ node: 'Is Staff?', type: 'main', index: 0 }]] },
    'L2V Merge must connect to Is Staff?'
  );
  assert.deepStrictEqual(
    l2vWf.connections['Is Staff?'],
    { main: [[], [{ node: 'Route Turn', type: 'main', index: 0 }]] },
    'Is Staff? must have empty true-branch and false-branch -> Route Turn'
  );
  assert.deepStrictEqual(
    l2vWf.connections['L2V Qualify?'],
    { main: [[{ node: 'L2V Qualify', type: 'main', index: 0 }], []] },
    'L2V Qualify? must connect true-branch -> L2V Qualify and empty false-branch'
  );
  const qualifyOut = l2vWf.connections['L2V Qualify'];
  assert.ok(
    !qualifyOut || Object.values(qualifyOut).every((b) => b.flat().length === 0),
    'L2V Qualify must be a dead end with no outgoing connections'
  );

  // Verify L2V Prepare code mode is runOnceForEachItem
  const prepareNode = l2vByName.get('L2V Prepare');
  assert.strictEqual(prepareNode.type, 'n8n-nodes-base.code');
  assert.strictEqual(prepareNode.parameters.mode, 'runOnceForEachItem');

  // Verify L2V Merge fail-open behavior and .all()[$itemIndex] fallback (never .first())
  const mergeNode = l2vByName.get('L2V Merge');
  assert.strictEqual(mergeNode.type, 'n8n-nodes-base.code');
  assert.strictEqual(mergeNode.parameters.mode, 'runOnceForEachItem');
  assert.ok(!/\.first\s*\(/.test(mergeNode.parameters.jsCode), 'L2V Merge must never use .first() fallback');
  assert.ok(
    mergeNode.parameters.jsCode.includes("$('Parse Turn & State').all()"),
    'L2V Merge must use $("Parse Turn & State").all()[$itemIndex] fallback'
  );

  const fnMerge = new Function('$json', '$', '$itemIndex', mergeNode.parameters.jsCode);
  const sampleTurn0 = { clinic_id: 'c1', contact_id: 'p1', body: 'first', route: 'ai' };
  const sampleTurn1 = { clinic_id: 'c1', contact_id: 'p2', body: 'second', route: 'ai' };
  const lookupItem = (name) => {
    if (name === 'Parse Turn & State') return { item: { json: sampleTurn0 } };
    throw new Error('Unexpected lookup: ' + name);
  };
  const lookupAll = (name) => {
    if (name === 'Parse Turn & State') return { all: () => [{ json: sampleTurn0 }, { json: sampleTurn1 }] };
    throw new Error('Unexpected lookup: ' + name);
  };
  const lookupItemThrowsAllWorks = (name) => {
    if (name === 'Parse Turn & State') {
      return {
        get item() {
          throw new Error('Paired item lost');
        },
        all: () => [{ json: sampleTurn0 }, { json: sampleTurn1 }],
      };
    }
    throw new Error('Unexpected lookup: ' + name);
  };
  const lookupBothThrow = (name) => {
    if (name === 'Parse Turn & State') {
      return {
        get item() {
          throw new Error('Paired item lost');
        },
        all: () => {
          throw new Error('Execution data unavailable');
        },
      };
    }
    throw new Error('Unexpected lookup: ' + name);
  };
  const lookupBroken = () => {
    throw new Error('Parse Turn unavailable');
  };

  assert.deepStrictEqual(fnMerge({ is_staff: true }, lookupItem, 0).json, { ...sampleTurn0, l2v_is_staff: true });
  assert.deepStrictEqual(fnMerge({ is_staff: false }, lookupItem, 0).json, { ...sampleTurn0, l2v_is_staff: false });
  assert.deepStrictEqual(fnMerge({}, lookupItem, 0).json, { ...sampleTurn0, l2v_is_staff: false });
  assert.deepStrictEqual(fnMerge({ error: 'db timeout', is_staff: true }, lookupItem, 0).json, {
    ...sampleTurn0,
    l2v_is_staff: false,
  });
  // Verify .all()[$itemIndex] selects item 1 (not item 0) when .item getter throws or is absent
  assert.deepStrictEqual(fnMerge({ is_staff: false }, lookupItemThrowsAllWorks, 1).json, {
    ...sampleTurn1,
    l2v_is_staff: false,
  });
  assert.deepStrictEqual(fnMerge({ is_staff: true }, lookupItemThrowsAllWorks, 1).json, {
    ...sampleTurn1,
    l2v_is_staff: true,
  });
  assert.deepStrictEqual(fnMerge({ is_staff: false }, lookupAll, 1).json, { ...sampleTurn1, l2v_is_staff: false });
  // Verify unavailable Parse Turn or both .item and .all() throwing returns { l2v_is_staff: false } only
  assert.deepStrictEqual(fnMerge({ is_staff: true }, lookupBothThrow, 1).json, { l2v_is_staff: false });
  assert.deepStrictEqual(fnMerge({ is_staff: true }, lookupBroken, 0).json, { l2v_is_staff: false });
  assert.deepStrictEqual(fnMerge({ is_staff: true }, lookupAll, 5).json, { l2v_is_staff: false });

  // Verify L2V Gate and L2V Qualify Postgres nodes (onError, options, queries vs docs/l2v/TASKS.md)
  const gateNode = l2vByName.get('L2V Gate');
  const qualifyNode = l2vByName.get('L2V Qualify');
  for (const pgNode of [gateNode, qualifyNode]) {
    assert.strictEqual(pgNode.type, 'n8n-nodes-base.postgres');
    assert.strictEqual(pgNode.onError, 'continueRegularOutput', `${pgNode.name} must set onError: "continueRegularOutput"`);
    assert.strictEqual(pgNode.parameters.operation, 'executeQuery');
    assert.strictEqual(pgNode.parameters.options?.queryBatching, 'single');
    assert.strictEqual(pgNode.credentials?.postgres?.id, 'YOUR_POSTGRES_CREDENTIAL_ID');
  }

  const expectedGateSql = extractGateSqlFromTasksMd();
  assert.strictEqual(
    gateNode.parameters.query.replace(/\r\n/g, '\n').trim(),
    expectedGateSql,
    'L2V Gate query text must exactly match the SQL block in docs/l2v/TASKS.md'
  );

  const expectedQualifySql = extractQualifySqlFromTasksMd();
  assert.strictEqual(
    qualifyNode.parameters.query.replace(/\r\n/g, '\n').trim(),
    expectedQualifySql,
    'L2V Qualify query text must exactly match docs/l2v/TASKS.md'
  );
  assert.ok(
    qualifyNode.parameters.options?.queryReplacement?.includes('$json.service_name_ar ?? null'),
    'L2V Qualify queryReplacement must pass $json.service_name_ar ?? null as the 5th parameter'
  );
  assert.ok(
    !qualifyNode.parameters.options?.queryReplacement?.includes('service_code'),
    'L2V Qualify queryReplacement must not pass service_code'
  );
}

function main() {
  const args = process.argv.slice(2);
  const targets =
    args.length > 0
      ? args.map((p) => path.resolve(process.cwd(), p))
      : [ORIG_WF_PATH, L2V_WF_PATH, ...(fs.existsSync(SLA_WF_PATH) ? [SLA_WF_PATH] : [])];

  for (const t of targets) {
    const wf = validateStructure(t);
    if (path.resolve(t) === path.resolve(L2V_WF_PATH)) {
      const origWf = validateStructure(ORIG_WF_PATH);
      validateL2vAddonContract(origWf, wf);
    }
    console.log(`Workflow valid: ${path.relative(REPO_ROOT, t)} (${wf.nodes.length} nodes)`);
  }
}

if (require.main === module) {
  main();
}

module.exports = { validateStructure, validateL2vAddonContract };
