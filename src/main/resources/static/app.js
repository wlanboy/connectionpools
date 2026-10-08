const api = '/api/messages';

const form = document.getElementById('new-message');
const input = document.getElementById('text');
const list = document.getElementById('messages');
const empty = document.getElementById('empty');
const error = document.getElementById('error');

const timeFormat = new Intl.DateTimeFormat('de-DE', {
  dateStyle: 'short',
  timeStyle: 'medium',
});

async function request(url, options = {}) {
  const response = await fetch(url, {
    headers: { 'Content-Type': 'application/json' },
    ...options,
  });
  if (!response.ok) {
    throw new Error(`${options.method || 'GET'} ${url}: ${response.status}`);
  }
  return response.status === 204 ? null : response.json();
}

function showError(e) {
  error.textContent = e.message;
  error.hidden = false;
}

function render(messages) {
  list.replaceChildren(...messages.map(renderRow));
  empty.hidden = messages.length > 0;
}

function renderRow(message) {
  const row = document.createElement('tr');
  row.classList.toggle('done', message.done);

  const okCell = document.createElement('td');
  const checkbox = document.createElement('input');
  checkbox.type = 'checkbox';
  checkbox.checked = message.done;
  checkbox.addEventListener('change', () => toggleDone(message.id, checkbox.checked));
  okCell.append(checkbox);

  const timeCell = document.createElement('td');
  timeCell.className = 'time';
  timeCell.textContent = timeFormat.format(new Date(message.createdAt));

  const textCell = document.createElement('td');
  textCell.className = 'text';
  textCell.textContent = message.text;

  const actionCell = document.createElement('td');
  actionCell.className = 'actions';
  const deleteButton = document.createElement('button');
  deleteButton.type = 'button';
  deleteButton.textContent = 'Löschen';
  deleteButton.addEventListener('click', () => remove(message.id));
  actionCell.append(deleteButton);

  row.append(okCell, timeCell, textCell, actionCell);
  return row;
}

async function load() {
  try {
    render(await request(api));
    error.hidden = true;
  } catch (e) {
    showError(e);
  }
}

async function toggleDone(id, done) {
  try {
    await request(`${api}/${id}`, { method: 'PATCH', body: JSON.stringify({ done }) });
  } catch (e) {
    showError(e);
  }
  await load();
}

async function remove(id) {
  try {
    await request(`${api}/${id}`, { method: 'DELETE' });
  } catch (e) {
    showError(e);
  }
  await load();
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const text = input.value.trim();
  if (!text) return;
  try {
    await request(api, { method: 'POST', body: JSON.stringify({ text }) });
    input.value = '';
  } catch (e) {
    showError(e);
  }
  await load();
});

load();
