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
const SLA_WORKFLOW_PATH = path.join(REPO_ROOT, 'workflow', 'clinicos-l2v-sla-tick.json');
const DASH_WORKFLOW_PATH = path.join(REPO_ROOT, 'workflow', 'clinicos-dashboard-api.json');
const L2V_PREPARE_NODE_PATH = path.join(REPO_ROOT, 'nodes', 'l2v_prepare.js');
const DASH_VALIDATE_NODE_PATH = path.join(REPO_ROOT, 'nodes', 'dashboard_validate_query.js');
const DASH_FORMAT_NODE_PATH = path.join(REPO_ROOT, 'nodes', 'dashboard_format_response.js');

const L2V_ESCALATE_QUERY = 'SELECT l2v.release_overnight() AS released, l2v.escalate_overdue() AS escalated;';

const DASHBOARD_API_QUERY = [
  'WITH clinic AS (',
  '  SELECT id, count(*) OVER ()::int AS clinic_cnt',
  '  FROM public.clinics',
  '),',
  'single_clinic AS (',
  '  SELECT id',
  '  FROM clinic',
  '  WHERE clinic_cnt = 1',
  ')',
  'SELECT',
  '  (SELECT count(*)::int FROM public.clinics) AS clinic_count,',
  '  COALESCE(',
  '    (SELECT jsonb_agg(to_jsonb(k) ORDER BY k.day ASC)',
  '     FROM single_clinic sc',
  '     CROSS JOIN LATERAL l2v.kpi_daily(sc.id, $1::date, $2::date) AS k),',
  "    '[]'::jsonb",
  '  ) AS kpi_daily,',
  '  COALESCE(',
  '    (SELECT jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC)',
  '     FROM single_clinic sc',
  '     CROSS JOIN LATERAL l2v.recent_leads(sc.id, 50) AS r),',
  "    '[]'::jsonb",
  '  ) AS leads;',
].join('\n');

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

function writeJsonIfChanged(filePath, obj) {
  const nextLf = JSON.stringify(obj, null, 2) + '\n';
  if (fs.existsSync(filePath)) {
    const prevRaw = fs.readFileSync(filePath, 'utf8');
    const prevLf = prevRaw.replace(/\r\n/g, '\n');
    const prevTrimmed = prevLf.endsWith('\n') ? prevLf : prevLf + '\n';
    if (prevTrimmed === nextLf) {
      return;
    }
    const useCrlf = prevRaw.includes('\r\n');
    fs.writeFileSync(filePath, useCrlf ? nextLf.replace(/\n/g, '\r\n') : nextLf, 'utf8');
    return;
  }
  fs.writeFileSync(filePath, nextLf, 'utf8');
}

function buildL2vWorkflow() {
  // Ensure the base workflow is synced with nodes/*.js and prompts/receptionist-system-prompt.xml first
  const srcRaw = fs.readFileSync(SRC_WORKFLOW_PATH, 'utf8');
  const srcObj = JSON.parse(srcRaw);
  syncWorkflowNodeCode(srcObj);
  if (JSON.stringify(srcObj) !== JSON.stringify(JSON.parse(srcRaw))) {
    syncWorkflowFile(SRC_WORKFLOW_PATH);
  }

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

  writeJsonIfChanged(DST_WORKFLOW_PATH, wf);
  console.log(`Built ${path.relative(REPO_ROOT, DST_WORKFLOW_PATH)} (${wf.nodes.length} nodes)`);
}

function buildSlaTickWorkflow() {
  const rawWf = fs.readFileSync(SRC_WORKFLOW_PATH, 'utf8');
  const srcWf = JSON.parse(rawWf);

  const refPgNode = srcWf.nodes.find((n) => n.name === 'Load Clinic Context');
  if (!refPgNode) {
    throw new Error('Reference Postgres node "Load Clinic Context" not found');
  }
  const errorTriggerNode = srcWf.nodes.find((n) => n.name === 'Error Trigger');
  if (!errorTriggerNode) {
    throw new Error('Node "Error Trigger" not found in main workflow');
  }
  const logErrorNode = srcWf.nodes.find((n) => n.name === 'Log Workflow Error');
  if (!logErrorNode) {
    throw new Error('Node "Log Workflow Error" not found in main workflow');
  }

  const pgCredentials = JSON.parse(JSON.stringify(refPgNode.credentials));
  const pgTypeVersion = refPgNode.typeVersion;

  const nodes = [
    {
      parameters: {
        rule: {
          interval: [
            {
              field: 'minutes',
              minutesInterval: 1,
            },
          ],
        },
      },
      id: 'b1b2c3d4-0001-4000-8000-000000000001',
      name: 'Schedule Trigger',
      type: 'n8n-nodes-base.scheduleTrigger',
      typeVersion: 1.4,
      position: [240, 240],
    },
    {
      parameters: {
        operation: 'executeQuery',
        query: L2V_ESCALATE_QUERY,
        options: {
          queryBatching: 'single',
        },
      },
      id: 'b1b2c3d4-0002-4000-8000-000000000002',
      name: 'Escalate Overdue Leads',
      type: 'n8n-nodes-base.postgres',
      typeVersion: pgTypeVersion,
      position: [480, 240],
      retryOnFail: true,
      maxTries: 3,
      waitBetweenTries: 1000,
      credentials: pgCredentials,
    },
    JSON.parse(JSON.stringify(errorTriggerNode)),
    JSON.parse(JSON.stringify(logErrorNode)),
  ];

  const slaWf = {
    id: 'YOUR_WORKFLOW_ID',
    name: 'ClinicOS L2V SLA Tick',
    active: true,
    isArchived: false,
    versionId: 'YOUR_WORKFLOW_VERSION_ID',
    activeVersionId: 'YOUR_WORKFLOW_VERSION_ID',
    triggerCount: 2,
    nodeCount: nodes.length,
    createdAt: srcWf.createdAt,
    updatedAt: srcWf.updatedAt,
    settings: JSON.parse(JSON.stringify(srcWf.settings)),
    tags: [],
    parentFolderId: null,
    description:
      'ClinicOS Lead-to-Visit SLA tick: runs l2v.release_overnight() and l2v.escalate_overdue() every minute and logs workflow errors.',
    scopes: JSON.parse(JSON.stringify(srcWf.scopes)),
    canExecute: true,
    connections: {
      'Schedule Trigger': {
        main: [
          [
            {
              node: 'Escalate Overdue Leads',
              type: 'main',
              index: 0,
            },
          ],
        ],
      },
      'Error Trigger': {
        main: [
          [
            {
              node: 'Log Workflow Error',
              type: 'main',
              index: 0,
            },
          ],
        ],
      },
    },
    nodes,
    nodeGroups: [],
    activeVersion: {
      sameAsDraft: true,
    },
    meta: JSON.parse(JSON.stringify(srcWf.meta)),
  };

  writeJsonIfChanged(SLA_WORKFLOW_PATH, slaWf);
  console.log(`Built ${path.relative(REPO_ROOT, SLA_WORKFLOW_PATH)} (${slaWf.nodes.length} nodes)`);
}

function buildDashboardApiWorkflow() {
  const rawWf = fs.readFileSync(SRC_WORKFLOW_PATH, 'utf8');
  const srcWf = JSON.parse(rawWf);

  const refPgNode = srcWf.nodes.find((n) => n.name === 'Load Clinic Context');
  if (!refPgNode) {
    throw new Error('Reference Postgres node "Load Clinic Context" not found');
  }
  const errorTriggerNode = srcWf.nodes.find((n) => n.name === 'Error Trigger');
  if (!errorTriggerNode) {
    throw new Error('Node "Error Trigger" not found in main workflow');
  }
  const logErrorNode = srcWf.nodes.find((n) => n.name === 'Log Workflow Error');
  if (!logErrorNode) {
    throw new Error('Node "Log Workflow Error" not found in main workflow');
  }

  const validateJs = fs.readFileSync(DASH_VALIDATE_NODE_PATH, 'utf8').replace(/\r\n/g, '\n');
  const formatJs = fs.readFileSync(DASH_FORMAT_NODE_PATH, 'utf8').replace(/\r\n/g, '\n');
  const pgCredentials = JSON.parse(JSON.stringify(refPgNode.credentials));
  const pgTypeVersion = refPgNode.typeVersion;

  const nodes = [
    {
      parameters: {
        httpMethod: 'GET',
        path: 'clinicos/dashboard',
        authentication: 'headerAuth',
        responseMode: 'responseNode',
        options: {},
      },
      id: 'c1b2c3d4-0001-4000-8000-000000000001',
      name: 'Dashboard Webhook',
      type: 'n8n-nodes-base.webhook',
      typeVersion: 2.2,
      position: [240, 240],
      webhookId: 'YOUR_DASHBOARD_GET_WEBHOOK_ID',
      credentials: {
        httpHeaderAuth: {
          id: 'YOUR_DASHBOARD_HEADER_AUTH_CREDENTIAL_ID',
          name: 'ClinicOS Dashboard Header Auth',
        },
      },
    },
    {
      parameters: {
        mode: 'runOnceForEachItem',
        jsCode: validateJs,
      },
      id: 'c1b2c3d4-0002-4000-8000-000000000002',
      name: 'Validate Query Params',
      type: 'n8n-nodes-base.code',
      typeVersion: 2,
      position: [480, 240],
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
              leftValue: '={{ $json.valid === true }}',
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
      id: 'c1b2c3d4-0003-4000-8000-000000000003',
      name: 'Is Valid Request?',
      type: 'n8n-nodes-base.if',
      typeVersion: 2.4,
      position: [720, 240],
    },
    {
      parameters: {
        operation: 'executeQuery',
        query: DASHBOARD_API_QUERY,
        options: {
          queryBatching: 'single',
          queryReplacement: '={{ [$json.from, $json.to] }}',
        },
      },
      id: 'c1b2c3d4-0004-4000-8000-000000000004',
      name: 'Fetch Dashboard Data',
      type: 'n8n-nodes-base.postgres',
      typeVersion: pgTypeVersion,
      position: [960, 160],
      retryOnFail: true,
      maxTries: 2,
      waitBetweenTries: 1000,
      credentials: pgCredentials,
    },
    {
      parameters: {
        mode: 'runOnceForEachItem',
        jsCode: formatJs,
      },
      id: 'c1b2c3d4-0005-4000-8000-000000000005',
      name: 'Format Dashboard Response',
      type: 'n8n-nodes-base.code',
      typeVersion: 2,
      position: [1200, 160],
    },
    {
      parameters: {
        respondWith: 'json',
        responseBody: '={{ $json }}',
        options: {
          responseCode: 200,
        },
      },
      id: 'c1b2c3d4-0006-4000-8000-000000000006',
      name: 'Respond Dashboard JSON',
      type: 'n8n-nodes-base.respondToWebhook',
      typeVersion: 1.5,
      position: [1440, 160],
    },
    {
      parameters: {
        respondWith: 'json',
        responseBody: "={{ ({ ok: false, error: $json.error || 'bad_request' }) }}",
        options: {
          responseCode: 400,
        },
      },
      id: 'c1b2c3d4-0007-4000-8000-000000000007',
      name: 'Respond Bad Request',
      type: 'n8n-nodes-base.respondToWebhook',
      typeVersion: 1.5,
      position: [960, 360],
    },
    JSON.parse(JSON.stringify(errorTriggerNode)),
    JSON.parse(JSON.stringify(logErrorNode)),
  ];

  const dashWf = {
    id: 'YOUR_WORKFLOW_ID',
    name: 'ClinicOS Dashboard API',
    active: true,
    isArchived: false,
    versionId: 'YOUR_WORKFLOW_VERSION_ID',
    activeVersionId: 'YOUR_WORKFLOW_VERSION_ID',
    triggerCount: 2,
    nodeCount: nodes.length,
    createdAt: srcWf.createdAt,
    updatedAt: srcWf.updatedAt,
    settings: JSON.parse(JSON.stringify(srcWf.settings)),
    tags: [],
    parentFolderId: null,
    description:
      'ClinicOS Dashboard API: header-authenticated GET endpoint returning l2v.kpi_daily (<=90 days) and latest 50 masked leads.',
    scopes: JSON.parse(JSON.stringify(srcWf.scopes)),
    canExecute: true,
    connections: {
      'Dashboard Webhook': {
        main: [[{ node: 'Validate Query Params', type: 'main', index: 0 }]],
      },
      'Validate Query Params': {
        main: [[{ node: 'Is Valid Request?', type: 'main', index: 0 }]],
      },
      'Is Valid Request?': {
        main: [
          [{ node: 'Fetch Dashboard Data', type: 'main', index: 0 }],
          [{ node: 'Respond Bad Request', type: 'main', index: 0 }],
        ],
      },
      'Fetch Dashboard Data': {
        main: [[{ node: 'Format Dashboard Response', type: 'main', index: 0 }]],
      },
      'Format Dashboard Response': {
        main: [[{ node: 'Respond Dashboard JSON', type: 'main', index: 0 }]],
      },
      'Error Trigger': {
        main: [[{ node: 'Log Workflow Error', type: 'main', index: 0 }]],
      },
    },
    nodes,
    nodeGroups: [],
    activeVersion: {
      sameAsDraft: true,
    },
    meta: JSON.parse(JSON.stringify(srcWf.meta)),
  };

  syncWorkflowNodeCode(dashWf);
  writeJsonIfChanged(DASH_WORKFLOW_PATH, dashWf);
  console.log(`Built ${path.relative(REPO_ROOT, DASH_WORKFLOW_PATH)} (${dashWf.nodes.length} nodes)`);
}

if (require.main === module) {
  buildL2vWorkflow();
  buildSlaTickWorkflow();
  buildDashboardApiWorkflow();
}

module.exports = {
  buildL2vWorkflow,
  buildSlaTickWorkflow,
  buildDashboardApiWorkflow,
  L2V_GATE_QUERY,
  L2V_QUALIFY_QUERY,
  L2V_ESCALATE_QUERY,
  DASHBOARD_API_QUERY,
};
