/* EbookViewer が本文に注入するページ送りスクリプト。
   ホスト (WKWebView) とは window.webkit.messageHandlers.ev.postMessage / window.__ev.* でやり取りする。 */
(function () {
  'use strict';
  if (window.__ev) { return; }

  var S = window.__EV_SETTINGS__ || {};
  var vertical = !!S.vertical;
  var pad = (S.padding == null) ? 32 : S.padding;
  var page = 0;
  var pages = 1;
  var step = 1;
  var colSize = 1;
  var html = document.documentElement;
  var body = null;
  var ready = false;
  var resizeTimer = null;
  var wheelLock = 0;

  function post(msg) {
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ev) {
        window.webkit.messageHandlers.ev.postMessage(msg);
      }
    } catch (e) { /* ホスト無し (ブラウザで直接開いた場合) */ }
  }

  function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); }

  /* スクリプトエラーはホストに知らせる (デバッグ用) */
  window.addEventListener('error', function (e) {
    post({ type: 'error', message: String(e.message || e.error || e) + ' @' + (e.filename || '') + ':' + (e.lineno || 0) });
  });

  /* page-break-* / break-* を段区切りに変換する (多段組みでは page ブレークが効かないため) */
  function convertPageBreaks() {
    var inlineTags = { SPAN: 1, A: 1, RUBY: 1, RT: 1, RB: 1, RP: 1, EM: 1, STRONG: 1, B: 1, I: 1, IMG: 1, BR: 1, SUP: 1, SUB: 1, SMALL: 1, U: 1, S: 1 };
    var els = body.getElementsByTagName('*');
    var n = els.length;
    if (n > 40000) { return; }
    for (var i = 0; i < n; i++) {
      var el = els[i];
      if (inlineTags[el.tagName]) { continue; }
      var cs = window.getComputedStyle(el);
      var bb = cs.breakBefore || cs.pageBreakBefore;
      var ba = cs.breakAfter || cs.pageBreakAfter;
      if (bb === 'page' || bb === 'always' || bb === 'left' || bb === 'right' || bb === 'recto' || bb === 'verso') {
        el.classList.add('__ev-break-before');
      }
      if (ba === 'page' || ba === 'always' || ba === 'left' || ba === 'right' || ba === 'recto' || ba === 'verso') {
        el.classList.add('__ev-break-after');
      }
    }
  }

  function layout() {
    var w = html.clientWidth;
    var h = html.clientHeight;
    if (!w || !h) { return; }
    body.classList.toggle('__ev-vertical', vertical);
    body.classList.toggle('__ev-horizontal', !vertical);
    var st = body.style;
    st.setProperty('width', w + 'px', 'important');
    st.setProperty('height', h + 'px', 'important');
    st.setProperty('padding', pad + 'px', 'important');
    colSize = (vertical ? h : w) - 2 * pad;
    if (colSize < 40) { colSize = 40; }
    st.setProperty('column-width', colSize + 'px', 'important');
    st.setProperty('column-gap', (2 * pad) + 'px', 'important');
    step = colSize + 2 * pad;
    var total = vertical ? body.scrollHeight : body.scrollWidth;
    pages = Math.max(1, Math.round((total + pad) / step));
    if (page > pages - 1) { page = pages - 1; }
  }

  function scrollToPage(p) {
    if (vertical) {
      body.scrollTop = p * step;
      body.scrollLeft = 0;
    } else {
      body.scrollLeft = p * step;
      body.scrollTop = 0;
    }
  }

  function report(extra) {
    var msg = { type: 'page', page: page, pages: pages };
    if (extra) { for (var k in extra) { msg[k] = extra[k]; } }
    post(msg);
  }

  function goto(p) {
    p = clamp(Math.round(p) || 0, 0, pages - 1);
    page = p;
    scrollToPage(p);
    report();
  }

  function next() {
    if (page + 1 < pages) { goto(page + 1); }
    else { post({ type: 'next-chapter' }); }
  }

  function prev() {
    if (page > 0) { goto(page - 1); }
    else { post({ type: 'prev-chapter' }); }
  }

  function rectOf(el) {
    var r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0 && r.top === 0 && r.left === 0) {
      /* 空のインライン要素は矩形を持たないことがあるので、次の要素か親で代用する */
      var alt = el.nextElementSibling || el.parentElement;
      if (alt && alt !== body) { return alt.getBoundingClientRect(); }
    }
    return r;
  }

  function pageOf(el) {
    var r = rectOf(el);
    var off = vertical ? (r.top + body.scrollTop - pad) : (r.left + body.scrollLeft - pad);
    return clamp(Math.floor((off + 2) / step), 0, pages - 1);
  }

  function findAnchor(id) {
    if (!id) { return null; }
    var el = document.getElementById(id);
    if (!el) {
      var named = document.getElementsByName(id);
      if (named && named.length) { el = named[0]; }
    }
    if (!el) {
      try { el = document.querySelector('[aid="' + id.replace(/^aid_/, '') + '"]'); } catch (e) { el = null; }
    }
    return el;
  }

  function gotoAnchor(id) {
    var el = findAnchor(id);
    if (!el) { goto(0); return false; }
    goto(pageOf(el));
    return true;
  }

  function applyInitial() {
    var i = S.initial || {};
    if (i.type === 'end') { goto(pages - 1); }
    else if (i.type === 'anchor') { gotoAnchor(i.id); }
    else if (i.type === 'fraction') { goto(Math.round((i.value || 0) * (pages - 1))); }
    else { goto(i.page || 0); }
  }

  function relayout() {
    var f = pages > 1 ? page / (pages - 1) : 0;
    layout();
    goto(Math.round(f * (pages - 1)));
  }

  function onReady() {
    if (ready) { return; }
    body = document.body;
    if (!body) { return; }
    ready = true;
    convertPageBreaks();
    layout();
    applyInitial();
    post({ type: 'ready', page: page, pages: pages });
    if (document.fonts && document.fonts.ready) {
      document.fonts.ready.then(function () { relayout(); });
    }
  }

  function onKey(e) {
    /* Cmd (macOS) / Alt 付きはアプリのメニューに任せる */
    if (e.altKey || e.metaKey) { return; }
    if (e.ctrlKey) {
      var ck = e.key;
      if (ck === 't' || ck === 'T' || ck === 'o' || ck === 'O' || ck === '+' || ck === '-' || ck === '=' || ck === ';') {
        e.preventDefault();
        post({ type: 'key', key: ck, ctrl: true });
      }
      return;
    }
    var k = e.key;
    var forward = null;
    if (k === 'PageDown' || (k === ' ' && !e.shiftKey) || k === 'Enter') { forward = true; }
    else if (k === 'PageUp' || (k === ' ' && e.shiftKey) || k === 'Backspace') { forward = false; }
    else if (k === 'ArrowLeft') { forward = vertical; }
    else if (k === 'ArrowRight') { forward = !vertical; }
    else if (k === 'ArrowDown') { forward = true; }
    else if (k === 'ArrowUp') { forward = false; }
    else if (k === 'Home') { e.preventDefault(); goto(0); return; }
    else if (k === 'End') { e.preventDefault(); goto(pages - 1); return; }
    else { post({ type: 'key', key: k, shift: e.shiftKey }); return; }
    e.preventDefault();
    if (forward) { next(); } else { prev(); }
  }

  function onWheel(e) {
    e.preventDefault();
    var now = Date.now();
    if (now - wheelLock < 220) { return; }
    var d = Math.abs(e.deltaY) >= Math.abs(e.deltaX) ? e.deltaY : (vertical ? -e.deltaX : e.deltaX);
    if (d === 0) { return; }
    wheelLock = now;
    if (d > 0) { next(); } else { prev(); }
  }

  function onClick(e) {
    var a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
    if (a) {
      e.preventDefault();
      post({ type: 'link', href: a.href });
      return;
    }
    if (e.target && e.target.closest && e.target.closest('img')) { return; }
    var sel = window.getSelection && window.getSelection();
    if (sel && sel.type === 'Range' && sel.toString().length > 0) { return; }
    var x = e.clientX / html.clientWidth;
    if (x < 0.25) { if (vertical) { next(); } else { prev(); } }
    else if (x > 0.75) { if (vertical) { prev(); } else { next(); } }
    else { post({ type: 'tap-center' }); }
  }

  /* iOS / iPadOS: スワイプでページ送り。縦書きは左右どちらの向きでも「進む = 右へ払う」(右綴じ) */
  var touchStart = null;
  function onTouchStart(e) {
    if (e.touches.length !== 1) { touchStart = null; return; }
    touchStart = { x: e.touches[0].clientX, y: e.touches[0].clientY, t: Date.now() };
  }
  function onTouchEnd(e) {
    if (!touchStart || e.changedTouches.length !== 1) { return; }
    var dx = e.changedTouches[0].clientX - touchStart.x;
    var dy = e.changedTouches[0].clientY - touchStart.y;
    var dt = Date.now() - touchStart.t;
    touchStart = null;
    if (dt > 800) { return; }
    var horizontalSwipe = Math.abs(dx) > 40 && Math.abs(dx) > Math.abs(dy) * 1.5;
    var verticalSwipe = Math.abs(dy) > 40 && Math.abs(dy) > Math.abs(dx) * 1.5;
    if (horizontalSwipe) {
      /* 右へ払う: 縦書きなら次のページ (右綴じ)、横書きなら前のページ */
      if (dx > 0) { if (vertical) { next(); } else { prev(); } }
      else { if (vertical) { prev(); } else { next(); } }
    } else if (verticalSwipe) {
      if (dy < 0) { next(); } else { prev(); }
    }
  }
  function onTouchMove(e) {
    /* 本文はページ単位で送るのでネイティブスクロールを止める */
    if (e.touches.length === 1) { e.preventDefault(); }
  }

  function onResize() {
    if (!ready) { return; }
    if (resizeTimer) { clearTimeout(resizeTimer); }
    resizeTimer = setTimeout(function () { resizeTimer = null; relayout(); }, 120);
  }

  window.__ev = {
    next: next,
    prev: prev,
    goto: goto,
    gotoAnchor: gotoAnchor,
    gotoEnd: function () { goto(pages - 1); },
    relayout: relayout,
    setVertical: function (v) { vertical = !!v; relayout(); },
    info: function () { return { page: page, pages: pages, step: step, vertical: vertical }; }
  };

  document.addEventListener('keydown', onKey, false);
  document.addEventListener('wheel', onWheel, { passive: false });
  document.addEventListener('click', onClick, false);
  document.addEventListener('touchstart', onTouchStart, { passive: true });
  document.addEventListener('touchmove', onTouchMove, { passive: false });
  document.addEventListener('touchend', onTouchEnd, { passive: true });
  window.addEventListener('resize', onResize, false);
  window.addEventListener('load', function () { onReady(); relayout(); }, false);
  if (document.readyState === 'complete' || document.readyState === 'interactive') { onReady(); }
  else { document.addEventListener('DOMContentLoaded', onReady, false); }
})();
