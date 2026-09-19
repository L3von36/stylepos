#!/usr/bin/env bash
# Types text into the currently focused Flutter-web text field by dispatching
# synthetic KeyboardEvent/InputEvent pairs (Flutter web reads `input` events
# on its hidden <input>/<textarea>). Runs through agent-browser eval.
# Usage: type_keys.sh "some text"
set -euo pipefail
TEXT="${1:-}"
agent-browser eval "(() => {
  const el = document.activeElement &&
             (document.activeElement.tagName === 'INPUT' ||
              document.activeElement.tagName === 'TEXTAREA')
    ? document.activeElement : null;
  if (!el) return 'no focused input';
  const text = ${TEXT@Q};
  for (const ch of text) {
    const v = el.value + ch;
    el.value = v;
    const ev = new InputEvent('input', { bubbles: true, data: ch, inputType: 'insertText' });
    el.dispatchEvent(ev);
  }
  return 'typed';
})()"
