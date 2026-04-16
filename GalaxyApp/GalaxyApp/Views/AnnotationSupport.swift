import Foundation
import WebKit

// MARK: - Annotation CSS

/// CSS for annotation highlights, form, cards, spacers,
/// and emoji popup. Requires CSS variables: --bg, --fg,
/// --code-bg, --code-border, --blockquote-fg,
/// --table-header-bg, --delete-color,
/// --annotation-active-bg, --annotation-active-border,
/// --annotation-active-block-bg,
/// --annotation-active-block-border.
let annotationCSS: String = """
    .annotation-highlight {
        background-color: rgba(88, 166, 255, 0.12);
        border-left: 3px solid rgba(88, 166, 255, 0.6);
        padding-left: 8px;
        margin-left: -11px;
        transition: background-color 0.15s ease;
    }
    .annotation-form {
        position: absolute;
        left: 24px;
        right: 24px;
        z-index: 10;
        padding: 8px 12px;
        border: 1px solid rgba(88, 166, 255, 0.4);
        border-radius: 6px;
        background: var(--code-bg);
        font-family: -apple-system, sans-serif;
        font-size: 13px;
        box-sizing: border-box;
    }
    .annotation-form-header {
        font-size: 11px;
        color: var(--blockquote-fg);
        margin-bottom: 4px;
        font-family: "SF Mono", monospace;
    }
    .annotation-textarea {
        width: 100%;
        min-height: 1.6em;
        padding: 6px 8px;
        border: 1px solid var(--code-border);
        border-radius: 4px;
        background: var(--bg);
        color: var(--fg);
        font-family: -apple-system, sans-serif;
        font-size: 13px;
        line-height: 1.5;
        resize: none;
        overflow: hidden;
        box-sizing: border-box;
    }
    .annotation-textarea:focus {
        outline: none;
        border-color: rgba(88, 166, 255, 0.6);
    }
    body.file-drop-active .annotation-textarea,
    body.file-drop-active .annotation-edit-textarea {
        border-color: rgba(88, 166, 255, 0.8);
        box-shadow: 0 0 0 1px rgba(88, 166, 255, 0.3);
    }
    .annotation-textarea::placeholder {
        color: var(--blockquote-fg);
        opacity: 0.6;
    }
    .annotation-card {
        position: absolute;
        left: 24px;
        right: 24px;
        z-index: 10;
        padding: 6px 10px;
        border: 1px solid var(--code-border);
        border-radius: 6px;
        background: var(--code-bg);
        font-family: -apple-system, sans-serif;
        font-size: 13px;
        box-sizing: border-box;
    }
    .annotation-card-header {
        display: flex;
        align-items: center;
        gap: 6px;
        font-size: 11px;
        color: var(--blockquote-fg);
        margin-bottom: 2px;
    }
    .annotation-card-ref {
        font-family: "SF Mono", monospace;
    }
    .annotation-card-meta {
        font-family: "SF Mono", monospace;
        opacity: 0.5;
    }
    .annotation-card-actions {
        margin-left: auto;
        display: flex;
        gap: 6px;
        opacity: 0;
        transition: opacity 0.15s;
    }
    .annotation-card:hover .annotation-card-actions {
        opacity: 1;
    }
    .annotation-card-actions button {
        background: none;
        border: none;
        color: var(--blockquote-fg);
        cursor: pointer;
        font-size: 15px;
        padding: 3px 6px;
        border-radius: 4px;
        line-height: 1;
    }
    .annotation-card-actions button:hover {
        background: var(--table-header-bg);
        color: var(--fg);
    }
    .annotation-card-actions .annotation-btn-delete {
        color: var(--delete-color);
    }
    .annotation-card-actions .annotation-btn-delete:hover {
        background: rgba(255, 59, 48, 0.1);
        color: var(--delete-color);
    }
    .annotation-card-actions:has(.confirming) {
        opacity: 1;
    }
    .annotation-card-actions:has(.confirming)
        .annotation-btn-edit {
        display: none;
    }
    .annotation-card:has(.annotation-edit-textarea)
        .annotation-card-actions {
        display: none;
    }
    .annotation-btn-delete.confirming {
        background: rgba(220, 40, 30, 0.75) !important;
        color: #fff !important;
        font-size: 12px;
        font-weight: 600;
        font-family: -apple-system, sans-serif;
        padding: 4px 12px !important;
        position: relative;
        overflow: hidden;
    }
    .annotation-btn-delete.confirming:hover {
        background: rgba(220, 40, 30, 0.85) !important;
        color: #fff !important;
    }
    .annotation-btn-delete.confirming::after {
        content: '';
        position: absolute;
        bottom: 0;
        left: 0;
        height: 1.5px;
        background: rgba(255, 255, 255, 0.8);
        animation: confirmDrain 5s linear forwards;
    }
    @keyframes confirmDrain {
        from { width: 100%; }
        to { width: 0%; }
    }
    .annotation-card-content {
        line-height: 1.5;
        color: var(--fg);
    }
    .annotation-card-content.collapsed {
        max-height: 1.6em;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
    }
    .annotation-card-content.collapsed p {
        display: inline;
        margin: 0;
    }
    .annotation-card-content ul,
    .annotation-card-content ol {
        margin-top: 0;
        margin-bottom: 8px;
        padding-left: 2em;
    }
    .annotation-card-content li + li {
        margin-top: 0.25em;
    }
    .annotation-edit-textarea {
        width: 100%;
        min-height: 1.6em;
        padding: 4px 6px;
        border: 1px solid rgba(88, 166, 255, 0.4);
        border-radius: 4px;
        background: var(--bg);
        color: var(--fg);
        font-family: -apple-system, sans-serif;
        font-size: 13px;
        line-height: 1.5;
        resize: none;
        overflow: hidden;
        box-sizing: border-box;
    }
    .annotation-card.expanded {
        border-color: var(--annotation-active-border);
        background: var(--annotation-active-bg);
    }
    .annotation-expanded-highlight {
        background-color:
            var(--annotation-active-block-bg);
        border-left: 3px solid
            var(--annotation-active-block-border);
        padding-left: 8px;
        margin-left: -11px;
        transition: background-color 0.15s ease;
    }
    .annotation-expand-hint {
        display: block;
        font-size: 11px;
        color: var(--blockquote-fg);
        opacity: 0.5;
        margin-top: 2px;
        cursor: pointer;
    }
    .annotation-card.expanded .annotation-expand-hint {
        display: none;
    }
    .annotation-spacer {
        pointer-events: none;
        line-height: 0;
        font-size: 0;
    }
    .annotation-spacer.form-spacer {
        margin: 8px 0;
    }
    .annotation-spacer.card-spacer {
        margin: 6px 0;
    }
    .annotation-spacer-row td {
        padding: 0 !important;
        border: none !important;
        background: transparent !important;
        line-height: 0;
    }
    .emoji-popup {
        position: absolute;
        z-index: 100;
        min-width: 200px;
        max-width: 300px;
        max-height: 280px;
        overflow-y: auto;
        border: 1px solid var(--code-border);
        border-radius: 6px;
        background: var(--code-bg);
        box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
        font-family: -apple-system, sans-serif;
        font-size: 13px;
        padding: 4px 0;
        display: none;
    }
    .emoji-popup-row {
        display: flex;
        align-items: center;
        padding: 4px 10px;
        cursor: pointer;
        gap: 8px;
    }
    .emoji-popup-row.selected,
    .emoji-popup-row.selected:hover {
        background: rgba(88, 166, 255, 0.2);
    }
    .emoji-popup-row:hover {
        background: rgba(88, 166, 255, 0.12);
    }
    .emoji-popup-emoji {
        font-size: 18px;
        width: 24px;
        text-align: center;
        flex-shrink: 0;
    }
    .emoji-popup-name {
        color: var(--fg);
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
    }
    .emoji-popup-name .emoji-match {
        font-weight: 600;
    }
"""

// MARK: - CSS Variables

/// CSS variable definitions for annotation theming.
func annotationCSSVars(isDark: Bool) -> String {
    if isDark {
        return """
            --bg: #0d1117;
            --fg: #e6edf3;
            --code-bg: #161b22;
            --code-border: #30363d;
            --blockquote-fg: #8b949e;
            --table-header-bg: #21262d;
            --annotation-active-bg: \
        rgba(255, 255, 120, 0.12);
            --annotation-active-border: \
        rgba(255, 220, 50, 0.5);
            --annotation-active-block-bg: \
        rgba(255, 255, 120, 0.08);
            --annotation-active-block-border: \
        rgba(255, 220, 50, 0.35);
            --delete-color: #ff5252;
        """
    } else {
        return """
            --bg: #ffffff;
            --fg: #1f2328;
            --code-bg: #f6f8fa;
            --code-border: #d0d7de;
            --blockquote-fg: #656d76;
            --table-header-bg: #f0f0f0;
            --annotation-active-bg: \
        rgba(255, 248, 220, 0.8);
            --annotation-active-border: #d4a017;
            --annotation-active-block-bg: \
        rgba(255, 248, 220, 0.5);
            --annotation-active-block-border: \
        rgba(212, 160, 23, 0.6);
            --delete-color: #ff3b30;
        """
    }
}

// MARK: - Generalized AnnotationManager JS

/// Returns the AnnotationManager JS module, generalized
/// for different block selectors and anchor types.
///
/// Config parameters (passed to initialize()):
///   - anchorType: 'line_range'|'row_range'|'block_range'
///   - blockSelector: CSS selector for selectable elements
///   - lineAttr: data attribute name for block index/line
///   - refPrefix: display prefix ('Line', 'Row', 'Block')
///   - itemLabel: header label ('Artifact #3', etc.)
///   - annotations: array of annotation objects
///   - htmlMap: map of number -> rendered HTML
let annotationManagerJS: String = """
    function autoGrow(el) {
        el.style.height = 'auto';
        el.style.height = el.scrollHeight + 'px';
        if (typeof AnnotationManager !== 'undefined'
            && AnnotationManager.syncAllPositions) {
            AnnotationManager.syncAllPositions();
        }
    }

    const AnnotationManager = {
        blocks: [],
        currentBlockIndex: 0,
        highlightStart: 0,
        highlightEnd: 0,
        annotations: [],
        annotationHTMLMap: {},
        formElement: null,
        formSpacer: null,
        formSpacerRow: null,
        cardSpacers: {},
        resizeObserver: null,
        editingNumber: null,
        expandedNumber: null,
        confirmingDeleteNumber: null,
        confirmDeleteTimer: null,
        confirmArmedAt: null,
        submitting: false,
        deleting: false,
        // Config
        anchorType: 'line_range',
        blockSelector: '.md-block',
        lineAttr: 'data-line-start',
        endLineAttr: null,
        refPrefix: 'Line',
        itemLabel: '',
        editIconSVG: '<svg width="1em" height="1em" \
viewBox="0 0 24 24" fill="none" stroke="currentColor" \
stroke-width="2.5" stroke-linecap="round" \
stroke-linejoin="round"><path d="M17 3a2.828 2.828 0 \
114 4L7.5 20.5 2 22l1.5-5.5L17 3z"/></svg>',
        deleteIconSVG: '<svg width="1em" height="1em" \
viewBox="0 0 24 24" fill="none" stroke="currentColor" \
stroke-width="2.5" stroke-linecap="round" \
stroke-linejoin="round"><path d="M3 6h18"/><path \
d="M8 6V4h8v2"/><path d="M5 6v14a1 1 0 001 1h12a1 \
1 0 001-1V6"/><path d="M10 11v6"/><path d="M14 \
11v6"/></svg>',

        initialize(data) {
            this.anchorType = data.anchorType || \
'line_range';
            this.blockSelector = data.blockSelector || \
'.md-block';
            this.lineAttr = data.lineAttr || \
'data-line-start';
            this.endLineAttr = data.endLineAttr || null;
            this.refPrefix = data.refPrefix || 'Line';
            this.itemLabel = data.itemLabel || '';
            this.annotations = data.annotations || [];
            this.annotationHTMLMap = data.htmlMap || {};

            // Whole-type mode: no blocks, form/cards
            // appended to a container at the bottom
            if (this.anchorType === 'whole') {
                this.blocks = [];
                this.initWholeMode();
                return;
            }

            var allBlocks = document.querySelectorAll(
                this.blockSelector
            );
            // For md-block, filter to leaf blocks
            if (this.blockSelector === '.md-block') {
                this.blocks = Array.from(allBlocks)\
.filter(
                    function(el) {
                        return !el.querySelector(\
'.md-block');
                    }
                );
            } else {
                this.blocks = Array.from(allBlocks);
            }

            if (this.blocks.length === 0) return;

            this.currentBlockIndex = -1;
            this.highlightStart = -1;
            this.highlightEnd = -1;

            this.createForm();
            this.renderAllAnnotations();

            var self = this;
            document.addEventListener(\
'mouseup', function(e) {
                if (e.target.closest(\
'.annotation-form') ||
                    e.target.closest(\
'.annotation-card')) return;

                var sel = window.getSelection();
                if (!sel || sel.isCollapsed) return;

                var range = sel.getRangeAt(0);
                var startBlock = self.findBlockElement(\
range.startContainer);
                var endBlock = self.findBlockElement(\
range.endContainer);

                if (!startBlock || !endBlock) return;

                var startIdx = self.blocks.indexOf(\
startBlock);
                var endIdx = self.blocks.indexOf(\
endBlock);
                if (startIdx < 0 || endIdx < 0) return;

                var lo = Math.min(startIdx, endIdx);
                var hi = Math.max(startIdx, endIdx);

                if (self.isFormVisible()) {
                    var ta = self.formElement
                        ? self.formElement.querySelector(\
'textarea')
                        : null;
                    if (ta && ta.value.trim()) {
                        window.webkit.messageHandlers\
.annotation
                            .postMessage({
                                action: \
'confirmDragReplace',
                                startIdx: lo,
                                endIdx: hi
                            });
                        sel.removeAllRanges();
                        return;
                    }
                }

                self.showFormForSelection(lo, hi);
                sel.removeAllRanges();
            });
        },

        // --- Whole-type Mode ---

        initWholeMode() {
            // Create container at bottom of body
            var container = document.createElement('div');
            container.id = 'annotation-whole-container';
            container.style.cssText = 'padding: 0 24px '
                + '24px 24px;';
            document.body.appendChild(container);
            this.wholeContainer = container;

            this.renderWholeAnnotations();
            this.createWholeForm();

            // Double-click anywhere (except form/cards)
            // opens the annotation form
            var self = this;
            document.addEventListener(\
'dblclick', function(e) {
                if (e.target.closest(\
'.annotation-form') ||
                    e.target.closest(\
'.annotation-card')) return;
                if (!self.isFormVisible()) {
                    self.showWholeForm();
                }
            });
        },

        createWholeForm() {
            var form = document.createElement('div');
            form.className = 'annotation-form';
            form.style.cssText = 'position: relative; '
                + 'left: 0; right: 0; display: none; '
                + 'margin-bottom: 12px;';
            var label = this.itemLabel || '';
            form.innerHTML =
                '<div class="annotation-form-header">'
                + '<span class="annotation-form-ref">'
                + label + '</span></div>'
                + '<textarea class="annotation-textarea"'
                + ' placeholder="Add annotation\\u2026'
                + ' (\\u2318Enter to save'
                + ' \\u00b7 Esc to dismiss)"'
                + ' rows="1"></textarea>';

            var ta = form.querySelector('textarea');
            ta.addEventListener('input', function() {
                autoGrow(ta);
            });
            ta.addEventListener('keydown', function(e) {
                if (typeof EmojiAutocomplete \
!== 'undefined' &&
                    EmojiAutocomplete.handleKeyDown(\
ta, e)) {
                    return;
                }
                if (e.key === 'Enter' && e.metaKey) {
                    e.preventDefault();
                    AnnotationManager.submitCreate();
                }
            });

            if (typeof EmojiAutocomplete \
!== 'undefined') {
                EmojiAutocomplete.attach(ta);
            }

            this.formElement = form;
            this.wholeContainer.appendChild(form);
        },

        showWholeForm() {
            this.collapseExpanded();
            this.formElement.style.display = '';
            var ta = this.formElement.querySelector(\
'textarea');
            if (ta) { ta.value = ''; autoGrow(ta); }
            requestAnimationFrame(function() {
                if (ta) ta.focus();
            });
        },

        renderWholeAnnotations() {
            // Remove existing cards
            var existing = this.wholeContainer\
.querySelectorAll('.annotation-card');
            existing.forEach(function(c) { c.remove(); });

            for (var i = 0; i < this.annotations.length;\
 i++) {
                var ann = this.annotations[i];
                var html = this.annotationHTMLMap[\
ann.number] || '';
                this.insertWholeCard(ann, html);
            }
        },

        insertWholeCard(annotation, renderedHTML) {
            var isExpanded = this.expandedNumber \
=== annotation.number;
            var hasReview = !!annotation.review_number;

            var metaText = '#' + annotation.number;
            if (hasReview) {
                metaText += ' \\u00B7 Review #'
                    + annotation.review_number;
                if (annotation.review_reviewed_at) {
                    metaText += ' \\u00B7 '
                        + this.formatReviewDate(\
annotation.review_reviewed_at);
                }
            }

            var actionsHTML = hasReview ? '' :
                '<span class=\
"annotation-card-actions">' +
                    '<button class=\
"annotation-btn-edit" title="Edit">' +
                        this.editIconSVG + '</button>' +
                    '<button class=\
"annotation-btn-delete" title="Delete">' +
                        this.deleteIconSVG
                        + '</button>' +
                '</span>';

            var card = document.createElement('div');
            card.className = 'annotation-card'
                + (isExpanded ? ' expanded' : '');
            card.style.cssText = 'position: relative; '
                + 'left: 0; right: 0; '
                + 'margin-bottom: 8px;';
            card.setAttribute('data-number',
                annotation.number);
            card.innerHTML =
                '<div class=\
"annotation-card-header">' +
                    '<span class=\
"annotation-card-meta">'
                    + metaText + '</span>' +
                    actionsHTML +
                '</div>' +
                '<div class="annotation-card-content'
                + (isExpanded ? '' : ' collapsed') + '">'
                + renderedHTML + '</div>' +
                '<span class="annotation-expand-hint"'
                + (isExpanded
                    ? ' style="display:none"' : '')
                + '>Click to expand</span>';

            var self = this;
            card.addEventListener('click', function(e) {
                if (e.target.closest(\
'.annotation-btn-edit') ||
                    e.target.closest(\
'.annotation-btn-delete') ||
                    e.target.closest(\
'.annotation-edit-textarea'))
                    return;
                self.expandAnnotation(annotation.number);
            });

            var editBtn = card.querySelector(\
'.annotation-btn-edit');
            if (editBtn) {
                editBtn.addEventListener(\
'click', function(e) {
                    e.stopPropagation();
                    self.startEdit(annotation.number);
                });
            }
            var deleteBtn = card.querySelector(\
'.annotation-btn-delete');
            if (deleteBtn) {
                deleteBtn.addEventListener(\
'click', function(e) {
                    e.stopPropagation();
                    self.handleDeleteClick(\
annotation.number);
                });
            }

            if (this.formElement &&
                this.formElement.parentNode ===
                    this.wholeContainer) {
                this.wholeContainer.insertBefore(
                    card, this.formElement
                );
            } else {
                this.wholeContainer.appendChild(card);
            }
        },

        findBlockElement(node) {
            var el = node.nodeType === 3
                ? node.parentElement : node;
            var selector = this.blockSelector;
            while (el && !el.matches(selector)) {
                el = el.parentElement;
            }
            if (!el) return null;
            // For md-block, walk to leaf
            if (selector === '.md-block') {
                while (el.querySelector('.md-block')) {
                    el = el.querySelector('.md-block');
                }
            }
            return el;
        },

        showFormForSelection(startIdx, endIdx) {
            this.collapseExpanded();
            this.currentBlockIndex = endIdx;
            this.highlightStart = startIdx;
            this.highlightEnd = endIdx;
            this.updateHighlights();
            this.positionForm();
            this.formElement.style.display = '';

            var ta = this.formElement.querySelector(\
'textarea');
            if (ta) { ta.value = ''; autoGrow(ta); }
            this.updateFormReference();
            requestAnimationFrame(function() {
                if (ta) ta.focus();
            });
        },

        restoreFormState(state) {
            if (!state || this.blocks.length === 0) \
return;
            var maxIdx = this.blocks.length - 1;

            if (state.formVisible
                && state.currentBlockIndex >= 0) {
                this.currentBlockIndex = Math.min(\
state.currentBlockIndex, maxIdx);
                this.highlightStart = Math.min(\
state.highlightStart || 0, maxIdx);
                this.highlightEnd = Math.min(\
state.highlightEnd || 0, maxIdx);
                this.updateHighlights();
                this.positionForm();
                this.formElement.style.display = '';
                this.updateFormReference();
                if (state.textareaValue) {
                    var ta = this.formElement\
.querySelector('textarea');
                    if (ta) {
                        ta.value = state.textareaValue;
                        autoGrow(ta);
                    }
                }
            }
            if (state.expandedNumber != null) {
                this.expandAnnotation(\
state.expandedNumber);
            }
        },

        focusTextarea() {
            var ta = this.formElement
                ? this.formElement.querySelector(\
'textarea')
                : null;
            if (ta) ta.focus();
        },

        updateHighlights() {
            var hs = this.highlightStart;
            var he = this.highlightEnd;
            this.blocks.forEach(function(block, i) {
                var inFormRange = hs >= 0 && he >= 0
                    && i >= hs && i <= he;
                var hasExpanded = block.classList\
.contains(\
'annotation-expanded-highlight');
                block.classList.toggle(\
'annotation-highlight',
                    inFormRange && !hasExpanded);
            });
        },

        createForm() {
            var form = document.createElement('div');
            form.className = 'annotation-form';
            form.id = 'annotation-form';
            form.style.display = 'none';
            form.innerHTML =
                '<div class="annotation-form-header">'
                + '<span class="annotation-form-ref">'
                + '</span></div>'
                + '<textarea class="annotation-textarea"'
                + ' placeholder="Add annotation\\u2026'
                + ' (\\u2318Enter to save'
                + ' \\u00b7 Esc to dismiss)"'
                + ' rows="1"></textarea>';

            var ta = form.querySelector('textarea');
            ta.addEventListener('focus', function() {
                AnnotationManager.collapseExpanded();
            });
            ta.addEventListener('input', function() {
                autoGrow(ta);
            });
            ta.addEventListener('keydown', function(e) {
                if (typeof EmojiAutocomplete \
!== 'undefined' &&
                    EmojiAutocomplete.handleKeyDown(\
ta, e)) {
                    return;
                }
                if (e.key === 'Enter' && e.metaKey) {
                    e.preventDefault();
                    AnnotationManager.submitCreate();
                }
            });

            if (typeof EmojiAutocomplete \
!== 'undefined') {
                EmojiAutocomplete.attach(ta);
            }

            this.formElement = form;
            document.body.appendChild(form);

            this.resizeObserver = new ResizeObserver(\
function() {
                AnnotationManager.syncAllPositions();
            });
            this.resizeObserver.observe(form);
        },

        positionForm(skipScroll, direction) {
            var targetBlock = this.blocks[\
this.highlightEnd];
            if (!targetBlock || !this.formElement) \
return;

            this.removeSpacer(this.formSpacer,
                this.formSpacerRow);

            var insertBefore = targetBlock\
.nextElementSibling;
            while (insertBefore && (
                insertBefore.classList.contains(\
'annotation-spacer') ||
                insertBefore.classList.contains(\
'annotation-spacer-row')
            )) {
                insertBefore = insertBefore\
.nextElementSibling;
            }

            var result = this.createSpacer(
                targetBlock.parentNode,
                insertBefore, 'form-spacer'
            );
            this.formSpacer = result.spacer;
            this.formSpacerRow = result.spacerRow;

            this.updateFormReference();
            this.syncAllPositions();
            if (!skipScroll) {
                if (direction) {
                    this.scrollFormIntoView(direction);
                } else {
                    this.formElement.scrollIntoView({
                        behavior: 'smooth',
                        block: 'nearest'
                    });
                }
            }
        },

        scrollFormIntoView(direction) {
            if (!this.formElement) return;
            var rect = this.formElement\
.getBoundingClientRect();
            var vh = window.innerHeight;

            if (rect.bottom < 0 || rect.top > vh) {
                this.formElement.scrollIntoView({
                    behavior: 'smooth',
                    block: 'center'
                });
                return;
            }

            var margin = vh * 0.35;
            if (direction === 'down') {
                var bottomSpace = vh - rect.bottom;
                if (bottomSpace < margin) {
                    window.scrollBy({
                        top: margin - bottomSpace,
                        behavior: 'smooth'
                    });
                }
            } else if (direction === 'up') {
                var topSpace = rect.top;
                if (topSpace < margin) {
                    window.scrollBy({
                        top: -(margin - topSpace),
                        behavior: 'smooth'
                    });
                }
            }
        },

        updateFormReference() {
            var range = this.getLineRange(\
this.highlightStart, this.highlightEnd);
            var ref;
            if (range.startLine === range.endLine) {
                ref = this.refPrefix.toLowerCase()
                    + ' ' + range.startLine;
            } else {
                ref = this.refPrefix.toLowerCase()
                    + 's ' + range.startLine
                    + '\\u2013' + range.endLine;
            }
            var label = this.itemLabel
                ? this.itemLabel + ': ' : '';
            var refEl = this.formElement.querySelector(\
'.annotation-form-ref');
            if (refEl) {
                refEl.textContent = label + ref;
            }
        },

        getLineRange(startIdx, endIdx) {
            var startBlock = this.blocks[startIdx];
            var endBlock = this.blocks[endIdx];
            var startLine = parseInt(
                startBlock.getAttribute(this.lineAttr)
            ) || 0;
            var endLine;
            if (this.endLineAttr) {
                endLine = parseInt(
                    endBlock.getAttribute(\
this.endLineAttr)
                ) || 0;
            } else {
                endLine = parseInt(
                    endBlock.getAttribute(this.lineAttr)
                ) || 0;
            }
            return {
                startLine: startLine,
                endLine: endLine
            };
        },

        renderAllAnnotations() {
            if (typeof EmojiAutocomplete \
!== 'undefined') {
                var editTas = document.querySelectorAll(\
'.annotation-edit-textarea');
                editTas.forEach(function(ta) {
                    EmojiAutocomplete.detach(ta);
                });
            }
            this.clearDeleteConfirmation();
            for (var num in this.cardSpacers) {
                var entry = this.cardSpacers[num];
                this.removeSpacer(entry.spacer,
                    entry.spacerRow);
                if (this.resizeObserver && entry.card) {
                    this.resizeObserver.unobserve(\
entry.card);
                }
                if (entry.card && entry.card.parentNode)
                    entry.card.remove();
            }
            this.cardSpacers = {};
            for (var i = 0; i < this.annotations.length;
                 i++) {
                var ann = this.annotations[i];
                var html = this.annotationHTMLMap[\
ann.number] || '';
                this.insertCard(ann, html);
            }
            if (this.formElement)
                this.positionForm(true);
            if (this.expandedNumber !== null) {
                this.applyExpandedHighlight(\
this.expandedNumber);
            }
        },

        refreshAnnotationData(annotations) {
            this.annotations = annotations;
            if (this.anchorType === 'whole') {
                this.renderWholeAnnotations();
            } else {
                this.renderAllAnnotations();
            }
        },

        findBlockIndexForEndLine(endLine) {
            var attr = this.endLineAttr || this.lineAttr;
            for (var i = this.blocks.length - 1;
                 i >= 0; i--) {
                var blockEnd = parseInt(
                    this.blocks[i].getAttribute(attr)
                );
                if (blockEnd <= endLine) return i;
            }
            return 0;
        },

        findBlockIndexForStartLine(startLine) {
            for (var i = 0; i < this.blocks.length;
                 i++) {
                var blockStart = parseInt(
                    this.blocks[i].getAttribute(\
this.lineAttr)
                );
                if (blockStart >= startLine) return i;
            }
            return this.blocks.length - 1;
        },

        insertCard(annotation, renderedHTML) {
            var startKey = this.anchorStartKey();
            var endKey = this.anchorEndKey();
            var endVal = annotation[endKey]
                || annotation[startKey];
            var blockIdx = this.findBlockIndexForEndLine(\
endVal);
            var block = this.blocks[blockIdx];
            if (!block) return;

            var startVal = annotation[startKey];
            var lineRef;
            if (startVal === endVal) {
                lineRef = this.refPrefix.toLowerCase()
                    + ' ' + startVal;
            } else {
                lineRef = this.refPrefix.toLowerCase()
                    + 's ' + startVal
                    + '\\u2013' + endVal;
            }

            var isExpanded = this.expandedNumber
                === annotation.number;
            var hasReview = !!annotation.review_number;

            var metaText = '#' + annotation.number;
            if (hasReview) {
                metaText += ' \\u00B7 Review #'
                    + annotation.review_number;
                if (annotation.review_reviewed_at) {
                    metaText += ' \\u00B7 '
                        + this.formatReviewDate(\
annotation.review_reviewed_at);
                }
            }

            var actionsHTML = hasReview ? '' :
                '<span class=\
"annotation-card-actions">' +
                    '<button class=\
"annotation-btn-edit" title="Edit">' +
                        this.editIconSVG + '</button>' +
                    '<button class=\
"annotation-btn-delete" title="Delete">' +
                        this.deleteIconSVG
                        + '</button>' +
                '</span>';

            var card = document.createElement('div');
            card.className = 'annotation-card'
                + (isExpanded ? ' expanded' : '');
            card.setAttribute('data-number',
                annotation.number);
            card.innerHTML =
                '<div class=\
"annotation-card-header">' +
                    '<span class=\
"annotation-card-ref">'
                    + lineRef + '</span>' +
                    '<span class=\
"annotation-card-meta">'
                    + metaText + '</span>' +
                    actionsHTML +
                '</div>' +
                '<div class="annotation-card-content'
                + (isExpanded ? '' : ' collapsed')
                + '">' +
                    renderedHTML +
                '</div>' +
                '<span class=\
"annotation-expand-hint"'
                + (isExpanded
                    ? ' style="display:none"' : '')
                + '>Click to expand</span>';

            var self = this;
            card.addEventListener('click', function(e) {
                if (e.target.closest(\
'.annotation-card-actions') ||
                    e.target.closest(\
'.annotation-edit-textarea')) return;
                self.expandAnnotation(\
annotation.number);
            });

            if (!hasReview) {
                card.querySelector(\
'.annotation-btn-edit').addEventListener(
                    'click', function(e) {
                        e.stopPropagation();
                        self.startEdit(\
annotation.number);
                    }
                );
                card.querySelector(\
'.annotation-btn-delete').addEventListener(
                    'click', function(e) {
                        e.stopPropagation();
                        self.handleDeleteClick(\
annotation.number);
                    }
                );
            }

            var insertBefore = block\
.nextElementSibling;
            while (insertBefore && (
                insertBefore.classList.contains(\
'annotation-spacer') ||
                insertBefore.classList.contains(\
'annotation-spacer-row')
            )) {
                insertBefore = insertBefore\
.nextElementSibling;
            }
            var result = this.createSpacer(
                block.parentNode,
                insertBefore, 'card-spacer'
            );

            document.body.appendChild(card);
            this.cardSpacers[annotation.number] = {
                spacer: result.spacer,
                spacerRow: result.spacerRow,
                card: card
            };
            if (this.resizeObserver)
                this.resizeObserver.observe(card);
        },

        anchorStartKey() {
            switch (this.anchorType) {
                case 'row_range': return 'start_row';
                case 'block_range': return 'start_block';
                default: return 'start_line';
            }
        },

        anchorEndKey() {
            switch (this.anchorType) {
                case 'row_range': return 'end_row';
                case 'block_range': return 'end_block';
                default: return 'end_line';
            }
        },

        expandAnnotation(number) {
            if (this.expandedNumber === number) {
                this.collapseExpanded();
                this.focusTextarea();
                return;
            }

            this.collapseExpanded();

            if (this.editingNumber !== null
                && this.editingNumber !== number) {
                this.cancelEdit();
            }

            this.expandedNumber = number;
            var card = document.querySelector(
                '.annotation-card[data-number="'
                + number + '"]'
            );
            if (card) {
                card.classList.add('expanded');
                var content = card.querySelector(\
'.annotation-card-content');
                if (content)
                    content.classList.remove('collapsed');
                var hint = card.querySelector(\
'.annotation-expand-hint');
                if (hint) hint.style.display = 'none';
                this.syncAllPositions();
                card.scrollIntoView({
                    behavior: 'smooth',
                    block: 'nearest'
                });
            }

            this.applyExpandedHighlight(number);
        },

        collapseExpanded() {
            if (this.expandedNumber === null) return;

            var card = document.querySelector(
                '.annotation-card[data-number="'
                + this.expandedNumber + '"]'
            );
            if (card) {
                card.classList.remove('expanded');
                var content = card.querySelector(\
'.annotation-card-content');
                if (content)
                    content.classList.add('collapsed');
                var hint = card.querySelector(\
'.annotation-expand-hint');
                if (hint) hint.style.display = '';
            }

            this.clearExpandedHighlight();
            this.expandedNumber = null;
            this.updateHighlights();
            this.syncAllPositions();
        },

        applyExpandedHighlight(number) {
            var startKey = this.anchorStartKey();
            var endKey = this.anchorEndKey();
            var ann = this.annotations.find(
                function(a) {
                    return a.number === number;
                }
            );
            if (!ann) return;

            var startIdx = this.findBlockIndexForStartLine(\
ann[startKey]);
            var endVal = ann[endKey] || ann[startKey];
            var endIdx = this.findBlockIndexForEndLine(\
endVal);

            for (var i = startIdx; i <= endIdx; i++) {
                this.blocks[i].classList.add(\
'annotation-expanded-highlight');
                this.blocks[i].classList.remove(\
'annotation-highlight');
            }
        },

        clearExpandedHighlight() {
            this.blocks.forEach(function(block) {
                block.classList.remove(\
'annotation-expanded-highlight');
            });
        },

        createSpacer(parent, insertBefore, className) {
            var spacer = document.createElement('div');
            spacer.className = 'annotation-spacer '
                + className;
            spacer.style.height = '0px';

            var spacerRow = null;
            var parentTag = parent.tagName;
            if (parentTag === 'TBODY'
                || parentTag === 'THEAD') {
                spacerRow = document.createElement('tr');
                spacerRow.className = \
'annotation-spacer-row';
                var td = document.createElement('td');
                td.setAttribute('colspan', '999');
                td.appendChild(spacer);
                spacerRow.appendChild(td);
                parent.insertBefore(spacerRow,
                    insertBefore);
            } else {
                parent.insertBefore(spacer,
                    insertBefore);
            }

            return {
                spacer: spacer,
                spacerRow: spacerRow
            };
        },

        removeSpacer(spacer, spacerRow) {
            if (spacerRow) spacerRow.remove();
            else if (spacer) spacer.remove();
        },

        syncAllPositions() {
            var scrollY = window.pageYOffset
                || document.documentElement.scrollTop;

            if (this.formSpacer && this.formElement) {
                this.formSpacer.style.height
                    = this.formElement.offsetHeight
                    + 'px';
                var rect = this.formSpacer\
.getBoundingClientRect();
                this.formElement.style.top
                    = (rect.top + scrollY) + 'px';
            }
            for (var num in this.cardSpacers) {
                var entry = this.cardSpacers[num];
                if (entry.spacer && entry.card) {
                    entry.spacer.style.height
                        = entry.card.offsetHeight
                        + 'px';
                    var rect = entry.spacer\
.getBoundingClientRect();
                    entry.card.style.top
                        = (rect.top + scrollY) + 'px';
                }
            }
        },

        startEdit(number) {
            if (this.editingNumber !== null)
                this.cancelEdit();
            if (this.expandedNumber !== number) {
                this.expandAnnotation(number);
            }
            this.editingNumber = number;

            var card = document.querySelector(
                '.annotation-card[data-number="'
                + number + '"]'
            );
            if (!card) return;
            var contentDiv = card.querySelector(\
'.annotation-card-content');
            var ann = this.annotations.find(
                function(a) {
                    return a.number === number;
                }
            );
            if (!ann || !contentDiv) return;

            card.setAttribute('data-original-html',
                contentDiv.outerHTML);

            var ta = document.createElement('textarea');
            ta.className = 'annotation-edit-textarea';
            ta.value = ann.content;
            contentDiv.replaceWith(ta);

            autoGrow(ta);
            ta.addEventListener('input', function() {
                autoGrow(ta);
            });
            ta.addEventListener('keydown', function(e) {
                if (typeof EmojiAutocomplete \
!== 'undefined' &&
                    EmojiAutocomplete.handleKeyDown(\
ta, e)) {
                    return;
                }
                if (e.key === 'Enter' && e.metaKey) {
                    e.preventDefault();
                    AnnotationManager.submitUpdate(\
number);
                }
            });

            if (typeof EmojiAutocomplete \
!== 'undefined') {
                EmojiAutocomplete.attach(ta);
            }

            this.syncAllPositions();
            ta.focus();
        },

        cancelEdit() {
            if (this.editingNumber === null) return;
            var card = document.querySelector(
                '.annotation-card[data-number="'
                + this.editingNumber + '"]'
            );
            if (card) {
                var ta = card.querySelector(\
'.annotation-edit-textarea');
                if (typeof EmojiAutocomplete \
!== 'undefined' && ta) {
                    EmojiAutocomplete.detach(ta);
                }
                var originalHTML = card.getAttribute(\
'data-original-html');
                if (ta && originalHTML) {
                    var temp = document.createElement(\
'div');
                    temp.innerHTML = originalHTML;
                    if (temp.firstChild)
                        ta.replaceWith(temp.firstChild);
                }
                card.removeAttribute(\
'data-original-html');
            }
            this.editingNumber = null;
            this.syncAllPositions();
        },

        submitCreate() {
            if (this.submitting) return;

            var ta = this.formElement.querySelector(\
'textarea');
            var content = ta ? ta.value.trim() : '';
            if (!content) return;

            this.submitting = true;

            if (this.anchorType === 'whole') {
                window.webkit.messageHandlers.annotation\
.postMessage({
                    action: 'create',
                    anchorType: 'whole',
                    content: content
                });
                return;
            }

            var range = this.getLineRange(\
this.highlightStart, this.highlightEnd);
            var msg = {
                action: 'create',
                anchorType: this.anchorType,
                content: content
            };
            switch (this.anchorType) {
                case 'row_range':
                    msg.startRow = range.startLine;
                    msg.endRow = range.endLine;
                    break;
                case 'block_range':
                    msg.startBlock = range.startLine;
                    msg.endBlock = range.endLine;
                    var blockTexts = [];
                    var attr = this.lineAttr;
                    for (var bi = range.startLine;
                         bi <= range.endLine; bi++) {
                        var bl = document.querySelector(
                            '[' + attr + '="'
                            + bi + '"]');
                        if (bl) blockTexts.push(
                            bl.textContent.trim());
                    }
                    msg.blockContent =
                        blockTexts.join('\\n');
                    break;
                default:
                    msg.startLine = range.startLine;
                    msg.endLine = range.endLine;
            }
            window.webkit.messageHandlers.annotation\
.postMessage(msg);
        },

        submitUpdate(number) {
            if (this.submitting) return;

            var card = document.querySelector(
                '.annotation-card[data-number="'
                + number + '"]'
            );
            if (!card) return;
            var ta = card.querySelector(\
'.annotation-edit-textarea');
            if (!ta) return;
            var content = ta.value.trim();
            if (!content) return;

            this.submitting = true;

            window.webkit.messageHandlers.annotation\
.postMessage({
                action: 'update',
                number: number,
                content: content
            });
        },

        handleDeleteClick(number) {
            if (this.deleting) return;
            if (this.confirmingDeleteNumber === number) {
                // Reject clicks too close to arming — this
                // catches the second click of a double-click
                // regardless of whether btn.disabled worked.
                var elapsed = Date.now() - this.confirmArmedAt;
                if (elapsed < 500) return;
                this.deleting = true;
                this.clearDeleteConfirmation();
                this.requestDelete(number);
            } else {
                this.showDeleteConfirmation(number);
            }
        },

        showDeleteConfirmation(number) {
            this.clearDeleteConfirmation();
            this.confirmingDeleteNumber = number;
            this.confirmArmedAt = Date.now();

            var btn = document.querySelector(
                '.annotation-card[data-number="'
                + number
                + '"] .annotation-btn-delete'
            );
            if (!btn) return;
            btn.classList.add('confirming');
            btn.textContent = 'Are you sure?';

            this.confirmDeleteTimer = setTimeout(\
function() {
                AnnotationManager\
.clearDeleteConfirmation();
            }, 5000);
        },

        clearDeleteConfirmation() {
            if (this.confirmDeleteTimer) {
                clearTimeout(this.confirmDeleteTimer);
                this.confirmDeleteTimer = null;
            }
            this.confirmArmedAt = null;
            var number = this.confirmingDeleteNumber;
            if (number === null) return;
            this.confirmingDeleteNumber = null;

            var btn = document.querySelector(
                '.annotation-card[data-number="'
                + number
                + '"] .annotation-btn-delete'
            );
            if (!btn) return;
            btn.classList.remove('confirming');
            btn.innerHTML = this.deleteIconSVG;
        },

        requestDelete(number) {
            window.webkit.messageHandlers.annotation\
.postMessage({
                action: 'delete',
                number: number
            });
        },

        annotationCreated(data) {
            this.submitting = false;

            var scrollY = window.pageYOffset
                || document.documentElement.scrollTop;

            this.annotations.push(data.annotation);
            this.annotationHTMLMap[\
data.annotation.number]
                = data.renderedHTML;

            if (this.anchorType === 'whole') {
                this.annotations.sort(function(a, b) {
                    return a.number - b.number;
                });
                this.renderWholeAnnotations();
                this.dismissForm();
                return;
            }

            var startKey = this.anchorStartKey();
            var endKey = this.anchorEndKey();
            this.annotations.sort(function(a, b) {
                return (a[startKey] - b[startKey])
                    || ((a[endKey] || a[startKey])
                        - (b[endKey] || b[startKey]))
                    || (a.number - b.number);
            });

            this.renderAllAnnotations();
            this.dismissForm();

            window.scrollTo(0, scrollY);
            this.formElement.scrollIntoView({
                block: 'nearest'
            });
        },

        annotationUpdated(data) {
            this.submitting = false;

            var scrollY = window.pageYOffset
                || document.documentElement.scrollTop;

            var idx = this.annotations.findIndex(
                function(a) {
                    return a.number
                        === data.annotation.number;
                }
            );
            if (idx >= 0)
                this.annotations[idx] = data.annotation;
            this.annotationHTMLMap[\
data.annotation.number]
                = data.renderedHTML;
            this.editingNumber = null;

            if (this.anchorType === 'whole') {
                this.renderWholeAnnotations();
                return;
            }

            this.renderAllAnnotations();

            window.scrollTo(0, scrollY);
        },

        annotationDeleted(number) {
            this.deleting = false;

            var scrollY = window.pageYOffset
                || document.documentElement.scrollTop;

            if (this.expandedNumber === number) {
                this.collapseExpanded();
            }
            this.annotations = this.annotations.filter(
                function(a) {
                    return a.number !== number;
                }
            );
            delete this.annotationHTMLMap[number];

            if (this.anchorType === 'whole') {
                this.renderWholeAnnotations();
                return;
            }

            this.renderAllAnnotations();

            window.scrollTo(0, scrollY);
        },

        isFormVisible() {
            return this.formElement
                && this.formElement.style.display
                    !== 'none';
        },

        focusForm() {
            if (!this.isFormVisible()) return;
            var ta = this.formElement
                ? this.formElement.querySelector(\
'textarea')
                : null;
            if (ta) ta.focus();
        },

        getEscapeContext() {
            if (typeof EmojiAutocomplete \
!== 'undefined') {
                var formTa = this.formElement
                    ? this.formElement.querySelector(\
'textarea') : null;
                if (formTa && EmojiAutocomplete\
.isActive(formTa))
                    return 'emojiPopup';
                if (this.editingNumber !== null) {
                    var editTa = document.querySelector(
                        '.annotation-card[data-number="'
                        + this.editingNumber
                        + '"] .annotation-edit-textarea'
                    );
                    if (editTa && EmojiAutocomplete\
.isActive(editTa))
                        return 'emojiPopup';
                }
            }
            if (this.editingNumber !== null) {
                var card = document.querySelector(
                    '.annotation-card[data-number="'
                    + this.editingNumber + '"]'
                );
                if (card) {
                    var ta = card.querySelector(\
'.annotation-edit-textarea');
                    var ann = this.annotations.find(\
function(a) {
                        return a.number
                            === AnnotationManager\
.editingNumber;
                    });
                    if (ta && ann
                        && ta.value !== ann.content)
                        return 'editing';
                }
                this.cancelEdit();
                return '__consumed__';
            }
            if (this.expandedNumber !== null)
                return 'expanded';
            if (this.isFormVisible()) {
                var ta = this.formElement.querySelector(\
'textarea');
                if (ta && ta.value.trim())
                    return 'formHasText';
                return 'formVisible';
            }
            return 'close';
        },

        dismissForm() {
            if (this.formElement) {
                var ta = this.formElement.querySelector(\
'textarea');
                if (ta) { ta.value = ''; autoGrow(ta); }
                this.formElement.style.display = 'none';
            }
            this.removeSpacer(this.formSpacer,
                this.formSpacerRow);
            this.formSpacer = null;
            this.formSpacerRow = null;
            this.highlightStart = -1;
            this.highlightEnd = -1;
            this.currentBlockIndex = -1;
            this.updateHighlights();
            this.syncAllPositions();
        },

        formatReviewDate(dateStr) {
            var d = new Date(
                dateStr.replace(' ', 'T')
                + (dateStr.indexOf('Z') < 0
                    && dateStr.indexOf('+') < 0
                    ? 'Z' : '')
            );
            if (isNaN(d.getTime())) return 'reviewed';
            var months = ['Jan','Feb','Mar','Apr',\
'May','Jun',
                'Jul','Aug','Sep','Oct','Nov','Dec'];
            return months[d.getMonth()] + ' '
                + d.getDate() + ', '
                + d.getFullYear();
        },

        getFormState() {
            var ta = this.formElement
                ? this.formElement.querySelector(\
'textarea') : null;
            return {
                currentBlockIndex: \
this.currentBlockIndex,
                highlightStart: this.highlightStart,
                highlightEnd: this.highlightEnd,
                formVisible: this.isFormVisible(),
                textareaValue: ta ? ta.value : '',
                expandedNumber: this.expandedNumber
            };
        }
    };

    function handleFileDrop(paths) {
        // Find the active textarea — either the
        // create form or an edit textarea
        var ta = null;
        if (AnnotationManager.formElement
            && AnnotationManager.formElement
                .style.display !== 'none') {
            ta = AnnotationManager.formElement
                .querySelector('textarea');
        }
        if (!ta
            && AnnotationManager.editingNumber
                !== null) {
            ta = document.querySelector(
                '.annotation-card[data-number="'
                + AnnotationManager.editingNumber
                + '"] .annotation-edit-textarea'
            );
        }
        if (!ta) return;

        // Build the text to insert
        var text = paths.map(function(p) {
            return '[' + p + ']';
        }).join(' ');

        // Insert at cursor position
        var start = ta.selectionStart;
        var end = ta.selectionEnd;
        var before = ta.value.substring(0, start);
        var after = ta.value.substring(end);

        // Newline before if not at start of line,
        // newline after
        var prefix = '';
        if (before.length > 0
            && before[before.length - 1] !== '\\n') {
            prefix = '\\n';
        }
        var suffix = '\\n';

        ta.value = before + prefix + text
            + suffix + after;

        // Move cursor to after inserted text
        var newPos = start + prefix.length
            + text.length + suffix.length;
        ta.selectionStart = newPos;
        ta.selectionEnd = newPos;

        // Trigger auto-grow
        ta.dispatchEvent(new Event('input'));
        ta.focus();
    }
"""

// MARK: - Emoji Data / Autocomplete JS

let emojiDataJS: String = {
    guard let url = Bundle.main.url(
        forResource: "emoji-data",
        withExtension: "js"
    ),
        let content = try? String(
            contentsOf: url, encoding: .utf8
        )
    else { return "" }
    return content
}()

let emojiAutocompleteJS: String = {
    guard let url = Bundle.main.url(
        forResource: "emoji-autocomplete",
        withExtension: "js"
    ),
        let content = try? String(
            contentsOf: url, encoding: .utf8
        )
    else { return "" }
    return content
}()

// MARK: - Annotation Coordinator

/// WKScriptMessageHandler that routes annotation
/// messages from the generalized AnnotationManager JS
/// to Swift via a callback.
class AnnotationCoordinator: NSObject,
    WKScriptMessageHandler, WKNavigationDelegate
{
    var lastIsDark: Bool
    var onAnnotationMessage:
        ((AnnotationMessage) -> Void)?
    var pendingInitJS: String?

    init(isDark: Bool) {
        self.lastIsDark = isDark
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "annotation",
              let body = message.body
                  as? [String: Any],
              let action = body["action"] as? String
        else { return }

        switch action {
        case "create":
            let anchorType = body["anchorType"]
                as? String ?? "line_range"
            let content = body["content"]
                as? String ?? ""
            switch anchorType {
            case "row_range":
                guard let startRow = body["startRow"]
                    as? Int,
                      let endRow = body["endRow"]
                    as? Int
                else { return }
                onAnnotationMessage?(.createRowRange(
                    startRow: Int32(startRow),
                    endRow: Int32(endRow),
                    content: content
                ))
            case "block_range":
                guard let startBlock
                    = body["startBlock"] as? Int,
                      let endBlock = body["endBlock"]
                    as? Int
                else { return }
                let blockContent = body["blockContent"]
                    as? String
                onAnnotationMessage?(.createBlockRange(
                    startBlock: Int32(startBlock),
                    endBlock: Int32(endBlock),
                    blockContent: blockContent,
                    content: content
                ))
            case "whole":
                onAnnotationMessage?(.createWhole(
                    content: content
                ))
            default:
                guard let startLine = body["startLine"]
                    as? Int,
                      let endLine = body["endLine"]
                    as? Int
                else { return }
                onAnnotationMessage?(.create(
                    startLine: Int32(startLine),
                    endLine: Int32(endLine),
                    content: content
                ))
            }
        case "update":
            guard let number = body["number"] as? Int,
                  let content = body["content"]
                      as? String
            else { return }
            onAnnotationMessage?(.update(
                number: Int32(number),
                content: content
            ))
        case "delete":
            guard let number = body["number"] as? Int
            else { return }
            onAnnotationMessage?(.delete(
                number: Int32(number)
            ))
        case "confirmDragReplace":
            guard let startIdx = body["startIdx"]
                as? Int,
                  let endIdx = body["endIdx"] as? Int
            else { return }
            onAnnotationMessage?(.confirmDragReplace(
                startIdx: startIdx,
                endIdx: endIdx
            ))
        default:
            break
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor nav: WKNavigationAction,
        decisionHandler: @escaping
            (WKNavigationActionPolicy) -> Void
    ) {
        if nav.navigationType == .linkActivated,
           let url = nav.request.url
        {
            if url.scheme == "http"
                || url.scheme == "https"
            {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        if let js = pendingInitJS {
            webView.evaluateJavaScript(js)
            pendingInitJS = nil
        }
    }
}

// MARK: - Extended AnnotationMessage

/// Extended AnnotationMessage enum that supports all
/// anchor types.
enum AnnotationMessage {
    case create(
        startLine: Int32,
        endLine: Int32,
        content: String
    )
    case createRowRange(
        startRow: Int32,
        endRow: Int32,
        content: String
    )
    case createBlockRange(
        startBlock: Int32,
        endBlock: Int32,
        blockContent: String?,
        content: String
    )
    case createWhole(content: String)
    case update(number: Int32, content: String)
    case delete(number: Int32)
    case confirmDragReplace(startIdx: Int, endIdx: Int)
}

// MARK: - Annotation Init JS Builder

/// Core builder — takes annotation dictionaries directly
/// so different domain types (artifact, snapshot) can feed
/// into the same JS module via small adapter overloads.
func buildAnnotationInitJS(
    anchorType: String,
    blockSelector: String,
    lineAttr: String,
    endLineAttr: String? = nil,
    refPrefix: String,
    itemLabel: String,
    annotationDicts: [[String: Any]],
    htmlMap: [Int32: String]
) -> String {
    let htmlMapDict: [String: String] = {
        var d: [String: String] = [:]
        for (k, v) in htmlMap {
            d[String(k)] = v
        }
        return d
    }()

    let payload: [String: Any] = [
        "anchorType": anchorType,
        "blockSelector": blockSelector,
        "lineAttr": lineAttr,
        "endLineAttr": endLineAttr as Any,
        "refPrefix": refPrefix,
        "itemLabel": itemLabel,
        "annotations": annotationDicts,
        "htmlMap": htmlMapDict,
    ]

    guard let data = try? JSONSerialization.data(
        withJSONObject: payload
    ),
          let json = String(
              data: data, encoding: .utf8
          )
    else { return "" }

    return "AnnotationManager.initialize(\(json))"
}

/// Overload for `[ArtifactAnnotation]` — maps anchor-type
/// variants (line_range / row_range / block_range / whole)
/// into the flat dict shape the JS expects.
func buildAnnotationInitJS(
    anchorType: String,
    blockSelector: String,
    lineAttr: String,
    endLineAttr: String? = nil,
    refPrefix: String,
    itemLabel: String,
    annotations: [ArtifactAnnotation],
    htmlMap: [Int32: String]
) -> String {
    let dicts: [[String: Any]] = annotations.map { a in
        var dict: [String: Any] = [
            "id": a.id,
            "number": a.number,
            "content": a.content,
            "created_at": a.createdAt,
            "updated_at": a.updatedAt,
        ]
        switch a.anchorData.type {
        case .lineRange:
            if let sl = a.anchorData.startLine {
                dict["start_line"] = sl
            }
            if let el = a.anchorData.endLine {
                dict["end_line"] = el
            }
        case .rowRange:
            if let sr = a.anchorData.startRow {
                dict["start_row"] = sr
            }
            if let er = a.anchorData.endRow {
                dict["end_row"] = er
            }
        case .blockRange:
            if let sb = a.anchorData.startBlock {
                dict["start_block"] = sb
            }
            if let eb = a.anchorData.endBlock {
                dict["end_block"] = eb
            }
        case .whole:
            break
        }
        if let rn = a.reviewNumber {
            dict["review_number"] = rn
        }
        if let rra = a.reviewReviewedAt {
            dict["review_reviewed_at"] = rra
        }
        return dict
    }

    return buildAnnotationInitJS(
        anchorType: anchorType,
        blockSelector: blockSelector,
        lineAttr: lineAttr,
        endLineAttr: endLineAttr,
        refPrefix: refPrefix,
        itemLabel: itemLabel,
        annotationDicts: dicts,
        htmlMap: htmlMap
    )
}

/// Overload for `[SnapshotAnnotation]` — snapshots only
/// support `line_range` anchors, so the dict shape is
/// simpler than the artifact variant.
func buildAnnotationInitJS(
    anchorType: String,
    blockSelector: String,
    lineAttr: String,
    endLineAttr: String? = nil,
    refPrefix: String,
    itemLabel: String,
    annotations: [SnapshotAnnotation],
    htmlMap: [Int32: String]
) -> String {
    let dicts: [[String: Any]] = annotations.map { a in
        var dict: [String: Any] = [
            "id": a.id,
            "number": a.number,
            "start_line": a.startLine,
            "end_line": a.endLine,
            "content": a.content,
            "created_at": a.createdAt,
            "updated_at": a.updatedAt,
        ]
        if let rn = a.reviewNumber {
            dict["review_number"] = rn
        }
        if let rra = a.reviewReviewedAt {
            dict["review_reviewed_at"] = rra
        }
        return dict
    }

    return buildAnnotationInitJS(
        anchorType: anchorType,
        blockSelector: blockSelector,
        lineAttr: lineAttr,
        endLineAttr: endLineAttr,
        refPrefix: refPrefix,
        itemLabel: itemLabel,
        annotationDicts: dicts,
        htmlMap: htmlMap
    )
}
