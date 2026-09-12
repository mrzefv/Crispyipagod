import {
  cycleMapStyle,
  closeTimeline,
  createInitialState,
  finishLoading,
  getFilteredLocations,
  getLocationById,
  jumpToEvent,
  locations,
  openTimeline,
  selectLocation,
  setActiveTab,
  setSearchQuery,
  setSelectedTime,
  timelineEvents,
  toggleBookmark,
  toggleDetailExpanded,
  togglePlayback,
  updateSetting,
} from "./app-state.js";

const app = document.querySelector("#app");
const quickFocusLocationId = "andes-array";
let state = createInitialState();
let playbackTimer;

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (character) => (
    {
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;",
    }[character]
  ));
}

function setState(nextState) {
  state = nextState;
  render();
}

function loadCoreAssets() {
  return Promise.all([
    document.fonts?.ready ?? Promise.resolve(),
    new Promise((resolve) => setTimeout(resolve, 900)),
  ]);
}

function startPlayback() {
  stopPlayback();
  playbackTimer = window.setInterval(() => {
    const nextTime = state.selectedTime >= 100 ? 0 : state.selectedTime + 5;
    state = setSelectedTime(state, nextTime);
    render();
  }, 700);
}

function stopPlayback() {
  if (playbackTimer) {
    window.clearInterval(playbackTimer);
    playbackTimer = undefined;
  }
}

function shareLocation(location) {
  const message = `Shared ${location.name} (${location.coordinates}) at t=${state.selectedTime}`;
  window.alert(message);
}

function locationButton(location) {
  const selected = location.id === state.selectedLocationId;
  return `
    <button
      class="marker ${selected ? "marker--selected" : ""}"
      style="left: ${location.marker.x}%; top: ${location.marker.y}%"
      data-action="select-location"
      data-location-id="${escapeHtml(location.id)}"
      aria-label="Open details for ${escapeHtml(location.name)}"
    >
      <span></span>
    </button>
  `;
}

function renderSplash() {
  return `
    <section class="splash-screen">
      <div class="splash-logo" aria-hidden="true">◎</div>
      <h1>Gods Eye IPA</h1>
      <p>${escapeHtml(state.status)}</p>
    </section>
  `;
}

function renderTopBar(selectedLocation) {
  const searchResults = getFilteredLocations(state.searchQuery);
  return `
    <header class="top-bar">
      <label class="search-field">
        <span>Search</span>
        <input
          type="search"
          placeholder="Search regions or coordinates"
          data-role="search"
        />
      </label>
      <button class="glass-button" data-action="toggle-layers">Layers · ${escapeHtml(state.mapStyle)}</button>
      <button class="glass-button" data-action="open-timeline">Time ${escapeHtml(state.selectedTime)}</button>
      ${
        state.searchQuery
          ? `<div class="search-results">${searchResults
              .map(
                (location) => `
                  <button data-action="select-location" data-location-id="${escapeHtml(location.id)}">
                    <strong>${escapeHtml(location.name)}</strong>
                    <span>${escapeHtml(location.coordinates)}</span>
                  </button>
                `,
              )
              .join("")}</div>`
          : ""
      }
      <div class="home-status">${escapeHtml(selectedLocation.region)}</div>
    </header>
  `;
}

function renderBottomPanel(selectedLocation) {
  return `
    <section class="bottom-panel">
      <div>
        <p class="eyebrow">Current location</p>
        <h2>${escapeHtml(selectedLocation.name)}</h2>
        <p>${escapeHtml(selectedLocation.coordinates)}</p>
      </div>
      <div class="quick-actions">
        <button data-action="select-location" data-location-id="${escapeHtml(quickFocusLocationId)}">Focus Andes</button>
        <button data-action="open-timeline">Timeline</button>
      </div>
    </section>
  `;
}

function renderGlobe(selectedLocation, overlayContent = "") {
  return `
    <main class="globe-stage" aria-label="Interactive globe view">
      <div class="globe globe--${state.mapStyle.toLowerCase()}">
        <div class="globe-core"></div>
        <div class="globe-grid"></div>
        ${locations.map(locationButton).join("")}
      </div>
      ${overlayContent}
    </main>
  `;
}

function renderDetailSheet(selectedLocation) {
  const isSaved = state.savedLocationIds.includes(selectedLocation.id);
  return `
    <section class="detail-sheet ${state.detailExpanded ? "detail-sheet--expanded" : ""}">
      <button class="sheet-handle" data-action="toggle-detail" aria-label="Toggle detail size"></button>
      <div class="sheet-heading">
        <div>
          <p class="eyebrow">Location detail</p>
          <h3>${escapeHtml(selectedLocation.name)}</h3>
          <p>${escapeHtml(selectedLocation.coordinates)}</p>
        </div>
        <button class="glass-button" data-action="toggle-detail">
          ${state.detailExpanded ? "Minimize" : "Expand"}
        </button>
      </div>
      <p>${escapeHtml(selectedLocation.summary)}</p>
      <dl class="metadata-grid">
        <div><dt>Region</dt><dd>${escapeHtml(selectedLocation.region)}</dd></div>
        <div><dt>Elevation</dt><dd>${escapeHtml(selectedLocation.metadata.elevation)}</dd></div>
        <div><dt>Visibility</dt><dd>${escapeHtml(selectedLocation.metadata.visibility)}</dd></div>
        <div><dt>Coverage</dt><dd>${escapeHtml(selectedLocation.metadata.coverage)}</dd></div>
      </dl>
      <div class="sheet-actions">
        <button data-action="toggle-bookmark">${isSaved ? "Remove bookmark" : "Save bookmark"}</button>
        <button data-action="open-timeline">Open timeline</button>
        <button data-action="share-location">Share</button>
      </div>
    </section>
  `;
}

function renderTimeline() {
  return `
    <section class="timeline-screen">
      <div class="timeline-header">
        <div>
          <p class="eyebrow">Playback</p>
          <h2>Historical timeline</h2>
          <p>Selected time ${escapeHtml(state.selectedTime)}</p>
        </div>
        <button class="glass-button" data-action="close-timeline">Back to globe</button>
      </div>
      <div class="timeline-controls">
        <button data-action="jump-event" data-direction="-1">Previous event</button>
        <button data-action="toggle-playback">${state.isPlaying ? "Pause" : "Play"}</button>
        <button data-action="jump-event" data-direction="1">Next event</button>
      </div>
      <label class="timeline-range">
        <span>Time scrubber</span>
        <input type="range" min="0" max="100" value="${state.selectedTime}" data-role="timeline-range" />
      </label>
      <div class="event-markers">
        ${timelineEvents
          .map(
            (event) => `
              <button
                class="event-marker ${event.time === state.selectedTime ? "event-marker--active" : ""}"
                style="left: ${event.time}%"
                data-action="timeline-event"
                data-time="${event.time}"
              >
                <span>${escapeHtml(event.label)}</span>
              </button>
            `,
          )
          .join("")}
      </div>
    </section>
  `;
}

function renderSaved() {
  const savedLocations = state.savedLocationIds.map(getLocationById);
  return `
    <section class="panel-screen">
      <div class="panel-header">
        <div>
          <p class="eyebrow">Saved</p>
          <h2>Bookmarked locations</h2>
        </div>
      </div>
      <div class="saved-list">
        ${
          savedLocations.length
            ? savedLocations
                .map(
                  (location) => `
                    <button class="saved-card" data-action="select-location" data-location-id="${escapeHtml(location.id)}">
                      <strong>${escapeHtml(location.name)}</strong>
                      <span>${escapeHtml(location.coordinates)}</span>
                    </button>
                  `,
                )
                .join("")
            : '<p class="empty-state">Save a location from the detail sheet to keep it here.</p>'
        }
      </div>
    </section>
  `;
}

function renderSettings() {
  return `
    <section class="panel-screen">
      <div class="panel-header">
        <div>
          <p class="eyebrow">Settings</p>
          <h2>Display and performance</h2>
        </div>
      </div>
      <div class="settings-grid">
        <label>
          <span>Theme</span>
          <select data-setting="theme">
            ${["Midnight", "Aurora", "Slate"]
              .map((option) => `<option ${state.theme === option ? "selected" : ""}>${option}</option>`)
              .join("")}
          </select>
        </label>
        <label>
          <span>Map style</span>
          <select data-setting="mapStyle">
            ${["Globe", "Terrain", "Signal"]
              .map((option) => `<option ${state.mapStyle === option ? "selected" : ""}>${option}</option>`)
              .join("")}
          </select>
        </label>
        <label>
          <span>Performance mode</span>
          <select data-setting="performanceMode">
            ${["Balanced", "Battery Saver", "High Fidelity"]
              .map(
                (option) => `<option ${state.performanceMode === option ? "selected" : ""}>${option}</option>`,
              )
              .join("")}
          </select>
        </label>
        <label>
          <span>Cache / offline</span>
          <select data-setting="cacheMode">
            ${["Auto cache", "Offline ready", "Streaming only"]
              .map((option) => `<option ${state.cacheMode === option ? "selected" : ""}>${option}</option>`)
              .join("")}
          </select>
        </label>
      </div>
    </section>
  `;
}

function renderTabs() {
  return `
    <nav class="tab-bar" aria-label="Main navigation">
      ${["home", "saved", "settings"]
        .map(
          (tab) => `
            <button
              class="${state.activeTab === tab ? "tab-active" : ""}"
              data-action="switch-tab"
              data-tab="${escapeHtml(tab)}"
            >
              ${escapeHtml(tab)}
            </button>
          `,
        )
        .join("")}
    </nav>
  `;
}

function renderHome() {
  const selectedLocation = getLocationById(state.selectedLocationId);
  return `
    <section class="app-shell">
      ${renderTopBar(selectedLocation)}
      ${renderGlobe(selectedLocation, `${renderBottomPanel(selectedLocation)}${renderDetailSheet(selectedLocation)}`)}
      ${state.screen === "timeline" ? renderTimeline() : ""}
      ${renderTabs()}
    </section>
  `;
}

function renderSavedView() {
  return `
    <section class="app-shell">
      ${renderGlobe(getLocationById(state.selectedLocationId), renderSaved())}
      ${renderTabs()}
    </section>
  `;
}

function renderSettingsView() {
  return `
    <section class="app-shell">
      ${renderGlobe(getLocationById(state.selectedLocationId), renderSettings())}
      ${renderTabs()}
    </section>
  `;
}

function render() {
  const current = state.screen === "splash"
    ? renderSplash()
    : state.activeTab === "saved"
      ? renderSavedView()
      : state.activeTab === "settings"
        ? renderSettingsView()
        : renderHome();

  app.innerHTML = current;
  const searchInput = app.querySelector("[data-role='search']");
  if (searchInput) {
    searchInput.value = state.searchQuery;
  }

  if (state.isPlaying && state.screen === "timeline") {
    startPlayback();
  } else {
    stopPlayback();
  }

  bindEvents();
}

function bindEvents() {
  app.querySelectorAll("[data-action='select-location']").forEach((element) => {
    element.addEventListener("click", () => {
      setState(selectLocation(state, element.dataset.locationId));
    });
  });

  app.querySelectorAll("[data-action='switch-tab']").forEach((element) => {
    element.addEventListener("click", () => {
      setState(setActiveTab(state, element.dataset.tab));
    });
  });

  app.querySelector("[data-role='search']")?.addEventListener("input", (event) => {
    setState(setSearchQuery(state, event.target.value));
  });

  app.querySelectorAll("[data-action='open-timeline']").forEach((element) => {
    element.addEventListener("click", () => setState(openTimeline(state)));
  });

  app.querySelector("[data-action='toggle-layers']")?.addEventListener("click", () => {
    setState(cycleMapStyle(state));
  });

  app.querySelector("[data-action='close-timeline']")?.addEventListener("click", () => {
    setState(closeTimeline(state));
  });

  app.querySelectorAll("[data-action='toggle-detail']").forEach((element) => {
    element.addEventListener("click", () => setState(toggleDetailExpanded(state)));
  });

  app.querySelector("[data-action='toggle-bookmark']")?.addEventListener("click", () => {
    setState(toggleBookmark(state, state.selectedLocationId));
  });

  app.querySelector("[data-action='share-location']")?.addEventListener("click", () => {
    shareLocation(getLocationById(state.selectedLocationId));
  });

  app.querySelector("[data-action='toggle-playback']")?.addEventListener("click", () => {
    setState(togglePlayback(state));
  });

  app.querySelectorAll("[data-action='jump-event']").forEach((element) => {
    element.addEventListener("click", () => {
      setState(jumpToEvent(state, Number(element.dataset.direction)));
    });
  });

  app.querySelectorAll("[data-action='timeline-event']").forEach((element) => {
    element.addEventListener("click", () => {
      setState(setSelectedTime(state, Number(element.dataset.time)));
    });
  });

  app.querySelector("[data-role='timeline-range']")?.addEventListener("input", (event) => {
    setState(setSelectedTime(state, Number(event.target.value)));
  });

  app.querySelectorAll("select[data-setting]").forEach((element) => {
    element.addEventListener("change", () => {
      setState(updateSetting(state, element.dataset.setting, element.value));
    });
  });
}

render();
loadCoreAssets().then(() => setState(finishLoading(state)));
