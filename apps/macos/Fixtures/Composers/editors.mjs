import { Editor } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import Placeholder from '@tiptap/extension-placeholder';
import { createEditor } from 'lexical';
import { registerPlainText } from '@lexical/plain-text';

const mount = document.getElementById('editor-mount');
const engine = document.body.dataset.engine;
let field;
if (engine === 'tiptap') {
  const editor = new Editor({
    element: mount,
    extensions: [StarterKit, Placeholder.configure({ placeholder: 'Synthetic composer placeholder' })],
    content: '<p></p>',
    editorProps: { attributes: { id: 'field', role: 'textbox', 'aria-multiline': 'true', spellcheck: 'false' } }
  });
  field = editor.view.dom;
  editor.commands.focus('start');
} else if (engine === 'lexical') {
  field = document.createElement('div');
  field.id = 'field'; field.contentEditable = 'true'; field.spellcheck = false;
  field.setAttribute('role', 'textbox'); field.setAttribute('aria-multiline', 'true');
  mount.append(field);
  const editor = createEditor({
    namespace: 'IntentionSyntheticComposer', onError(error) { throw error; },
    theme: { paragraph: 'paragraph' }
  });
  registerPlainText(editor);
  editor.setRootElement(field);
  editor.focus();
} else { throw new Error('Unknown synthetic composer'); }

// Receipts are independent of Intention and count actual browser input/selection.
let keys = 0;
const caret = () => {
  const selection = getSelection();
  if (!selection.rangeCount || !field.contains(selection.anchorNode)) return -1;
  const range = document.createRange();
  range.selectNodeContents(field); range.setEnd(selection.anchorNode, selection.anchorOffset);
  return range.toString().length;
};
const receipt = () => {
  const length = field.textContent.length;
  field.setAttribute('aria-label', 'Intention fixture keys=' + keys + ' length=' + length + ' caret=' + caret());
  const placeholder = document.getElementById('external-placeholder');
  if (placeholder) placeholder.hidden = length > 0;
};
field.addEventListener('keydown', () => { keys++; receipt(); });
field.addEventListener('keyup', receipt);
field.addEventListener('input', receipt);
document.addEventListener('selectionchange', receipt);
new MutationObserver(receipt).observe(field, { childList: true, subtree: true, characterData: true });
receipt();
