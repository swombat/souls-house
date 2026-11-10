// The inline references chat markdown recognises: commit shas (status badges)
// and conversation IDs (title links). One stable array, so Streamdown is not
// handed a new extensions list per render.
import { commitRefExtension } from './commit-refs.js';
import { conversationRefExtension } from './conversation-refs.js';

export const messageRefExtensions = [commitRefExtension, conversationRefExtension];
