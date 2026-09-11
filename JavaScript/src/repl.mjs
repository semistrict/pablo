import repl from 'node:repl';
import { Pablo } from './index.mjs';

const pablo = await Pablo.connect();
const session = repl.start({ prompt: 'pablo> ' });
function bind() { session.context.pablo = pablo; session.context.Pablo = Pablo; }
bind();
session.on('reset', bind);
