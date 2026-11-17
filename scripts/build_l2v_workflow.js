#!/usr/bin/env node
// Deterministic builder for workflow/clinicos-main-engine.l2v.json (Task T5).
// Syncs workflow/clinicos-main-engine.json from nodes/*.js and prompts/receptionist-system-prompt.xml,
// inserts only the 6 L2V add-on nodes, rewires Parse Turn & State -> L2V Prepare..Is Staff? -> Route Turn,
// adds the L2V Qualify? side branch from Emergency Reply Guard, and sets Reminder & Outbox Timer to 1 minute.

const fs = require('fs');
const path = require('path');
const { syncWorkflowFile, syncWorkflowNodeCode } = require('./sync_node_code.js');

const REPO_ROOT = path.resolve(__dirname, '..');
const SRC_WORKFLOW_PATH = path.join(REPO_ROOT, 'workflow', 'clinicos-main-engine.json');
const DST_WORKFLOW_PATH = path.join(REPO_ROOT, 'workflow', 'clinicos-main-engine.l2v.json');
const L2V_PREPARE_NODE_PATH = path.join(REPO_ROOT, 'nodes', 'l2v_prepare.js');

const L2V_GATE_QUERY = [
  'WITH s AS (SELECT l2v.is_staff($1::uuid, $2::text) AS is_staff)',
  'SELECT s.is_staff,',
  '  CASE WHEN s.is_staff',
  '    THEN (SELECT to_jsonb(a) FROM l2v.rep_ack($1::uuid, $2::text) a)',
  '    ELSE (SELECT to_jsonb(c) FROM l2v.capture_lead_guarded($1::uuid, $3::uuid, $4::text, $5::text, $6::jsonb, $7::timestamptz) c)',
  '  END AS l2v',
  'FROM s;',
].join('\n');

const L2V_MERGE_JS_CODE = [
  '// Fail-open merge: preserve the matching Parse Turn & State item by itemIndex',
  '// and mark l2v_is_staff = true only when L2V Gate explicitly returned is_staff === true without error.',
  'let turn = null;',
  'try {',
  "  turn = $('Parse Turn & State').item?.json ?? null;",
  '} catch {',
  '  turn = null;',
  '}',
  'if (!turn || typeof turn !== "object" || Array.isArray(turn) || Object.keys(turn).length === 0) {',
  '  try {',
  '    const idx = typeof $itemIndex === "number" ? $itemIndex : 0;',
  "    turn = $('Parse Turn & State').all()?.[idx]?.json ?? null;",
  '  } catch {',
  '    turn = null;',
  '  }',
  '}',
  'if (!turn || typeof turn !== "object" || Array.isArray(turn) || Object.keys(turn).length === 0) {',
  '  return { json: { l2v_is_staff: false } };',
  '}',
  'const gate = typeof $json !== "undefined" && $json && typeof $json === "object" ? $json : {};',
  'const isStaff = !gate.error && gate.is_staff === true;',
  'return {',
  '  json: {',
  '    ...turn,',
  '    l2v_is_staff: isStaff,',
  '  },',
  '};',
].join('\n');

const L2V_QUALIFY_QUERY = 'SELECT * FROM l2v.qualify_contact($1::uuid, $2::uuid, $3, $4, $5);';

function buildL2vWorkflow() {
  // Ensure the base workflow is synced with nodes/*.js and prompts/receptionist-system-prompt.xml first
  syncWorkflowFile(SRC_WORKFLOW_PATH);

  const rawWf = fs.readFileSync(SRC_WORKFLOW_PATH, 'utf8');
  const wf = JSON.parse(rawWf);
  const prepareJs = fs.readFileSync(L2V_PREPARE_NODE_PATH, 'utf8').replace(/\r\n/g, '\n');

  const refPgNode = wf.nodes.find((n) => n.name === 'Load Clinic Context');
  if (!refPgNode) {
    throw new Error('Reference Postgres node "Load Clinic Context" not found');
  }
  const pgCredentials = JSON.parse(JSON.stringify(refPgNode.credentials));
  const pgTypeVersion = refPgNode.typeVersion;

  // Update only Reminder & Outbox Timer interval to 1 minute among existing nodes
  const timerNode = wf.nodes.find((n) => n.name === 'Reminder & Outbox Timer');
  if (!timerNode) {
    throw new Error('Node "Reminder & Outbox Timer" not found');
  }
  timerNode.parameters.rule.interval = [
    {
      field: 'minutes',
      minutesInterval: 1,
    },
  ];

  const newNodes = [
    {
      parameters: {
        mode: 'runOnceForEachItem',
        jsCode: prepareJs,
      },
      id: 'a1b2c3d4-0001-4000-8000-000000000001',
      name: 'L2V Prepare',
      type: 'n8n-nodes-base.code',
      typeVersion: 2,
      position: [1392, 304],
    },
    {
      parameters: {
        operation: 'executeQuery',
        options: {
          queryBatching: 'single',
          queryReplacement:
            '={{ [$json.clinic_id, $json.phone_e164, $json.contact_id, $json.source, $json.campaign ?? null, $json.referral ? JSON.stringify($json.referral) : null, $json.message_timestamp ?? null] }}',
        },
        query: L2V_GATE_QUERY,
      },
      id: 'a1b2c3d4-0002-4000-8000-000000000002',
      name: 'L2V Gate',
      type: 'n8n-nodes-base.postgres',
      typeVersion: pgTypeVersion,
      position: [1440, 304],
      retryOnFail: true,
      maxTries: 3,
      waitBetweenTries: 1000,
      onError: 'continueRegularOutput',
      credentials: pgCredentials,
    },
    {
      parameters: {
        mode: 'runOnceForEachItem',
        jsCode: L2V_MERGE_JS_CODE,
      },
      id: 'a1b2c3d4-0003-4000-8000-000000000003',
      name: 'L2V Merge',
      type: 'n8n-nodes-base.code',
      typeVersion: 2,
      position: [1488, 304],
    },
    {
      parameters: {
        conditions: {
          options: {
            caseSensitive: true,
            leftValue: '',
            typeValidation: 'strict',
            version: 1,
          },
          conditions: [
            {
              leftValue: '={{ $json.l2v_is_staff === true }}',
              rightValue: true,
              operator: {
                type: 'boolean',
                operation: 'equals',
              },
            },
          ],
          combinator: 'and',
        },
        options: {},
      },
      id: 'a1b2c3d4-0004-4000-8000-000000000004',
      name: 'Is Staff?',
      type: 'n8n-nodes-base.if',
      typeVersion: 2.4,
      position: [1536, 304],
    },
    {
      parameters: {
        conditions: {
          options: {
            caseSensitive: true,
            leftValue: '',
            typeValidation: 'strict',
            version: 1,
          },
          conditions: [
            {
              leftValue: '={{ Boolean($json.lead_timing || $json.lead_budget_band) }}',
              rightValue: true,
              operator: {
                type: 'boolean',
                operation: 'equals',
              },
            },
          ],
          combinator: 'and',
        },
        options: {},
      },
      id: 'a1b2c3d4-0005-4000-8000-000000000005',
      name: 'L2V Qualify?',
      type: 'n8n-nodes-base.if',
      typeVersion: 2.4,
      position: [2624, 640],
    },
    {
      parameters: {
        operation: 'executeQuery',
        options: {
          queryBatching: 'single',
          queryReplacement:
            '={{ [$json.clinic_id, $json.contact_id, $json.lead_budget_band ?? null, $json.lead_timing ?? null, $json.service_name_ar ?? null] }}',
        },
        query: L2V_QUALIFY_QUERY,
      },
      id: 'a1b2c3d4-0006-4000-8000-000000000006',
      name: 'L2V Qualify',
      type: 'n8n-nodes-base.postgres',
      typeVersion: pgTypeVersion,
      position: [2848, 640],
      retryOnFail: true,
      maxTries: 3,
      waitBetweenTries: 1000,
      onError: 'continueRegularOutput',
      credentials: JSON.parse(JSON.stringify(pgCredentials)),
    },
  ];

  wf.nodes.push(...newNodes);
  syncWorkflowNodeCode(wf);
  if (typeof wf.nodeCount === 'number') {
    wf.nodeCount = wf.nodes.length;
  }

  // Rewire Parse Turn & State -> L2V Prepare -> L2V Gate -> L2V Merge -> Is Staff? (false -> Route Turn)
  wf.connections['Parse Turn & State'] = {
    main: [[{ node: 'L2V Prepare', type: 'main', index: 0 }]],
  };
  wf.connections['L2V Prepare'] = {
    main: [[{ node: 'L2V Gate', type: 'main', index: 0 }]],
  };
  wf.connections['L2V Gate'] = {
    main: [[{ node: 'L2V Merge', type: 'main', index: 0 }]],
  };
  wf.connections['L2V Merge'] = {
    main: [[{ node: 'Is Staff?', type: 'main', index: 0 }]],
  };
  wf.connections['Is Staff?'] = {
    main: [[], [{ node: 'Route Turn', type: 'main', index: 0 }]],
  };

  // Add side branch from Emergency Reply Guard -> L2V Qualify? -> L2V Qualify
  const ergConn = wf.connections['Emergency Reply Guard'];
  if (!ergConn || !Array.isArray(ergConn.main) || !Array.isArray(ergConn.main[0])) {
    throw new Error('Unexpected connection structure on "Emergency Reply Guard"');
  }
  ergConn.main[0] = [
    ...ergConn.main[0].filter((c) => c.node !== 'L2V Qualify?'),
    { node: 'L2V Qualify?', type: 'main', index: 0 },
  ];
  wf.connections['L2V Qualify?'] = {
    main: [[{ node: 'L2V Qualify', type: 'main', index: 0 }], []],
  };

  fs.writeFileSync(DST_WORKFLOW_PATH, JSON.stringify(wf, null, 2) + '\n', 'utf8');
  console.log(`Built ${path.relative(REPO_ROOT, DST_WORKFLOW_PATH)} (${wf.nodes.length} nodes)`);
}

if (require.main === module) {
  buildL2vWorkflow();
}

module.exports = { buildL2vWorkflow, L2V_GATE_QUERY, L2V_QUALIFY_QUERY };
