export const locations = [
  {
    id: "north-atlantic",
    name: "North Atlantic Relay",
    coordinates: "46.2° N, 28.4° W",
    region: "Oceanic corridor",
    summary: "High-traffic waypoint with active atmospheric and shipping telemetry overlays.",
    metadata: {
      elevation: "Sea level",
      visibility: "High",
      coverage: "Telemetry mesh",
    },
    marker: { x: 58, y: 34 },
  },
  {
    id: "andes-array",
    name: "Andes Sensor Array",
    coordinates: "13.5° S, 71.9° W",
    region: "South America",
    summary: "Mountain sensor cluster tracking terrain shifts, weather fronts, and historical events.",
    metadata: {
      elevation: "3,800 m",
      visibility: "Medium",
      coverage: "Seismic grid",
    },
    marker: { x: 26, y: 61 },
  },
  {
    id: "pacific-gateway",
    name: "Pacific Gateway",
    coordinates: "35.6° N, 139.7° E",
    region: "Asia-Pacific",
    summary: "Dense urban observation point with layered transport, energy, and population signals.",
    metadata: {
      elevation: "44 m",
      visibility: "High",
      coverage: "Urban fusion",
    },
    marker: { x: 83, y: 41 },
  },
];

export const timelineEvents = [
  { id: "evt-1", label: "Asset sync", time: 20 },
  { id: "evt-2", label: "Weather shift", time: 45 },
  { id: "evt-3", label: "Transit spike", time: 70 },
  { id: "evt-4", label: "Signal handoff", time: 90 },
];

const supportedTabs = new Set(["home", "saved", "settings"]);
const supportedSettingValues = {
  theme: new Set(["Midnight", "Aurora", "Slate"]),
  mapStyle: new Set(["Globe", "Terrain", "Signal"]),
  performanceMode: new Set(["Balanced", "Battery Saver", "High Fidelity"]),
  cacheMode: new Set(["Auto cache", "Offline ready", "Streaming only"]),
};

export function createInitialState() {
  return {
    screen: "splash",
    activeTab: "home",
    selectedLocationId: locations[0].id,
    detailExpanded: false,
    savedLocationIds: [],
    selectedTime: timelineEvents[1].time,
    isPlaying: false,
    theme: "Midnight",
    mapStyle: "Globe",
    performanceMode: "Balanced",
    cacheMode: "Auto cache",
    searchQuery: "",
    status: "Loading globe assets…",
  };
}

export function getLocationById(locationId) {
  return locations.find((location) => location.id === locationId) ?? locations[0];
}

export function getFilteredLocations(query) {
  const normalized = query.trim().toLowerCase();
  if (!normalized) {
    return locations;
  }

  return locations.filter((location) =>
    [location.name, location.region, location.coordinates].some((value) =>
      value.toLowerCase().includes(normalized),
    ),
  );
}

export function finishLoading(state) {
  return {
    ...state,
    screen: "home",
    status: "Core assets ready",
  };
}

export function selectLocation(state, locationId) {
  const selectedLocationId = getLocationById(locationId).id;
  return {
    ...state,
    activeTab: "home",
    screen: "home",
    selectedLocationId,
    detailExpanded: false,
  };
}

export function setActiveTab(state, activeTab) {
  if (!supportedTabs.has(activeTab)) {
    return state;
  }

  return {
    ...state,
    activeTab,
    screen: "home",
  };
}

export function setSearchQuery(state, searchQuery) {
  const matches = getFilteredLocations(searchQuery);
  return {
    ...state,
    searchQuery,
    selectedLocationId: matches[0]?.id ?? state.selectedLocationId,
  };
}

export function toggleBookmark(state, locationId) {
  const selectedLocationId = getLocationById(locationId).id;
  const savedLocationIds = state.savedLocationIds.includes(selectedLocationId)
    ? state.savedLocationIds.filter((id) => id !== selectedLocationId)
    : [...state.savedLocationIds, selectedLocationId];

  return {
    ...state,
    savedLocationIds,
  };
}

export function openTimeline(state) {
  return {
    ...state,
    activeTab: "home",
    screen: "timeline",
    isPlaying: false,
  };
}

export function closeTimeline(state) {
  return {
    ...state,
    screen: "home",
    isPlaying: false,
  };
}

export function toggleDetailExpanded(state) {
  return {
    ...state,
    detailExpanded: !state.detailExpanded,
  };
}

export function setSelectedTime(state, selectedTime) {
  return {
    ...state,
    selectedTime,
  };
}

export function togglePlayback(state) {
  return {
    ...state,
    isPlaying: !state.isPlaying,
  };
}

export function jumpToEvent(state, direction) {
  const sorted = [...timelineEvents].sort((left, right) => left.time - right.time);
  const nextIndex =
    direction < 0
      ? Math.max(
          0,
          sorted.reduce(
            (foundIndex, event, index) =>
              event.time < state.selectedTime ? index : foundIndex,
            -1,
          ),
        )
      : (() => {
          const firstLaterIndex = sorted.findIndex((event) => event.time > state.selectedTime);
          return firstLaterIndex === -1 ? sorted.length - 1 : firstLaterIndex;
        })();

  return {
    ...state,
    selectedTime: sorted[nextIndex].time,
  };
}

export function updateSetting(state, setting, value) {
  const allowedValues = supportedSettingValues[setting];
  if (!allowedValues?.has(value)) {
    return state;
  }

  return {
    ...state,
    [setting]: value,
  };
}

export function cycleMapStyle(state) {
  const options = ["Globe", "Terrain", "Signal"];
  const currentIndex = options.indexOf(state.mapStyle);
  return {
    ...state,
    mapStyle: options[(currentIndex + 1) % options.length],
  };
}
