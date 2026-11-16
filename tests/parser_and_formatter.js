// Node code for ClinicOS lives in nodes/*.js; this module exposes it to the tests and the workflow builder.
const fs = require('fs');
const path = require('path');
const readNode = (name) => fs.readFileSync(path.join(__dirname, '..', 'nodes', name), 'utf8');

const PARSE_AI_OUTPUT_JS = readNode('parse_ai_output.js');
const FORMAT_SLOT_LIST_JS = readNode('format_slot_list.js');

module.exports = {
  PARSE_AI_OUTPUT_JS,
  FORMAT_SLOT_LIST_JS,
};
