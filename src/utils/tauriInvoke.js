function toLowerCamelCaseKey(key) {
  if (!key.includes("_")) {
    return key;
  }

  return key.replace(/_+([a-zA-Z0-9])/g, (_, char) => char.toUpperCase());
}

export function normalizeInvokeArgs(args) {
  if (args === undefined || args === null || Array.isArray(args) || typeof args !== "object") {
    return args;
  }

  const normalized = {};
  for (const [rawKey, value] of Object.entries(args)) {
    const nextKey = toLowerCamelCaseKey(rawKey);
    if (Object.prototype.hasOwnProperty.call(normalized, nextKey)) {
      throw new Error(
        `[Orbit] Duplicate invoke arg after camelCase normalization: ${rawKey} -> ${nextKey}`,
      );
    }
    normalized[nextKey] = value;
  }

  return normalized;
}

export function invokeCommand(command, args) {
  const { invoke } = window.__TAURI__.core;
  const normalizedArgs = normalizeInvokeArgs(args);
  return normalizedArgs === undefined ? invoke(command) : invoke(command, normalizedArgs);
}
