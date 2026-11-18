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
const DASH_WF_PATH = path.join(REPO_ROOT, 'workflow', 'clinicos-dashboard-api.json');
const TASKS_MD_PATH = path.join(REPO_ROOT, 'docs', 'l2v', 'TASKS.md');
const { DASHBOARD_API_QUERY } = require('../scripts/build_l2v_workflow.js');

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

function validateStructure(wfOrPath, customLabel) {
  const isPath = typeof wfOrPath === 'string';
  const rel = customLabel || (isPath ? path.relative(REPO_ROOT, wfOrPath) : '<in-memory-workflow>');
  const wf = isPath ? JSON.parse(fs.readFileSync(wfOrPath, 'utf8')) : wfOrPath;
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

  const saveNode = wf.nodes.find((n) => n.name === 'Save State & Enqueue');
  if (saveNode) {
    const q = String(saveNode.parameters?.query ?? '');
    assert.ok(
      q.includes("'whatsapp'::text, NULL::text") && !q.includes("'whatsapp'::text, $17::text"),
      `${rel}: Save State & Enqueue must pass NULL::text (not $17::text) as 7th argument to book_appointment`
    );
  }
  const isVoiceNode = wf.nodes.find((n) => n.name === 'Is Voice Note?');
  if (isVoiceNode) {
    const condExpr = String(isVoiceNode.parameters?.conditions?.conditions?.[0]?.leftValue ?? '');
    assert.ok(
      condExpr.includes('messages.some(') && !condExpr.includes('messages[0]'),
      `${rel}: Is Voice Note? must inspect messages.some(...) rather than hardcoding messages[0]`
    );
  }
  const getAudioNode = wf.nodes.find((n) => n.name === 'Get Audio URL');
  if (getAudioNode) {
    const urlExpr = String(getAudioNode.parameters?.url ?? '');
    assert.ok(
      urlExpr.includes('.find(') && !urlExpr.includes('messages[0]'),
      `${rel}: Get Audio URL must resolve the actionable voice message via .find(...) rather than hardcoding messages[0]`
    );
  }
  const dlVoiceNode = wf.nodes.find((n) => n.name === 'Download Voice');
  if (dlVoiceNode) {
    const urlExpr = String(dlVoiceNode.parameters?.url ?? '');
    assert.ok(
      urlExpr.includes('msgs.find(') && !urlExpr.includes('messages[0]'),
      `${rel}: Download Voice must resolve the actionable voice message via msgs.find(...) rather than hardcoding messages[0]`
    );
  }
  const txVoiceNode = wf.nodes.find((n) => n.name === 'Transcribe Voice');
  if (txVoiceNode) {
    const promptExpr = String(
      (txVoiceNode.parameters?.bodyParameters?.parameters || []).find((p) => p.name === 'prompt')?.value ?? ''
    );
    assert.ok(
      promptExpr.includes('msgs.find(') && !promptExpr.includes('messages?.[0]'),
      `${rel}: Transcribe Voice prompt must resolve the actionable voice message via msgs.find(...) rather than hardcoding messages?.[0]`
    );
  }
  const saveTxNode = wf.nodes.find((n) => n.name === 'Save & Inject Transcript');
  if (saveTxNode) {
    const q = String(saveTxNode.parameters?.query ?? '').trim();
    const rep = String(saveTxNode.parameters?.options?.queryReplacement ?? '');
    assert.strictEqual(
      q,
      'SELECT public.apply_voice_transcription($1::jsonb, $2::text) AS result;',
      `${rel}: Save & Inject Transcript must keep the 2-parameter call to public.apply_voice_transcription($1::jsonb, $2::text)`
    );
    assert.ok(
      rep.includes('msgs.findIndex('),
      `${rel}: Save & Inject Transcript queryReplacement must locate the actionable voice item via msgs.findIndex(...)`
    );
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

function validateSlaTickContract(origWf, slaWf) {
  validateStructure(slaWf, 'workflow/clinicos-l2v-sla-tick.json');

  assert.strictEqual(
    slaWf.name,
    'ClinicOS L2V SLA Tick',
    `SLA tick workflow name must be "ClinicOS L2V SLA Tick", got ${JSON.stringify(slaWf.name)}`
  );
  assert.strictEqual(
    slaWf.nodes.length,
    4,
    `SLA tick workflow must have exactly 4 nodes, got ${slaWf.nodes.length}`
  );
  for (const n of slaWf.nodes) {
    assert.ok(!n.disabled, `Node "${n.name}" in SLA tick workflow must not have disabled: true`);
    assert.ok(!n.continueOnFail, `Node "${n.name}" in SLA tick workflow must not set continueOnFail: true`);
  }

  const scheduleNodes = slaWf.nodes.filter((n) => n.type === 'n8n-nodes-base.scheduleTrigger');
  assert.strictEqual(scheduleNodes.length, 1, 'SLA tick workflow must have exactly 1 Schedule Trigger node');
  const scheduleNode = scheduleNodes[0];
  assert.strictEqual(scheduleNode.typeVersion, 1.4, 'Schedule Trigger typeVersion must be 1.4');
  assert.deepStrictEqual(
    scheduleNode.parameters?.rule?.interval,
    [{ field: 'minutes', minutesInterval: 1 }],
    `Schedule Trigger interval must be 1 minute, got ${JSON.stringify(scheduleNode.parameters?.rule?.interval)}`
  );

  const schedConn = slaWf.connections[scheduleNode.name];
  assert.ok(
    schedConn &&
      Array.isArray(schedConn.main) &&
      schedConn.main.length === 1 &&
      Array.isArray(schedConn.main[0]) &&
      schedConn.main[0].length === 1,
    'Schedule Trigger must have a single outgoing main connection'
  );
  const escalateNodeName = schedConn.main[0][0].node;
  const escalateNode = slaWf.nodes.find((n) => n.name === escalateNodeName);
  assert.ok(escalateNode, `Escalate target node "${escalateNodeName}" not found`);
  assert.strictEqual(escalateNode.type, 'n8n-nodes-base.postgres', 'Escalate node must be a Postgres node');
  assert.strictEqual(escalateNode.typeVersion, 2.8, 'Escalate Postgres node typeVersion must be 2.8');
  assert.strictEqual(escalateNode.parameters?.operation, 'executeQuery', 'Escalate Postgres node must use executeQuery');
  const expectedSlaQuery = 'SELECT l2v.release_overnight() AS released, l2v.escalate_overdue() AS escalated;';
  assert.strictEqual(
    String(escalateNode.parameters?.query ?? '').replace(/\r\n/g, '\n').trim(),
    expectedSlaQuery,
    `Escalate Postgres node query must be "${expectedSlaQuery}", got ${JSON.stringify(escalateNode.parameters?.query)}`
  );
  assert.strictEqual(
    escalateNode.parameters?.options?.queryBatching,
    'single',
    'Escalate Postgres node must set options.queryBatching = "single"'
  );
  assert.strictEqual(escalateNode.retryOnFail, true, 'Escalate Postgres node must set retryOnFail: true');
  assert.strictEqual(escalateNode.maxTries, 3, 'Escalate Postgres node must set maxTries: 3');
  assert.strictEqual(escalateNode.waitBetweenTries, 1000, 'Escalate Postgres node must set waitBetweenTries: 1000');

  const escalateOut = slaWf.connections[escalateNode.name];
  assert.ok(
    !escalateOut || Object.values(escalateOut).every((b) => b.flat().length === 0),
    'Escalate Postgres node must have no outgoing connections'
  );

  // Verify Error Trigger -> Log Workflow Error matches main workflow
  const origErrorTrigger = origWf.nodes.find((n) => n.name === 'Error Trigger');
  const origLogError = origWf.nodes.find((n) => n.name === 'Log Workflow Error');
  const slaErrorTrigger = slaWf.nodes.find((n) => n.name === 'Error Trigger');
  const slaLogError = slaWf.nodes.find((n) => n.name === 'Log Workflow Error');

  assert.ok(slaErrorTrigger, 'SLA tick workflow must include "Error Trigger"');
  assert.ok(slaLogError, 'SLA tick workflow must include "Log Workflow Error"');

  for (const pgNode of [escalateNode, slaLogError]) {
    assert.ok(
      pgNode.onError === undefined || pgNode.onError === 'stopWorkflow',
      `Postgres node "${pgNode.name}" in SLA tick workflow must not swallow errors with onError: ${JSON.stringify(pgNode.onError)}`
    );
    assert.strictEqual(
      pgNode.credentials?.postgres?.id,
      'YOUR_POSTGRES_CREDENTIAL_ID',
      `Postgres node "${pgNode.name}" must use placeholder credential YOUR_POSTGRES_CREDENTIAL_ID`
    );
    assert.strictEqual(
      pgNode.credentials?.postgres?.name,
      'ClinicOS Runtime PostgreSQL',
      `Postgres node "${pgNode.name}" must use credential name "ClinicOS Runtime PostgreSQL", got ${JSON.stringify(pgNode.credentials?.postgres?.name)}`
    );
  }

  assert.strictEqual(
    JSON.stringify(slaErrorTrigger),
    JSON.stringify(origErrorTrigger),
    '"Error Trigger" in SLA tick workflow must match "Error Trigger" in clinicos-main-engine.json'
  );
  assert.strictEqual(
    JSON.stringify(slaLogError),
    JSON.stringify(origLogError),
    '"Log Workflow Error" in SLA tick workflow must match "Log Workflow Error" in clinicos-main-engine.json'
  );
  assert.deepStrictEqual(
    slaWf.connections['Error Trigger'],
    { main: [[{ node: 'Log Workflow Error', type: 'main', index: 0 }]] },
    'Error Trigger must connect to Log Workflow Error'
  );
  const logErrorOut = slaWf.connections['Log Workflow Error'];
  assert.ok(
    !logErrorOut || Object.values(logErrorOut).every((b) => b.flat().length === 0),
    'Log Workflow Error must have no outgoing connections'
  );
}

function runSlaTickMutationTests(origWf, slaWf) {
  const clone = () => JSON.parse(JSON.stringify(slaWf));

  // Mutation 1: workflow name not starting with ClinicOS
  assert.throws(
    () => {
      const m = clone();
      m.name = 'L2V SLA Tick';
      validateSlaTickContract(origWf, m);
    },
    /workflow name must start with "ClinicOS"/,
    'Mutation 1 (name not starting with ClinicOS) must be rejected'
  );

  // Mutation 2: workflow name starts with ClinicOS but is not "ClinicOS L2V SLA Tick"
  assert.throws(
    () => {
      const m = clone();
      m.name = 'ClinicOS Wrong SLA Workflow';
      validateSlaTickContract(origWf, m);
    },
    /SLA tick workflow name must be "ClinicOS L2V SLA Tick"/,
    'Mutation 2 (wrong ClinicOS workflow name) must be rejected'
  );

  // Mutation 3: schedule interval != 1 minute
  assert.throws(
    () => {
      const m = clone();
      const sched = m.nodes.find((n) => n.type === 'n8n-nodes-base.scheduleTrigger');
      sched.parameters.rule.interval = [{ field: 'minutes', minutesInterval: 15 }];
      validateSlaTickContract(origWf, m);
    },
    /Schedule Trigger interval must be 1 minute/,
    'Mutation 3 (schedule interval != 1 minute) must be rejected'
  );

  // Mutation 4: wrong SQL query on the escalate Postgres node
  assert.throws(
    () => {
      const m = clone();
      const esc = m.nodes.find((n) => n.name === 'Escalate Overdue Leads');
      esc.parameters.query = 'SELECT l2v.escalate_overdue();';
      validateSlaTickContract(origWf, m);
    },
    /Escalate Postgres node query must be "SELECT l2v\.release_overnight\(\) AS released, l2v\.escalate_overdue\(\) AS escalated;"/,
    'Mutation 4 (wrong SQL query on escalate Postgres node) must be rejected'
  );

  // Mutation 5: non-placeholder credential id
  assert.throws(
    () => {
      const m = clone();
      const esc = m.nodes.find((n) => n.name === 'Escalate Overdue Leads');
      esc.credentials.postgres.id = 'real-secret-cred-123';
      validateSlaTickContract(origWf, m);
    },
    /YOUR_\*_CREDENTIAL_ID placeholder/,
    'Mutation 5 (non-placeholder credential id) must be rejected'
  );

  // Mutation 6: missing Error Trigger -> Log Workflow Error connection (causes orphan / unconnected node)
  assert.throws(
    () => {
      const m = clone();
      delete m.connections['Error Trigger'];
      validateSlaTickContract(origWf, m);
    },
    /orphan node|no incoming connection|Error Trigger must connect to Log Workflow Error/,
    'Mutation 6 (missing Error Trigger -> Log Workflow Error connection) must be rejected'
  );

  // Mutation 7: modified Log Workflow Error query vs main workflow
  assert.throws(
    () => {
      const m = clone();
      const logNode = m.nodes.find((n) => n.name === 'Log Workflow Error');
      logNode.parameters.query = 'SELECT 1;';
      validateSlaTickContract(origWf, m);
    },
    /"Log Workflow Error" in SLA tick workflow must match "Log Workflow Error" in clinicos-main-engine\.json/,
    'Mutation 7 (mismatched Log Workflow Error node) must be rejected'
  );

  // Mutation 8: disabled: true on Schedule Trigger (or Escalate Overdue Leads)
  assert.throws(
    () => {
      const m = clone();
      const sched = m.nodes.find((n) => n.name === 'Schedule Trigger');
      sched.disabled = true;
      validateSlaTickContract(origWf, m);
    },
    /Node "Schedule Trigger" in SLA tick workflow must not have disabled: true/,
    'Mutation 8 (disabled: true on Schedule Trigger) must be rejected'
  );
  assert.throws(
    () => {
      const m = clone();
      const esc = m.nodes.find((n) => n.name === 'Escalate Overdue Leads');
      esc.disabled = true;
      validateSlaTickContract(origWf, m);
    },
    /Node "Escalate Overdue Leads" in SLA tick workflow must not have disabled: true/,
    'Mutation 8b (disabled: true on Escalate Overdue Leads) must be rejected'
  );

  // Mutation 9: onError: 'continueRegularOutput' (and 'continueErrorOutput') on Escalate Overdue Leads
  assert.throws(
    () => {
      const m = clone();
      const esc = m.nodes.find((n) => n.name === 'Escalate Overdue Leads');
      esc.onError = 'continueRegularOutput';
      validateSlaTickContract(origWf, m);
    },
    /Postgres node "Escalate Overdue Leads" in SLA tick workflow must not swallow errors with onError: "continueRegularOutput"/,
    'Mutation 9 (onError: continueRegularOutput on Escalate Overdue Leads) must be rejected'
  );
  assert.throws(
    () => {
      const m = clone();
      const esc = m.nodes.find((n) => n.name === 'Escalate Overdue Leads');
      esc.onError = 'continueErrorOutput';
      validateSlaTickContract(origWf, m);
    },
    /Postgres node "Escalate Overdue Leads" in SLA tick workflow must not swallow errors with onError: "continueErrorOutput"/,
    'Mutation 9b (onError: continueErrorOutput on Escalate Overdue Leads) must be rejected'
  );

  // Mutation 10: credentials.postgres.name changed from 'ClinicOS Runtime PostgreSQL' to 'Wrong Credential Name'
  assert.throws(
    () => {
      const m = clone();
      const esc = m.nodes.find((n) => n.name === 'Escalate Overdue Leads');
      esc.credentials.postgres.name = 'Wrong Credential Name';
      validateSlaTickContract(origWf, m);
    },
    /Postgres node "Escalate Overdue Leads" must use credential name "ClinicOS Runtime PostgreSQL"/,
    'Mutation 10 (wrong credentials.postgres.name) must be rejected'
  );

  // Mutation 11 (T11): legacy SLA Tick query omitting l2v.release_overnight()
  assert.throws(
    () => {
      const m = clone();
      const esc = m.nodes.find((n) => n.name === 'Escalate Overdue Leads');
      esc.parameters.query = 'SELECT l2v.escalate_overdue() AS escalated;';
      validateSlaTickContract(origWf, m);
    },
    /Escalate Postgres node query must be "SELECT l2v\.release_overnight\(\) AS released, l2v\.escalate_overdue\(\) AS escalated;"/,
    'Mutation 11 (omitting l2v.release_overnight() from SLA Tick query) must be rejected'
  );

  return 11;
}

function runMainWorkflowAuditMutationTests(wf) {
  const clone = () => JSON.parse(JSON.stringify(wf));

  // Mutation 1: revert Save State & Enqueue NULL::text back to $17::text
  assert.throws(
    () => {
      const m = clone();
      const saveNode = m.nodes.find((n) => n.name === 'Save State & Enqueue');
      saveNode.parameters.query = saveNode.parameters.query.replace(
        "'whatsapp'::text, NULL::text",
        "'whatsapp'::text, $17::text"
      );
      validateStructure(m, 'mutation-save-state');
    },
    /Save State & Enqueue must pass NULL::text/,
    'Mutation 1 (reverted $17::text in Save State & Enqueue) must be rejected'
  );

  // Mutation 2: revert Is Voice Note? back to hardcoded messages[0]
  assert.throws(
    () => {
      const m = clone();
      const n = m.nodes.find((n) => n.name === 'Is Voice Note?');
      n.parameters.conditions.conditions[0].leftValue =
        '={{ Boolean($json.result?.ok === true && $json.result.messages[0]) }}';
      validateStructure(m, 'mutation-is-voice-note');
    },
    /Is Voice Note\? must inspect messages\.some/,
    'Mutation 2 (reverted messages[0] in Is Voice Note?) must be rejected'
  );

  // Mutation 3: revert Get Audio URL back to hardcoded messages[0]
  assert.throws(
    () => {
      const m = clone();
      const n = m.nodes.find((n) => n.name === 'Get Audio URL');
      n.parameters.url = '=https://graph.facebook.com/v21.0/{{ $json.result.messages[0].payload.audio?.id }}';
      validateStructure(m, 'mutation-get-audio-url');
    },
    /Get Audio URL must resolve the actionable voice message/,
    'Mutation 3 (reverted messages[0] in Get Audio URL) must be rejected'
  );

  // Mutation 4: revert Download Voice back to hardcoded messages[0]
  assert.throws(
    () => {
      const m = clone();
      const n = m.nodes.find((n) => n.name === 'Download Voice');
      n.parameters.url = "={{ $('Verify & Save Event').first().json.result.messages[0].payload.audio?.url }}";
      validateStructure(m, 'mutation-download-voice');
    },
    /Download Voice must resolve the actionable voice message/,
    'Mutation 4 (reverted messages[0] in Download Voice) must be rejected'
  );

  // Mutation 5: revert Transcribe Voice prompt back to messages?.[0]
  assert.throws(
    () => {
      const m = clone();
      const n = m.nodes.find((n) => n.name === 'Transcribe Voice');
      const p = n.parameters.bodyParameters.parameters.find((x) => x.name === 'prompt');
      p.value = "={{ (() => { const ev = $('Verify & Save Event').first().json.result?.messages?.[0] ?? {}; return ev; })() }}";
      validateStructure(m, 'mutation-transcribe-voice');
    },
    /Transcribe Voice prompt must resolve the actionable voice message/,
    'Mutation 5 (reverted messages?.[0] in Transcribe Voice) must be rejected'
  );

  // Mutation 6: pass incompatible 3rd parameter ($3) in Save & Inject Transcript query
  assert.throws(
    () => {
      const m = clone();
      const n = m.nodes.find((n) => n.name === 'Save & Inject Transcript');
      n.parameters.query = 'SELECT public.apply_voice_transcription($1::jsonb, $2::text, $3::uuid) AS result;';
      validateStructure(m, 'mutation-save-tx-3arg');
    },
    /Save & Inject Transcript must keep the 2-parameter call/,
    'Mutation 6 (3-arg apply_voice_transcription before DB sync) must be rejected'
  );

  // Mutation 7: revert Save & Inject Transcript queryReplacement to skip msgs.findIndex
  assert.throws(
    () => {
      const m = clone();
      const n = m.nodes.find((n) => n.name === 'Save & Inject Transcript');
      n.parameters.options.queryReplacement =
        "={{ [JSON.stringify($('Verify & Save Event').first().json.result), String($json.text ?? '')] }}";
      validateStructure(m, 'mutation-save-tx-no-findindex');
    },
    /Save & Inject Transcript queryReplacement must locate the actionable voice item via msgs\.findIndex/,
    'Mutation 7 (reverted queryReplacement in Save & Inject Transcript) must be rejected'
  );

  return 7;
}

function validateDashboardApiContract(origWf, dashWf, opts = {}) {
  assert.strictEqual(
    dashWf.name,
    'ClinicOS Dashboard API',
    `Dashboard API workflow name must be "ClinicOS Dashboard API", got ${JSON.stringify(dashWf.name)}`
  );

  for (const n of dashWf.nodes || []) {
    assert.ok(!n.disabled, `Node "${n.name}" in Dashboard API workflow must not have disabled: true`);
    assert.ok(!n.continueOnFail, `Node "${n.name}" in Dashboard API workflow must not set continueOnFail: true`);
    assert.ok(
      n.onError === undefined || n.onError === 'stopWorkflow',
      `Node "${n.name}" in Dashboard API workflow must fail closed (got onError: ${JSON.stringify(n.onError)})`
    );
    assert.notStrictEqual(
      n.type,
      'n8n-nodes-base.httpRequest',
      `Dashboard API workflow must not contain any HTTP Request node (found "${n.name}")`
    );
  }

  // Webhook trigger checks: GET + headerAuth + placeholder credential + no embedded secrets
  const webhooks = (dashWf.nodes || []).filter((n) => n.type === 'n8n-nodes-base.webhook');
  assert.strictEqual(webhooks.length, 1, 'Dashboard API workflow must have exactly 1 Webhook node');
  const wh = webhooks[0];
  assert.strictEqual(wh.parameters?.httpMethod, 'GET', 'Dashboard Webhook must use httpMethod: "GET"');
  assert.strictEqual(
    wh.parameters?.authentication,
    'headerAuth',
    `Dashboard Webhook must enforce authentication: "headerAuth", got ${JSON.stringify(wh.parameters?.authentication)}`
  );
  assert.strictEqual(
    wh.parameters?.responseMode,
    'responseNode',
    'Dashboard Webhook must use responseMode: "responseNode"'
  );
  assert.strictEqual(
    wh.credentials?.httpHeaderAuth?.id,
    'YOUR_DASHBOARD_HEADER_AUTH_CREDENTIAL_ID',
    'Dashboard Webhook must bind httpHeaderAuth credential placeholder YOUR_DASHBOARD_HEADER_AUTH_CREDENTIAL_ID'
  );

  const rawJson = JSON.stringify(dashWf);
  assert.ok(
    !/x-dashboard-token["']?\s*:\s*["'][^Y{][^"']+["']/i.test(rawJson) &&
      !/Bearer\s+[A-Za-z0-9._-]{8,}/i.test(rawJson),
    'Dashboard API workflow must never embed a literal token or secret'
  );

  // Postgres query check
  const pgNode = (dashWf.nodes || []).find((n) => n.name === 'Fetch Dashboard Data');
  assert.ok(pgNode, 'Dashboard API workflow must contain "Fetch Dashboard Data" Postgres node');
  assert.strictEqual(pgNode.type, 'n8n-nodes-base.postgres');
  assert.strictEqual(pgNode.parameters?.operation, 'executeQuery');
  assert.strictEqual(pgNode.parameters?.options?.queryBatching, 'single');
  assert.strictEqual(pgNode.credentials?.postgres?.id, 'YOUR_POSTGRES_CREDENTIAL_ID');
  assert.strictEqual(
    String(pgNode.parameters?.query ?? '').replace(/\r\n/g, '\n').trim(),
    DASHBOARD_API_QUERY.trim(),
    'Fetch Dashboard Data query must match DASHBOARD_API_QUERY (l2v.kpi_daily + l2v.recent_leads max 50)'
  );

  // Functional fail-closed date validation check on Validate Query Params
  const valNode = (dashWf.nodes || []).find((n) => n.name === 'Validate Query Params');
  assert.ok(valNode && valNode.type === 'n8n-nodes-base.code', 'Missing Validate Query Params Code node');
  const runValidate = new Function('$json', valNode.parameters.jsCode);
  assert.strictEqual(runValidate({ query: { from: '2026-01-01', to: '2026-03-31' } }).json.valid, true, '90-day range must be valid');
  assert.strictEqual(
    runValidate({ query: { from: '2026-01-01', to: '2026-04-01' } }).json.valid,
    false,
    'Dashboard API must reject date ranges > 90 days (91 days must fail closed)'
  );
  assert.strictEqual(runValidate({ query: {} }).json.valid, false, 'Missing query params must fail closed');
  assert.strictEqual(runValidate({ query: { from: '2026-02-30', to: '2026-03-01' } }).json.valid, false, 'Impossible calendar date must fail closed');
  assert.strictEqual(runValidate({ query: { from: '2026-05-10', to: '2026-05-01' } }).json.valid, false, 'Reversed date range must fail closed');

  // Functional phone-masking check on Format Dashboard Response (all digits masked except last 3)
  const fmtNode = (dashWf.nodes || []).find((n) => n.name === 'Format Dashboard Response');
  assert.ok(fmtNode && fmtNode.type === 'n8n-nodes-base.code', 'Missing Format Dashboard Response Code node');
  const runFormat = new Function('$json', '$', '$itemIndex', fmtNode.parameters.jsCode);
  const lookupValidate = (name) => {
    if (name === 'Validate Query Params') return { item: { json: { from: '2026-11-01', to: '2026-11-17' } } };
    throw new Error('Unexpected lookup: ' + name);
  };
  const formatted = runFormat(
    {
      clinic_count: 1,
      kpi_daily: [{ day: '2026-11-17', leads: 2, hot_leads: 1, avg_first_reply_s: 5, escalations: 0, booked_leads: 1, visits: 1, no_shows: 0 }],
      leads: [
        { lead_id: 'l1', phone_masked: '+201001234567', status: 'hot', source: 'click_to_whatsapp', score: 85 },
        { lead_id: 'l2', phone_masked: '+*********890', status: 'warm', source: 'organic', score: 40 },
        { lead_id: 'l3', phone_masked: '12', status: 'cold', source: 'organic', score: 15 },
      ],
    },
    lookupValidate,
    0
  ).json;

  assert.strictEqual(
    formatted.leads[0].phone_masked,
    '+*********567',
    `Dashboard API must mask phone numbers (all digits except last 3), got ${JSON.stringify(formatted.leads[0].phone_masked)}`
  );
  assert.strictEqual(
    formatted.leads[1].phone_masked,
    '+*********890',
    `Dashboard API must preserve already-masked phone numbers, got ${JSON.stringify(formatted.leads[1].phone_masked)}`
  );
  assert.strictEqual(
    formatted.leads[2].phone_masked,
    '***',
    `Dashboard API must fully mask <=3-digit phone values, got ${JSON.stringify(formatted.leads[2].phone_masked)}`
  );

  // Error Trigger -> Log Workflow Error must match main workflow
  const origErrorTrigger = origWf.nodes.find((n) => n.name === 'Error Trigger');
  const origLogError = origWf.nodes.find((n) => n.name === 'Log Workflow Error');
  const dashErrorTrigger = dashWf.nodes.find((n) => n.name === 'Error Trigger');
  const dashLogError = dashWf.nodes.find((n) => n.name === 'Log Workflow Error');
  assert.ok(dashErrorTrigger && dashLogError, 'Dashboard API must include Error Trigger -> Log Workflow Error');
  assert.strictEqual(JSON.stringify(dashErrorTrigger), JSON.stringify(origErrorTrigger), 'Error Trigger must match main workflow');
  assert.strictEqual(JSON.stringify(dashLogError), JSON.stringify(origLogError), 'Log Workflow Error must match main workflow');
  assert.deepStrictEqual(
    dashWf.connections['Error Trigger'],
    { main: [[{ node: 'Log Workflow Error', type: 'main', index: 0 }]] },
    'Error Trigger must connect to Log Workflow Error'
  );

  if (!opts.skipSourceSync) {
    validateStructure(dashWf, 'workflow/clinicos-dashboard-api.json');
  }
}

function runDashboardApiMutationTests(origWf, dashWf) {
  const clone = () => JSON.parse(JSON.stringify(dashWf));

  // Mutation 1: header auth removed
  assert.throws(
    () => {
      const m = clone();
      const wh = m.nodes.find((n) => n.name === 'Dashboard Webhook');
      wh.parameters.authentication = 'none';
      delete wh.credentials;
      validateDashboardApiContract(origWf, m);
    },
    /Dashboard Webhook must enforce authentication: "headerAuth"/,
    'Dashboard Mutation 1 (header auth removed) must be rejected'
  );

  // Mutation 2: Postgres query changed
  assert.throws(
    () => {
      const m = clone();
      const pg = m.nodes.find((n) => n.name === 'Fetch Dashboard Data');
      pg.parameters.query = 'SELECT * FROM l2v.leads LIMIT 50;';
      validateDashboardApiContract(origWf, m);
    },
    /Fetch Dashboard Data query must match DASHBOARD_API_QUERY/,
    'Dashboard Mutation 2 (query changed) must be rejected'
  );

  // Mutation 3: extra HTTP Request node added
  assert.throws(
    () => {
      const m = clone();
      m.nodes.push({
        parameters: { url: 'https://example.com/leak' },
        id: 'c1b2c3d4-9999-4000-8000-000000000099',
        name: 'Extra HTTP Node',
        type: 'n8n-nodes-base.httpRequest',
        typeVersion: 4.2,
        position: [1600, 160],
      });
      m.connections['Respond Dashboard JSON'] = { main: [[{ node: 'Extra HTTP Node', type: 'main', index: 0 }]] };
      validateDashboardApiContract(origWf, m);
    },
    /must not contain any HTTP Request node/,
    'Dashboard Mutation 3 (extra HTTP node) must be rejected'
  );

  // Mutation 4: disabled node
  assert.throws(
    () => {
      const m = clone();
      const val = m.nodes.find((n) => n.name === 'Validate Query Params');
      val.disabled = true;
      validateDashboardApiContract(origWf, m);
    },
    /must not have disabled: true/,
    'Dashboard Mutation 4 (disabled node) must be rejected'
  );

  // Mutation 5: onError continue (fails open instead of failing closed)
  assert.throws(
    () => {
      const m = clone();
      const pg = m.nodes.find((n) => n.name === 'Fetch Dashboard Data');
      pg.onError = 'continueRegularOutput';
      validateDashboardApiContract(origWf, m);
    },
    /must fail closed/,
    'Dashboard Mutation 5 (onError continue) must be rejected'
  );

  // Mutation 6: phone not masked in Format Dashboard Response
  assert.throws(
    () => {
      const m = clone();
      const fmt = m.nodes.find((n) => n.name === 'Format Dashboard Response');
      fmt.parameters.jsCode = fmt.parameters.jsCode.replace(
        'return "+" + "*".repeat(digits.length - 3) + digits.slice(-3);',
        'return "+" + digits;'
      );
      validateDashboardApiContract(origWf, m, { skipSourceSync: true });
    },
    /Dashboard API must mask phone numbers/,
    'Dashboard Mutation 6 (phone not masked) must be rejected'
  );

  // Mutation 7: non-placeholder headerAuth credential id
  assert.throws(
    () => {
      const m = clone();
      const wh = m.nodes.find((n) => n.name === 'Dashboard Webhook');
      wh.credentials.httpHeaderAuth.id = 'real-dashboard-cred-99';
      validateDashboardApiContract(origWf, m);
    },
    /YOUR_DASHBOARD_HEADER_AUTH_CREDENTIAL_ID|YOUR_\*_CREDENTIAL_ID/,
    'Dashboard Mutation 7 (non-placeholder headerAuth credential) must be rejected'
  );

  // Mutation 8: >90-day range accepted instead of failing closed
  assert.throws(
    () => {
      const m = clone();
      const val = m.nodes.find((n) => n.name === 'Validate Query Params');
      val.parameters.jsCode = val.parameters.jsCode.replace('inclusiveDays > 90', 'inclusiveDays > 365');
      validateDashboardApiContract(origWf, m, { skipSourceSync: true });
    },
    /Dashboard API must reject date ranges > 90 days/,
    'Dashboard Mutation 8 (>90-day range accepted) must be rejected'
  );

  return 8;
}

function main() {
  const args = process.argv.slice(2);
  const defaultTargets = [
    ORIG_WF_PATH,
    L2V_WF_PATH,
    SLA_WF_PATH,
    ...(fs.existsSync(DASH_WF_PATH) ? [DASH_WF_PATH] : []),
  ];
  const extraDefaults = [SLA_WF_PATH, DASH_WF_PATH].filter(
    (wfPath) =>
      fs.existsSync(wfPath) &&
      !args.some((p) => path.resolve(process.cwd(), p) === path.resolve(wfPath))
  );
  const targets =
    args.length > 0
      ? [...args.map((p) => path.resolve(process.cwd(), p)), ...extraDefaults]
      : defaultTargets;

  const origWf = validateStructure(ORIG_WF_PATH);
  runMainWorkflowAuditMutationTests(origWf);
  for (const t of targets) {
    const wf = validateStructure(t);
    if (path.resolve(t) === path.resolve(L2V_WF_PATH)) {
      validateL2vAddonContract(origWf, wf);
      runMainWorkflowAuditMutationTests(wf);
    } else if (path.resolve(t) === path.resolve(SLA_WF_PATH)) {
      validateSlaTickContract(origWf, wf);
      runSlaTickMutationTests(origWf, wf);
    } else if (path.resolve(t) === path.resolve(DASH_WF_PATH)) {
      validateDashboardApiContract(origWf, wf);
      runDashboardApiMutationTests(origWf, wf);
    }
    console.log(`Workflow valid: ${path.relative(REPO_ROOT, t)} (${wf.nodes.length} nodes)`);
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  validateStructure,
  validateL2vAddonContract,
  validateSlaTickContract,
  validateDashboardApiContract,
  runSlaTickMutationTests,
  runMainWorkflowAuditMutationTests,
  runDashboardApiMutationTests,
};
