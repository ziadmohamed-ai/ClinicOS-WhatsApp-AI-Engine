#!/usr/bin/env node
// Synchronizes embedded node code and system prompt in ClinicOS workflow JSON files
// from the single source of truth in nodes/*.js and prompts/receptionist-system-prompt.xml.

const fs = require('fs');
const path = require('path');

const REPO_ROOT = path.resolve(__dirname, '..');

function readLf(relPath) {
  return fs.readFileSync(path.join(REPO_ROOT, relPath), 'utf8').replace(/\r\n/g, '\n');
}

function getSourceOfTruthMap() {
  return {
    'Parse AI Output': {
      kind: 'jsCode',
      relPath: 'nodes/parse_ai_output.js',
      expected: readLf('nodes/parse_ai_output.js'),
    },
    'Format Slot List': {
      kind: 'jsCode',
      relPath: 'nodes/format_slot_list.js',
      expected: readLf('nodes/format_slot_list.js'),
    },
    'Parse Turn & State': {
      kind: 'jsCode',
      relPath: 'nodes/parse_turn_and_state.js',
      expected: readLf('nodes/parse_turn_and_state.js'),
    },
    'L2V Prepare': {
      kind: 'jsCode',
      relPath: 'nodes/l2v_prepare.js',
      expected: readLf('nodes/l2v_prepare.js'),
    },
    'Validate Query Params': {
      kind: 'jsCode',
      relPath: 'nodes/dashboard_validate_query.js',
      expected: readLf('nodes/dashboard_validate_query.js'),
    },
    'Format Dashboard Response': {
      kind: 'jsCode',
      relPath: 'nodes/dashboard_format_response.js',
      expected: readLf('nodes/dashboard_format_response.js'),
    },
    'AI Receptionist': {
      kind: 'systemMessage',
      relPath: 'prompts/receptionist-system-prompt.xml',
      expected: '=' + readLf('prompts/receptionist-system-prompt.xml'),
    },
  };
}

function syncWorkflowNodeCode(wf) {
  const map = getSourceOfTruthMap();
  for (const node of wf.nodes || []) {
    const spec = map[node.name];
    if (!spec) continue;
    if (spec.kind === 'jsCode') {
      node.parameters.jsCode = spec.expected;
    } else if (spec.kind === 'systemMessage') {
      if (!node.parameters.options) node.parameters.options = {};
      node.parameters.options.systemMessage = spec.expected;
    }
  }
  return wf;
}

function syncWorkflowFile(wfPath) {
  if (!fs.existsSync(wfPath)) return false;
  const raw = fs.readFileSync(wfPath, 'utf8').replace(/\r\n/g, '\n');
  const trailingNewline = raw.endsWith('\n') ? '\n' : '';
  const wf = JSON.parse(raw);
  syncWorkflowNodeCode(wf);
  fs.writeFileSync(wfPath, JSON.stringify(wf, null, 2) + trailingNewline, 'utf8');
  return true;
}

function syncAllWorkflowFiles() {
  const targets = [
    path.join(REPO_ROOT, 'workflow', 'clinicos-main-engine.json'),
    path.join(REPO_ROOT, 'workflow', 'clinicos-main-engine.l2v.json'),
    path.join(REPO_ROOT, 'workflow', 'clinicos-dashboard-api.json'),
  ];
  for (const t of targets) {
    if (syncWorkflowFile(t)) {
      console.log(`Synced node code in ${path.relative(REPO_ROOT, t)}`);
    }
  }
}

if (require.main === module) {
  syncAllWorkflowFiles();
}

module.exports = {
  getSourceOfTruthMap,
  syncWorkflowNodeCode,
  syncWorkflowFile,
  syncAllWorkflowFiles,
};
