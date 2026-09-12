import test from "node:test";
import assert from "node:assert/strict";

import {
  cycleMapStyle,
  closeTimeline,
  createInitialState,
  finishLoading,
  getFilteredLocations,
  jumpToEvent,
  locations,
  openTimeline,
  selectLocation,
  setActiveTab,
  setSearchQuery,
  setSelectedTime,
  toggleBookmark,
  toggleDetailExpanded,
  togglePlayback,
  updateSetting,
} from "./app-state.js";

test("splash transitions to home when loading finishes", () => {
  const finished = finishLoading(createInitialState());
  assert.equal(finished.screen, "home");
  assert.equal(finished.status, "Core assets ready");
});

test("location selection preserves home flow and resets sheet expansion", () => {
  const state = {
    ...createInitialState(),
    screen: "timeline",
    detailExpanded: true,
  };

  const next = selectLocation(state, locations[1].id);
  assert.equal(next.screen, "home");
  assert.equal(next.activeTab, "home");
  assert.equal(next.detailExpanded, false);
  assert.equal(next.selectedLocationId, locations[1].id);
});

test("invalid location selection falls back to the default location", () => {
  const next = selectLocation(createInitialState(), "unknown-location");
  assert.equal(next.selectedLocationId, locations[0].id);
});

test("bookmarks can be saved and removed", () => {
  const firstSave = toggleBookmark(createInitialState(), locations[0].id);
  const secondSave = toggleBookmark(firstSave, locations[0].id);
  const fallbackSave = toggleBookmark(createInitialState(), "missing");

  assert.deepEqual(firstSave.savedLocationIds, [locations[0].id]);
  assert.deepEqual(secondSave.savedLocationIds, []);
  assert.deepEqual(fallbackSave.savedLocationIds, [locations[0].id]);
});

test("timeline state preserves selected time on open and close", () => {
  const base = setSelectedTime(createInitialState(), 70);
  const open = openTimeline(base);
  const closed = closeTimeline(open);

  assert.equal(open.screen, "timeline");
  assert.equal(closed.screen, "home");
  assert.equal(closed.selectedTime, 70);
});

test("search query focuses the first matching location", () => {
  const next = setSearchQuery(createInitialState(), "andes");
  assert.equal(next.selectedLocationId, locations[1].id);
  assert.equal(getFilteredLocations("139.7").length, 1);
});

test("detail sheet and playback toggles flip boolean state", () => {
  const expanded = toggleDetailExpanded(createInitialState());
  const playing = togglePlayback(createInitialState());

  assert.equal(expanded.detailExpanded, true);
  assert.equal(playing.isPlaying, true);
});

test("timeline event jumps choose the closest previous and next markers", () => {
  const state = setSelectedTime(createInitialState(), 46);
  assert.equal(jumpToEvent(state, -1).selectedTime, 45);
  assert.equal(jumpToEvent(state, 1).selectedTime, 70);
});

test("switching away from home closes the timeline overlay", () => {
  const timeline = openTimeline(createInitialState());
  const saved = setActiveTab(timeline, "saved");
  const home = setActiveTab(saved, "home");
  const ignored = setActiveTab(saved, "invalid");

  assert.equal(saved.activeTab, "saved");
  assert.equal(saved.screen, "home");
  assert.equal(home.activeTab, "home");
  assert.equal(home.screen, "home");
  assert.equal(ignored.activeTab, "saved");
});

test("layers control cycles through supported map styles", () => {
  const first = cycleMapStyle(createInitialState());
  const second = cycleMapStyle(first);
  const third = cycleMapStyle(second);

  assert.equal(first.mapStyle, "Terrain");
  assert.equal(second.mapStyle, "Signal");
  assert.equal(third.mapStyle, "Globe");
});

test("settings updates only supported keys", () => {
  const updated = updateSetting(createInitialState(), "mapStyle", "Signal");
  const ignored = updateSetting(updated, "screen", "timeline");
  const invalidValue = updateSetting(updated, "mapStyle", "Neon");

  assert.equal(updated.mapStyle, "Signal");
  assert.equal(ignored.screen, "splash");
  assert.equal(invalidValue.mapStyle, "Signal");
});
