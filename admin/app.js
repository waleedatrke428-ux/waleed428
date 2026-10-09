(() => {
  'use strict';

  const apiBase = window.APP_API_BASE_URL || window.location.origin;
  const state = { token: null, statusTimer: null };
  const element = (id) => document.getElementById(id);
  const statusElement = element('status-message');

  function showStatus(message) {
    statusElement.textContent = message;
    window.clearTimeout(state.statusTimer);
    state.statusTimer = window.setTimeout(() => {
      statusElement.textContent = '';
    }, 5000);
  }

  async function api(path, options = {}) {
    const headers = new Headers(options.headers || {});
    headers.set('Accept', 'application/json');
    if (options.body) headers.set('Content-Type', 'application/json');
    if (state.token) headers.set('Authorization', `Bearer ${state.token}`);
    let response;
    try {
      response = await fetch(new URL(path, apiBase), { ...options, headers });
    } catch {
      throw new Error('تعذّر الاتصال بالخادم.');
    }
    const payload = response.status === 204 ? {} : await response.json().catch(() => ({}));
    if (!response.ok) {
      const message = payload.message || payload.detail || `فشل الطلب (${response.status}).`;
      if (response.status === 401 || response.status === 403) logout(false);
      throw new Error(message);
    }
    return payload;
  }

  function setCell(row, value) {
    const cell = document.createElement('td');
    cell.textContent = value == null ? '—' : String(value);
    row.appendChild(cell);
    return cell;
  }

  function setView(viewName) {
    for (const view of document.querySelectorAll('.view')) {
      view.hidden = view.id !== `${viewName}-view`;
    }
    for (const tab of document.querySelectorAll('.tab')) {
      const active = tab.dataset.view === viewName;
      tab.classList.toggle('active', active);
      tab.setAttribute('aria-current', active ? 'page' : 'false');
    }
    if (viewName === 'users') void loadUsers();
    if (viewName === 'signals') void loadSignals();
    if (viewName === 'settings') void loadSettings();
  }

  function enterDashboard() {
    element('login-panel').hidden = true;
    element('dashboard').hidden = false;
    element('logout-button').hidden = false;
    setView('overview');
    void refreshOverview();
  }

  function logout(showMessage = true) {
    state.token = null;
    element('login-panel').hidden = false;
    element('dashboard').hidden = true;
    element('logout-button').hidden = true;
    if (showMessage) showStatus('تم تسجيل الخروج.');
  }

  async function refreshOverview() {
    try {
      const [users, signals] = await Promise.all([
        api('/api/admin/users'),
        api('/api/admin/signals'),
      ]);
      element('user-count').textContent = String(items(users).length);
      element('signal-count').textContent = String(items(signals).length);
    } catch (error) {
      showStatus(error.message);
    }
  }

  function items(payload) {
    return Array.isArray(payload.items) ? payload.items : [];
  }

  async function loadUsers() {
    const body = element('users-table');
    body.replaceChildren();
    try {
      const payload = await api('/api/admin/users');
      for (const user of items(payload)) {
        const row = document.createElement('tr');
        setCell(row, user.email);
        setCell(row, user.phone);
        setCell(row, user.accessEndsAt || user.expiresAt || user.trialEndsAt);
        setCell(row, user.status);
        const action = setCell(row, '');
        const button = document.createElement('button');
        button.className = 'small-button';
        button.type = 'button';
        button.textContent = 'إضافة شهر';
        button.addEventListener('click', () => extendSubscription(user.id, button));
        action.appendChild(button);
        body.appendChild(row);
      }
      if (body.childElementCount === 0) emptyRow(body, 5, 'لا يوجد مستخدمون.');
    } catch (error) {
      showStatus(error.message);
    }
  }

  async function extendSubscription(userId, button) {
    if (!userId) {
      showStatus('معرّف المستخدم غير صالح.');
      return;
    }
    button.disabled = true;
    try {
      await api(`/api/admin/users/${encodeURIComponent(userId)}/subscriptions`, {
        method: 'POST',
        body: JSON.stringify({ months: 1 }),
      });
      showStatus('تم تحديث الاشتراك.');
      await loadUsers();
    } catch (error) {
      showStatus(error.message);
    } finally {
      button.disabled = false;
    }
  }

  async function loadSignals() {
    const body = element('signals-table');
    body.replaceChildren();
    try {
      const payload = await api('/api/admin/signals');
      for (const signal of items(payload)) {
        const row = document.createElement('tr');
        setCell(row, signal.symbol);
        setCell(row, signal.exchange);
        setCell(row, signal.side || signal.direction);
        setCell(row, signal.score == null ? '' : `${signal.score}/100`);
        setCell(row, signal.status);
        setCell(row, signal.createdAt);
        body.appendChild(row);
      }
      if (body.childElementCount === 0) emptyRow(body, 6, 'لا توجد إشارات منشورة.');
    } catch (error) {
      showStatus(error.message);
    }
  }

  async function loadSettings() {
    try {
      const payload = await api('/api/admin/settings');
      const settings = payload.settings || payload;
      const score = Number(settings.minimumSignalScore);
      element('score-input').value = String(Number.isFinite(score) ? Math.max(65, score) : 65);
      const enabled = new Set(Array.isArray(settings.exchanges) ? settings.exchanges : []);
      for (const checkbox of document.querySelectorAll('input[name="exchange"]')) {
        checkbox.checked = enabled.has(checkbox.value);
      }
    } catch (error) {
      showStatus(error.message);
    }
  }

  function emptyRow(body, columns, message) {
    const row = document.createElement('tr');
    const cell = document.createElement('td');
    cell.colSpan = columns;
    cell.textContent = message;
    row.appendChild(cell);
    body.appendChild(row);
  }

  element('login-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    const button = event.currentTarget.querySelector('button[type="submit"]');
    button.disabled = true;
    try {
      const result = await api('/api/auth/login', {
        method: 'POST',
        body: JSON.stringify({
          email: element('email-input').value.trim(),
          password: element('password-input').value,
        }),
      });
      const token = result.accessToken || result.access_token || result.token;
      if (typeof token !== 'string' || token.length < 16) {
        throw new Error('استجابة تسجيل الدخول لا تحتوي رمزاً صالحاً.');
      }
      if (result.role !== 'admin') {
        throw new Error('هذا الحساب لا يملك صلاحية المشرف.');
      }
      state.token = token;
      enterDashboard();
    } catch (error) {
      showStatus(error.message);
    } finally {
      button.disabled = false;
    }
  });

  element('logout-button').addEventListener('click', () => logout());
  for (const tab of document.querySelectorAll('.tab')) {
    tab.addEventListener('click', () => setView(tab.dataset.view));
  }
  for (const button of document.querySelectorAll('[data-refresh]')) {
    button.addEventListener('click', () => {
      if (button.dataset.refresh === 'users') void loadUsers();
      if (button.dataset.refresh === 'signals') void loadSignals();
    });
  }

  element('settings-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    const score = Number(element('score-input').value);
    if (!Number.isInteger(score) || score < 65 || score > 100) {
      showStatus('يجب أن تكون الدرجة بين 65 و100.');
      return;
    }
    const exchanges = [...document.querySelectorAll('input[name="exchange"]:checked')]
      .map((input) => input.value);
    try {
      await api('/api/admin/settings', {
        method: 'PUT',
        body: JSON.stringify({ minimumSignalScore: score, exchanges }),
      });
      showStatus('تم حفظ الإعدادات.');
    } catch (error) {
      showStatus(error.message);
    }
  });
})();
