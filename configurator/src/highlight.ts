// DOM-based syntax highlighting — no innerHTML, so user-supplied paths
// cannot introduce script injection through the generated output.

// Line-number gutter. Was #3b4155 which failed WCAG AA at ~1.8:1 against
// the editor's #0d131d background — line numbers are text (users reference
// them when pointing at specific lines in the output), so they need 4.5:1.
// #707ea6 gives ~4.6:1 while still reading as de-emphasized gutter metadata.
const GUTTER_STYLE =
  'color:#707ea6;user-select:none;text-align:right;padding-right:1.5em;vertical-align:top;white-space:nowrap;width:1%;';

// Builds the <table>/<tbody> scaffolding shared by both highlighters and
// hands back a callback that appends a new row (numbered gutter + empty
// code cell) per line. Each highlighter populates the code cell.
function codeTable(
  lines: readonly string[],
  container: HTMLElement,
): (visit: (tdCode: HTMLTableCellElement, line: string, index: number) => void) => void {
  container.textContent = '';
  const table = document.createElement('table');
  table.style.cssText = 'border-collapse:collapse;width:100%';
  const tbody = document.createElement('tbody');
  table.appendChild(tbody);
  container.appendChild(table);

  return (visit) => {
    lines.forEach((line, i) => {
      const tr = document.createElement('tr');

      const tdNum = document.createElement('td');
      tdNum.style.cssText = GUTTER_STYLE;
      tdNum.textContent = String(i + 1);
      tr.appendChild(tdNum);

      const tdCode = document.createElement('td');
      tdCode.style.cssText = 'white-space:pre;';
      tr.appendChild(tdCode);
      tbody.appendChild(tr);

      visit(tdCode, line, i);
    });
  };
}

export function highlightYaml(lines: readonly string[], container: HTMLElement): void {
  codeTable(lines, container)((tdCode, line) => {

    const trimmed = line.trimStart();
    const indent = line.length - trimmed.length;
    const indentStr = line.substring(0, indent);

    if (trimmed.startsWith('#')) {
      const cs = document.createElement('span');
      cs.className = 'hl-comment';
      cs.textContent = line;
      tdCode.appendChild(cs);
    } else if (trimmed.startsWith('- ')) {
      const valText = trimmed.substring(2);
      tdCode.appendChild(document.createTextNode(indentStr));
      const dash = document.createElement('span');
      dash.className = 'hl-punct';
      dash.textContent = '- ';
      tdCode.appendChild(dash);
      const val = document.createElement('span');
      val.className = 'hl-string';
      val.textContent = valText;
      tdCode.appendChild(val);
    } else if (trimmed.indexOf(':') > 0) {
      const colonIdx = trimmed.indexOf(':');
      const key = trimmed.substring(0, colonIdx);
      const rest = trimmed.substring(colonIdx + 1);

      tdCode.appendChild(document.createTextNode(indentStr));
      const keySpan = document.createElement('span');
      keySpan.className = 'hl-key';
      keySpan.textContent = key;
      tdCode.appendChild(keySpan);
      const colonSpan = document.createElement('span');
      colonSpan.className = 'hl-punct';
      colonSpan.textContent = ':';
      tdCode.appendChild(colonSpan);

      if (rest.trim()) {
        const valSpan = document.createElement('span');
        if (/^\s*\d+[a-z]*\s*$/.test(rest)) {
          valSpan.className = 'hl-number';
        } else if (/^\s*(true|false|yes|no)\s*$/i.test(rest)) {
          valSpan.className = 'hl-keyword';
        } else {
          valSpan.className = 'hl-string';
        }
        valSpan.textContent = ' ' + rest.trim();
        tdCode.appendChild(valSpan);
      }
    } else {
      tdCode.appendChild(document.createTextNode(line));
    }
  });
}

export function highlightShell(lines: readonly string[], container: HTMLElement): void {
  // Output may contain multiple command blocks separated by blank lines.
  // Each block's first line is a command; subsequent lines are flags until
  // one that doesn't end with a backslash (terminal line, e.g. image name).
  let expectCommand = true;

  codeTable(lines, container)((tdCode, line) => {
    const trimmed = line.trim();

    if (trimmed === '') {
      tdCode.appendChild(document.createTextNode(' '));
      expectCommand = true;
    } else if (expectCommand) {
      const cmdParts = trimmed.split(/\s+/);
      const cmdSpan = document.createElement('span');
      cmdSpan.className = 'hl-cmd';
      cmdSpan.textContent = cmdParts[0] ?? '';
      tdCode.appendChild(cmdSpan);
      for (let k = 1; k < cmdParts.length; k++) {
        tdCode.appendChild(document.createTextNode(' '));
        const fs = document.createElement('span');
        const part = cmdParts[k] ?? '';
        if (part === '\\') {
          fs.className = 'hl-punct';
        } else if (k === 1) {
          fs.className = 'hl-key';
        } else {
          fs.className = 'hl-flag';
        }
        fs.textContent = part;
        tdCode.appendChild(fs);
      }
      expectCommand = !trimmed.endsWith('\\');
    } else if (!trimmed.endsWith('\\')) {
      const indentImg = line.length - line.trimStart().length;
      tdCode.appendChild(document.createTextNode(line.substring(0, indentImg)));
      const imgSpan = document.createElement('span');
      imgSpan.className = 'hl-string';
      imgSpan.textContent = trimmed;
      tdCode.appendChild(imgSpan);
      expectCommand = true;
    } else {
      const indentFlag = line.length - line.trimStart().length;
      tdCode.appendChild(document.createTextNode(line.substring(0, indentFlag)));

      const withoutBackslash = trimmed.replace(/ \\$/, '');
      const flagMatch = withoutBackslash.match(/^(--?[\w-]+)\s*(.*)/);
      if (flagMatch) {
        const fSpan = document.createElement('span');
        fSpan.className = 'hl-flag';
        fSpan.textContent = flagMatch[1] ?? '';
        tdCode.appendChild(fSpan);
        if (flagMatch[2]) {
          tdCode.appendChild(document.createTextNode(' '));
          const vSpan = document.createElement('span');
          vSpan.className = 'hl-string';
          vSpan.textContent = flagMatch[2];
          tdCode.appendChild(vSpan);
        }
      } else {
        tdCode.appendChild(document.createTextNode(withoutBackslash));
      }

      tdCode.appendChild(document.createTextNode(' '));
      const bs = document.createElement('span');
      bs.className = 'hl-punct';
      bs.textContent = '\\';
      tdCode.appendChild(bs);
    }
  });
}
