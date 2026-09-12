import test from "node:test";
import assert from "node:assert/strict";

import {
  closeTimeline,
  createInitialState,
  finishLoading,
  getFilteredLocations,
  locations,
  openTimeline,
  selectLocation,
  setSearchQuery,
  setSelectedTime,
  toggleBookmark,
  toggleDetailExpanded,
  togglePlayback,
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

test("bookmarks can be saved and removed", () => {
  const firstSave = toggleBookmark(createInitialState(), locations[0].id);
  const secondSave = toggleBookmark(firstSave, locations[0].id);

  assert.deepEqual(firstSave.savedLocationIds, [locations[0].id]);
  assert.deepEqual(secondSave.savedLocationIds, []);
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
