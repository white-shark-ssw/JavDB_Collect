(() => {
    if (window.JavDBCollect) return;

    const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.javdbCollect;
    const originKey = 'jdcMovieOrigin';
    const restoreKey = 'jdcRestoreOrigin';
    let reportTimer = null;
    let restoreTimer = null;

    function post(message) {
        if (bridge) bridge.postMessage(message);
    }

    function sessionGet(key) {
        try { return sessionStorage.getItem(key); } catch (_) { return null; }
    }

    function sessionSet(key, value) {
        try { sessionStorage.setItem(key, value); return true; } catch (_) { return false; }
    }

    function sessionRemove(key) {
        try { sessionStorage.removeItem(key); } catch (_) {}
    }

    function normalizedPageURL(value) {
        try {
            const url = new URL(value, location.href);
            url.hash = '';
            return url.href;
        } catch (_) {
            return String(value || '');
        }
    }

    function movieIdFromURL(value) {
        try {
            const url = new URL(value, location.href);
            const match = url.pathname.match(/^\/v\/([^/?#]+)/);
            return match ? match[1] : null;
        } catch (_) {
            return null;
        }
    }

    function currentMovieId() {
        return movieIdFromURL(location.href);
    }

    function visibleMovieIds() {
        const ids = new Set();
        document.querySelectorAll('a[href*="/v/"]').forEach(anchor => {
            const id = movieIdFromURL(anchor.href);
            if (id) ids.add(id);
        });
        const current = currentMovieId();
        if (current) ids.add(current);
        return Array.from(ids);
    }

    function scheduleVisibleReport() {
        clearTimeout(reportTimer);
        reportTimer = setTimeout(() => post({ type: 'visibleMovies', ids: visibleMovieIds() }), 180);
    }

    function captureMovieOrigin(event) {
        const target = event.target instanceof Element ? event.target : null;
        const anchor = target?.closest('a[href*="/v/"]');
        if (!anchor) return;
        const id = movieIdFromURL(anchor.href);
        if (!id) return;
        const host = anchor.closest('.item') || anchor;
        const rect = host.getBoundingClientRect();
        const state = {
            id,
            url: normalizedPageURL(location.href),
            scrollY: Math.max(window.scrollY || document.documentElement.scrollTop || 0, 0),
            viewportTop: Number.isFinite(rect.top) ? rect.top : 0,
            capturedAt: Date.now()
        };
        sessionSet(originKey, JSON.stringify(state));
    }

    function armReturnToOrigin(id) {
        try {
            const origin = JSON.parse(sessionGet(originKey) || 'null');
            if (!origin || origin.id !== id || !origin.url) return false;
            sessionSet(restoreKey, JSON.stringify(origin));
            return true;
        } catch (_) {
            return false;
        }
    }

    function findMovieAnchor(id) {
        return Array.from(document.querySelectorAll('a[href*="/v/"]')).find(anchor => movieIdFromURL(anchor.href) === id) || null;
    }

    function maybeRestoreOrigin() {
        if (restoreTimer !== null) return;
        let state;
        try { state = JSON.parse(sessionGet(restoreKey) || 'null'); } catch (_) { state = null; }
        if (!state || !state.id || !state.url) return;
        if (normalizedPageURL(location.href) !== state.url) return;

        let attempts = 0;
        let foundCount = 0;
        restoreTimer = -1;

        const step = () => {
            attempts += 1;
            const savedY = Math.max(Number(state.scrollY) || 0, 0);
            const anchor = findMovieAnchor(state.id);
            if (!anchor) {
                window.scrollTo(0, savedY);
            } else {
                const host = anchor.closest('.item') || anchor;
                const desiredTop = Number(state.viewportTop);
                if (Number.isFinite(desiredTop)) {
                    const delta = host.getBoundingClientRect().top - desiredTop;
                    if (Math.abs(delta) > 2) window.scrollBy(0, delta);
                } else {
                    host.scrollIntoView({ block: 'center', behavior: 'auto' });
                }
                foundCount += 1;
            }

            if ((foundCount >= 3 && attempts >= 3) || attempts >= 24) {
                sessionRemove(restoreKey);
                restoreTimer = null;
                return;
            }
            restoreTimer = setTimeout(step, foundCount > 0 ? 220 : 160);
        };

        step();
    }

    function extractCode() {
        let code = '';
        document.querySelectorAll('.panel-block, .video-meta-panel').forEach(element => {
            if (code) return;
            const text = (element.innerText || '').replace(/\s+/g, ' ');
            const match = text.match(/(?:番號|番号|ID)\s*[:：]?\s*([A-Za-z0-9]+[-_][A-Za-z0-9]+)/i);
            if (match) code = match[1].toUpperCase();
        });
        if (!code) {
            const match = document.title.match(/\b([A-Za-z]{2,12}[-_]\d{2,6})\b/i);
            if (match) code = match[1].toUpperCase();
        }
        return code;
    }

    function parseSizeGB(text) {
        const match = String(text || '').match(/([\d.]+)\s*(TB|GB|MB)/i);
        if (!match) return 0;
        const number = parseFloat(match[1]) || 0;
        const unit = match[2].toUpperCase();
        if (unit === 'TB') return number * 1024;
        if (unit === 'MB') return number / 1024;
        return number;
    }

    function parseFileCount(text) {
        const match = String(text || '').match(/(\d+)\s*(?:個|个)?\s*(?:文件|檔案|档案|files?)/i);
        return match ? parseInt(match[1], 10) || 0 : 0;
    }

    function magnetCandidates() {
        const rows = Array.from(document.querySelectorAll('#magnets-content .item'));
        const candidates = [];
        const seen = new Set();

        function appendFromRow(row) {
            const anchor = row.querySelector('a[href^="magnet:"]');
            if (!anchor || seen.has(anchor.href)) return;
            seen.add(anchor.href);
            const name = (row.querySelector('.name')?.textContent || anchor.textContent || '').trim();
            const meta = (row.querySelector('.meta')?.textContent || '').replace(/\s+/g, ' ').trim();
            const tags = Array.from(row.querySelectorAll('.tag')).map(tag => (tag.textContent || '').trim()).filter(Boolean);
            candidates.push({ magnet: anchor.href, name, meta, tags, sizeGB: parseSizeGB(meta), fileCount: parseFileCount(meta) });
        }

        rows.forEach(appendFromRow);
        if (!rows.length) {
            document.querySelectorAll('a[href^="magnet:"]').forEach(anchor => appendFromRow(anchor.closest('.item') || anchor.parentElement || anchor));
        }
        return candidates;
    }

    function collectCurrent() {
        const javdbId = currentMovieId();
        if (!javdbId) return JSON.stringify({ error: 'not_detail_page' });

        const titleElement = document.querySelector('h2.title, .video-title, .title.is-4');
        const rawTitle = (titleElement?.innerText || document.title.split('|')[0] || '').replace(/\s+/g, ' ').trim();
        const code = extractCode();
        const title = rawTitle || code || javdbId;
        const cover = document.querySelector('.video-cover img, .column-video-cover img, img[src*="cover"]');
        const candidates = magnetCandidates();

        return JSON.stringify({ javdbId, code: code || javdbId, title, coverUrl: cover?.src || '', candidates });
    }

    function addCardBadge(anchor, id) {
        const image = anchor.querySelector('img') || anchor.closest('.item')?.querySelector('img');
        if (!image) return;
        const host = anchor.closest('.item') || anchor;
        if (host.querySelector(`.jdc-collected-badge[data-jdc-id="${CSS.escape(id)}"]`)) return;
        const style = getComputedStyle(host);
        if (style.position === 'static') host.style.position = 'relative';
        const badge = document.createElement('div');
        badge.className = 'jdc-collected-badge';
        badge.dataset.jdcId = id;
        badge.textContent = '✓ 已采集';
        Object.assign(badge.style, {
            position: 'absolute', top: '6px', right: '6px', zIndex: '20', padding: '3px 7px', borderRadius: '10px',
            background: 'rgba(0,145,90,.92)', color: '#fff', fontSize: '12px', lineHeight: '16px', fontWeight: '600',
            boxShadow: '0 1px 4px rgba(0,0,0,.25)', pointerEvents: 'none'
        });
        host.appendChild(badge);
    }

    function applyCollected(ids) {
        const collected = new Set(ids || []);
        document.querySelectorAll('.jdc-collected-badge').forEach(badge => {
            if (!collected.has(badge.dataset.jdcId || '')) badge.remove();
        });

        document.querySelectorAll('a[href*="/v/"]').forEach(anchor => {
            const id = movieIdFromURL(anchor.href);
            if (id && collected.has(id)) addCardBadge(anchor, id);
        });

        const current = currentMovieId();
        let detailBadge = document.getElementById('jdc-detail-collected');
        if (current && collected.has(current)) {
            if (!detailBadge) {
                detailBadge = document.createElement('div');
                detailBadge.id = 'jdc-detail-collected';
                detailBadge.dataset.jdcId = current;
                detailBadge.textContent = '✓ 已采集';
                Object.assign(detailBadge.style, {
                    position: 'fixed', top: '72px', right: '12px', zIndex: '2147483000', padding: '6px 10px', borderRadius: '14px',
                    background: 'rgba(0,145,90,.94)', color: '#fff', fontSize: '13px', lineHeight: '18px', fontWeight: '600',
                    boxShadow: '0 2px 8px rgba(0,0,0,.25)', pointerEvents: 'none'
                });
                document.body.appendChild(detailBadge);
            }
        } else if (detailBadge) {
            detailBadge.remove();
        }
    }

    document.addEventListener('click', captureMovieOrigin, true);
    window.addEventListener('pageshow', () => {
        scheduleVisibleReport();
        setTimeout(maybeRestoreOrigin, 30);
    });

    const observer = new MutationObserver(() => {
        scheduleVisibleReport();
        maybeRestoreOrigin();
    });
    observer.observe(document.documentElement, { childList: true, subtree: true });
    window.addEventListener('load', () => {
        scheduleVisibleReport();
        setTimeout(maybeRestoreOrigin, 30);
    }, { once: true });

    window.JavDBCollect = { collectCurrent, applyCollected, reportVisible: scheduleVisibleReport, armReturnToOrigin, restoreOrigin: maybeRestoreOrigin };
    setTimeout(() => {
        scheduleVisibleReport();
        maybeRestoreOrigin();
    }, 250);
})();
