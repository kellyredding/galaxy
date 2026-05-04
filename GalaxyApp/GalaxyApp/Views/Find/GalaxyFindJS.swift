import Foundation

/// JavaScript module that powers Galaxy's Cmd+F find bar.
///
/// Installed once per WKWebView via `WKUserScript` (see
/// `WKWebViewConfiguration+GalaxyFind.installGalaxyFindUserScript`)
/// and exposes `window.GalaxyFind` to Swift, which drives it via
/// `evaluateJavaScript`.
///
/// Match wrapping uses `<mark class="galaxy-find-match">` so it
/// composes cleanly with rendered Markdown's own `<mark>` content
/// — the find spans are styled distinctly from any pre-existing
/// highlights, and `clear()` only removes elements with the
/// galaxy-prefixed class.
///
/// Reverse mode (used by the scrollback overlay) flips the
/// initial cursor position and the next/prev step direction so
/// the first match presented is the most-recent occurrence
/// walking up — matching Terminal.app and iTerm behavior.
enum GalaxyFindJS {
    static let userScriptSource: String = """
    (function() {
      if (window.GalaxyFind) return; // idempotent

      const STYLE_ID = 'galaxy-find-style';
      if (!document.getElementById(STYLE_ID)) {
        const s = document.createElement('style');
        s.id = STYLE_ID;
        s.textContent = `
          mark.galaxy-find-match {
            background: rgba(255, 220, 50, 0.45);
            color: inherit;
            padding: 0;
            border-radius: 1px;
          }
          mark.galaxy-find-current {
            background: rgba(255, 165, 0, 0.85);
            color: #000;
            outline: 1px solid rgba(0,0,0,0.3);
          }
        `;
        (document.head || document.documentElement).appendChild(s);
      }

      // Walk all text nodes under root, skipping script/style and
      // our own <mark> wrappers. Re-applied on every setQuery so
      // existing wrappers are removed by clear() before walking.
      function* textNodes(root) {
        const walker = document.createTreeWalker(
          root, NodeFilter.SHOW_TEXT,
          {
            acceptNode(n) {
              const p = n.parentElement;
              if (!p) return NodeFilter.FILTER_REJECT;
              const tag = p.tagName;
              if (tag === 'SCRIPT' || tag === 'STYLE') {
                return NodeFilter.FILTER_REJECT;
              }
              if (p.classList &&
                  p.classList.contains('galaxy-find-match')) {
                return NodeFilter.FILTER_REJECT;
              }
              return n.nodeValue
                ? NodeFilter.FILTER_ACCEPT
                : NodeFilter.FILTER_REJECT;
            }
          }
        );
        let n;
        while ((n = walker.nextNode())) yield n;
      }

      let matches = []; // array of <mark> elements
      let currentIdx = -1;
      let currentQuery = '';
      let reverseMode = false;

      function clear() {
        // Replace each <mark> with its text and merge siblings.
        const marks = document.querySelectorAll(
          'mark.galaxy-find-match'
        );
        marks.forEach(m => {
          const t = document.createTextNode(m.textContent);
          m.parentNode.replaceChild(t, m);
          if (t.parentNode) t.parentNode.normalize();
        });
        matches = [];
        currentIdx = -1;
      }

      function highlight(query) {
        clear();
        currentQuery = query || '';
        if (!currentQuery) return;
        const lower = currentQuery.toLowerCase();
        const len = currentQuery.length;
        const root = document.body;
        if (!root) return;

        const nodes = [];
        for (const n of textNodes(root)) nodes.push(n);

        for (const node of nodes) {
          const text = node.nodeValue;
          const lc = text.toLowerCase();
          const ranges = [];
          let i = 0;
          while ((i = lc.indexOf(lower, i)) !== -1) {
            ranges.push([i, i + len]);
            i += len;
          }
          if (ranges.length === 0) continue;

          // Split node into pieces; wrap matches in <mark>.
          const frag = document.createDocumentFragment();
          let cursor = 0;
          for (const [a, b] of ranges) {
            if (a > cursor) {
              frag.appendChild(
                document.createTextNode(text.slice(cursor, a))
              );
            }
            const m = document.createElement('mark');
            m.className = 'galaxy-find-match';
            m.textContent = text.slice(a, b);
            frag.appendChild(m);
            matches.push(m);
            cursor = b;
          }
          if (cursor < text.length) {
            frag.appendChild(
              document.createTextNode(text.slice(cursor))
            );
          }
          node.parentNode.replaceChild(frag, node);
        }

        if (matches.length === 0) return;
        currentIdx = reverseMode ? matches.length - 1 : 0;
        applyCurrent();
      }

      function applyCurrent() {
        matches.forEach(m =>
          m.classList.remove('galaxy-find-current')
        );
        if (currentIdx < 0 || currentIdx >= matches.length) return;
        const cur = matches[currentIdx];
        cur.classList.add('galaxy-find-current');
        cur.scrollIntoView({
          behavior: 'instant', block: 'center'
        });
      }

      function step(delta) {
        if (matches.length === 0) return;
        currentIdx =
          (currentIdx + delta + matches.length) % matches.length;
        applyCurrent();
      }

      function emit() {
        if (window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.galaxyFind) {
          window.webkit.messageHandlers.galaxyFind.postMessage({
            event: 'matches',
            count: matches.length,
            index: currentIdx
          });
        }
      }

      window.GalaxyFind = {
        setQuery(q, opts) {
          opts = opts || {};
          reverseMode = !!opts.reverse;
          highlight(q);
          emit();
        },
        next() {
          step(reverseMode ? -1 : 1);
          emit();
        },
        prev() {
          step(reverseMode ? 1 : -1);
          emit();
        },
        close() {
          clear();
          currentQuery = '';
          emit();
        }
      };
    })();
    """
}
